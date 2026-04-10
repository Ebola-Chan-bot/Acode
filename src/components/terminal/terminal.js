/**
 * Terminal Component using xtermjs
 * Provides a pluggable and customizable terminal interface
 */

import { AttachAddon } from "@xterm/addon-attach";
import { FitAddon } from "@xterm/addon-fit";
import { ImageAddon } from "@xterm/addon-image";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { WebglAddon } from "@xterm/addon-webgl";
import { Terminal as Xterm } from "@xterm/xterm";
import toast from "components/toast";
import confirm from "dialogs/confirm";
import fonts from "lib/fonts";
import keyBindings from "lib/keyBindings";
import appSettings from "lib/settings";
import LigaturesAddon from "./ligatures";
import { getTerminalSettings } from "./terminalDefaults";
import TerminalThemeManager from "./terminalThemeManager";
import TerminalTouchSelection from "./terminalTouchSelection";

let terminalEnvironmentGeneration = 0;
const AXS_READY_MARKER = "__ACODE_AXS_READY__";

// Bump the generation counter to invalidate all in-flight createSessionInternal() calls.
// Used by terminalManager.closeAllTerminals() to cancel startup code for terminals not yet
// registered in the terminals map (so dispose() alone cannot reach them).
export function invalidateTerminalEnvironment() {
	terminalEnvironmentGeneration++;
}

// Expose the current generation so callers can snapshot it before an await
// boundary and later detect invalidations that occurred during the wait.
export function getTerminalEnvironmentGeneration() {
	return terminalEnvironmentGeneration;
}

class TerminalSessionStaleError extends Error {
	constructor(message = "Terminal session attempt became stale") {
		super(message);
		this.name = "TerminalSessionStaleError";
	}
}

export default class TerminalComponent {
	constructor(options = {}) {
		// Get terminal settings from shared defaults
		const terminalSettings = getTerminalSettings();

		this.options = {
			allowProposedApi: true,
			scrollOnUserInput: true,
			rows: options.rows || 24,
			cols: options.cols || 80,
			port: options.port || 8767,
			renderer: options.renderer || "auto", // 'auto' | 'canvas' | 'webgl'
			fontSize: terminalSettings.fontSize,
			fontFamily: `"${terminalSettings.fontFamily}", monospace`,
			fontWeight: terminalSettings.fontWeight,
			theme: TerminalThemeManager.getTheme(terminalSettings.theme),
			cursorBlink: terminalSettings.cursorBlink,
			cursorStyle: terminalSettings.cursorStyle,
			cursorInactiveStyle: terminalSettings.cursorInactiveStyle,
			scrollback: terminalSettings.scrollback,
			tabStopWidth: terminalSettings.tabStopWidth,
			convertEol: terminalSettings.convertEol,
			letterSpacing: terminalSettings.letterSpacing,
			...options,
		};

		this.terminal = null;
		this.fitAddon = null;
		this.attachAddon = null;
		this.unicode11Addon = null;
		this.searchAddon = null;
		this.webLinksAddon = null;
		this.imageAddon = null;
		this.ligaturesAddon = null;
		this.container = null;
		this.websocket = null;
		this.pid = null;
		this.isConnected = false;
		this.serverMode = options.serverMode !== false; // Default true
		this.touchSelection = null;
		this._isDisposed = false;
		this._sessionCreationPromise = null;
		this._bootstrapOutputSeen = false;
		this._pendingFocusAfterBootstrap = false;
		this._visibleLayoutSyncFrame = null;
		this._visibleLayoutSyncTimeout = null;
		this._focusLayoutSyncTimeout = null;
		this._visualViewportSyncHandler = null;
		this._wasVisibleOnLastLayoutSync = false;
		this._hiddenBootstrapOutputNeedsVisibleAnchor = false;

		this.init();
	}

	init() {
		this.terminal = new Xterm(this.options);

		// Initialize addons
		this.fitAddon = new FitAddon();
		this.unicode11Addon = new Unicode11Addon();
		this.searchAddon = new SearchAddon();
		this.webLinksAddon = new WebLinksAddon(async (event, uri) => {
			const linkOpenConfirm = await confirm(
				"Terminal",
				`Do you want to open ${uri} in browser?`,
			);
			if (linkOpenConfirm) {
				system.openInBrowser(uri);
			}
		});
		this.webglAddon = null;

		// Load addons
		this.terminal.loadAddon(this.fitAddon);
		this.terminal.loadAddon(this.unicode11Addon);
		this.terminal.loadAddon(this.searchAddon);
		this.terminal.loadAddon(this.webLinksAddon);

		// Load conditional addons based on settings
		const terminalSettings = getTerminalSettings();

		// Load image addon if enabled
		if (terminalSettings.imageSupport) {
			this.loadImageAddon();
		}

		// Load font if specified
		this.loadTerminalFont();

		// Set up terminal event handlers
		this.setupEventHandlers();
	}

	setupEventHandlers() {
		// terminal resize handling
		this.setupResizeHandling();

		// Handle terminal title changes
		this.terminal.onTitleChange((title) => {
			this.onTitleChange?.(title);
		});

		// Handle bell
		this.terminal.onBell(() => {
			this.onBell?.();
		});

		// Handle copy/paste keybindings
		this.setupCopyPasteHandlers();

		// Handle custom OSC 7777 for acode CLI commands
		this.setupOscHandler();
	}

	/**
	 * Setup custom OSC handler for acode CLI integration
	 * OSC 7777 format: \e]7777;command;arg1;arg2;...\a
	 */
	setupOscHandler() {
		// Register custom OSC handler for ID 7777
		// Format: command;arg1;arg2;... where arg2 (path) may contain semicolons
		this.terminal.parser.registerOscHandler(7777, (data) => {
			const firstSemi = data.indexOf(";");
			if (firstSemi === -1) {
				console.warn("Invalid OSC 7777 format:", data);
				return true;
			}

			const command = data.substring(0, firstSemi);
			const rest = data.substring(firstSemi + 1);

			switch (command) {
				case "open": {
					// Format: open;type;path (path may contain semicolons)
					const secondSemi = rest.indexOf(";");
					if (secondSemi === -1) {
						console.warn("Invalid OSC 7777 open format:", data);
						return true;
					}
					const type = rest.substring(0, secondSemi);
					const path = rest.substring(secondSemi + 1);
					this.handleOscOpen(type, path);
					break;
				}
				default:
					console.warn("Unknown OSC 7777 command:", command);
			}
			return true;
		});
	}

	/**
	 * Handle OSC open command from acode CLI
	 * @param {string} type - "file" or "folder"
	 * @param {string} path - Path to open
	 */
	handleOscOpen(type, path) {
		if (!path) return;

		// Emit event for the app to handle
		this.onOscOpen?.(type, path);
	}

	/**
	 * Setup resize handling for keyboard events and content preservation
	 */
	setupResizeHandling() {
		let resizeTimeout = null;
		let lastKnownScrollPosition = 0;
		let wasNearBottomBeforeResize = true;
		let isResizing = false;
		const RESIZE_DEBOUNCE = 100;

		// Store original dimensions for comparison
		let originalRows = this.terminal.rows;
		let originalCols = this.terminal.cols;

		this.terminal.onResize((size) => {
			isResizing = true;

			// Store current scroll position before resize
			if (this.terminal.buffer && this.terminal.buffer.active) {
				const buffer = this.terminal.buffer.active;
				const maxScroll = Math.max(0, buffer.length - this.terminal.rows);
				lastKnownScrollPosition = buffer.viewportY;
				wasNearBottomBeforeResize = buffer.viewportY >= maxScroll - 1;
			}

			// Clear any existing timeout
			if (resizeTimeout) {
				clearTimeout(resizeTimeout);
			}

			// Debounced resize handling
			resizeTimeout = setTimeout(async () => {
				try {
					// Always sync cols/rows to backend PTY on every client resize.
					//
					// The original code only synced when heightRatio < 0.75 (the "keyboard resize"
					// heuristic below). That fails in several real scenarios on mobile:
					//   1. Small keyboard height changes (e.g. switching input methods, suggestion
					//      bar appearing/disappearing) shrink height by <25%, bypassing the threshold.
					//   2. Width-only changes (screen rotation, split-screen toggle) leave height
					//      unchanged so heightRatio ≈ 1.0, but cols change and PTY must know.
					//   3. Animated keyboard open/close fires many incremental resize events; each
					//      individual step is a tiny delta that never crosses 0.75, yet the
					//      accumulated drift corrupts output.
					//   4. Different ROMs / WebView versions report slightly different viewport sizes
					//      for the same keyboard, making any fixed threshold unreliable.
					//
					// Unconditionally syncing is cheap (one small HTTP POST per debounced resize)
					// and guarantees the PTY always matches the client grid.
					if (this.serverMode) {
						await this.resizeTerminal(size.cols, size.rows);
					}

					// Handle keyboard resize cursor positioning
					const heightRatio = size.rows / originalRows;
					if (
						heightRatio < 0.75 &&
						this.terminal.buffer &&
						this.terminal.buffer.active
					) {
						// Keyboard resize detected - ensure cursor is visible
						const buffer = this.terminal.buffer.active;
						const cursorY = buffer.cursorY;
						const cursorViewportPos = buffer.baseY + cursorY;
						const viewportTop = buffer.viewportY;
						const viewportBottom = viewportTop + this.terminal.rows - 1;

						if (
							cursorViewportPos <= viewportTop + 1 ||
							cursorViewportPos >= viewportBottom - 1
						) {
							const targetScroll = Math.max(
								0,
								Math.min(
									buffer.length - this.terminal.rows,
									cursorViewportPos - Math.floor(this.terminal.rows * 0.25),
								),
							);
							this.terminal.scrollToLine(targetScroll);
						}
					} else if (wasNearBottomBeforeResize) {
						// Restoring a stale viewportY after a hidden-tab/IME height change while
						// the prompt is at the bottom replays a scroll offset that no longer matches
						// the new viewport height, causing xterm to shift the DOM layer above its
						// container. If we were already at the live bottom, re-anchor there.
						this.terminal.scrollToBottom();
					} else {
						// Regular resize away from the prompt - preserve the user-visible viewport.
						this.preserveViewportPosition(lastKnownScrollPosition);
					}

					// Update stored dimensions
					originalRows = size.rows;
					originalCols = size.cols;

					// Mark resize as complete
					isResizing = false;

					// IME animation can shrink the viewport after the tab is visible, causing
					// WebView to reapply a stale scroll offset that pushes the .xterm layer above
					// the container. Running visible-layout correction after the debounced resize
					// settles fixes that late relocation, and also makes hidden terminals that
					// received MOTD while inactive repaint correctly when they become active.
					this.scheduleVisibleLayoutSync("resize-settled");

					// Notify touch selection if it exists
					if (this.touchSelection) {
						this.touchSelection.onTerminalResize(size);
					}
				} catch (error) {
					console.error("Resize handling failed:", error);
					isResizing = false;
				}
			}, RESIZE_DEBOUNCE);
		});

		// Also handle viewport changes for scroll position preservation
		this.terminal.onData(() => {
			// If we're not resizing and user types, everything is stable
			if (!isResizing && this.terminal.buffer && this.terminal.buffer.active) {
				lastKnownScrollPosition = this.terminal.buffer.active.viewportY;
			}
		});
	}

	/**
	 * Preserve viewport position during resize to prevent jumping
	 */
	preserveViewportPosition(targetScrollPosition) {
		if (!this.terminal.buffer || !this.terminal.buffer.active) return;

		const buffer = this.terminal.buffer.active;
		const maxScroll = Math.max(0, buffer.length - this.terminal.rows);

		// Ensure scroll position is within valid bounds
		const safeScrollPosition = Math.min(targetScrollPosition, maxScroll);

		// Only adjust if we have significant content and the position differs
		if (
			buffer.length > this.terminal.rows &&
			buffer.viewportY !== safeScrollPosition
		) {
			this.terminal.scrollToLine(safeScrollPosition);
		}
	}

	/**
	 * Setup touch selection for mobile devices
	 */
	setupTouchSelection() {
		// Only initialize touch selection on mobile devices
		if (window.cordova && this.container) {
			const terminalSettings = getTerminalSettings();
			this.touchSelection = new TerminalTouchSelection(
				this.terminal,
				this.container,
				{
					tapHoldDuration:
						terminalSettings.touchSelectionTapHoldDuration || 600,
					moveThreshold: terminalSettings.touchSelectionMoveThreshold || 8,
					handleSize: terminalSettings.touchSelectionHandleSize || 24,
					hapticFeedback:
						terminalSettings.touchSelectionHapticFeedback !== false,
					showContextMenu:
						terminalSettings.touchSelectionShowContextMenu !== false,
					onFontSizeChange: (fontSize) => this.updateFontSize(fontSize),
				},
			);
		}
	}

	/**
	 * Parse app keybindings into a format usable by the keyboard handler
	 */
	parseAppKeybindings() {
		const parsedBindings = [];

		Object.values(keyBindings).forEach((binding) => {
			if (!binding.key) return;

			// Skip editor-only keybindings in terminal
			if (binding.editorOnly) return;

			// Handle multiple key combinations separated by |
			const keys = binding.key.split("|");

			keys.forEach((keyCombo) => {
				const parts = keyCombo.split("-");
				const parsed = {
					ctrl: false,
					shift: false,
					alt: false,
					meta: false,
					key: "",
				};

				parts.forEach((part) => {
					const lowerPart = part.toLowerCase();
					if (lowerPart === "ctrl") {
						parsed.ctrl = true;
					} else if (lowerPart === "shift") {
						parsed.shift = true;
					} else if (lowerPart === "alt") {
						parsed.alt = true;
					} else if (lowerPart === "meta" || lowerPart === "cmd") {
						parsed.meta = true;
					} else {
						// This is the actual key
						parsed.key = part;
					}
				});

				if (parsed.key) {
					parsedBindings.push(parsed);
				}
			});
		});

		return parsedBindings;
	}

	/**
	 * Setup copy/paste keyboard handlers
	 */
	setupCopyPasteHandlers() {
		// Add keyboard event listener to terminal element
		this.terminal.attachCustomKeyEventHandler((event) => {
			// Check for Ctrl+Shift+C (copy)
			if (event.ctrlKey && event.shiftKey && event.key === "C") {
				event.preventDefault();
				this.copySelection();
				return false;
			}

			// Check for Ctrl+Shift+V (paste)
			if (event.ctrlKey && event.shiftKey && event.key === "V") {
				event.preventDefault();
				this.pasteFromClipboard();
				return false;
			}

			// Check for Ctrl+= or Ctrl++ (increase font size)
			if (event.ctrlKey && (event.key === "+" || event.key === "=")) {
				event.preventDefault();
				this.increaseFontSize();
				return false;
			}

			// Check for Ctrl+- (decrease font size)
			if (event.ctrlKey && event.key === "-") {
				event.preventDefault();
				this.decreaseFontSize();
				return false;
			}

			// Only intercept specific app-wide keybindings, let terminal handle the rest
			if (event.ctrlKey || event.altKey || event.metaKey) {
				// Skip modifier-only keys
				if (["Control", "Alt", "Meta", "Shift"].includes(event.key)) {
					return true;
				}

				// Get parsed app keybindings
				const appKeybindings = this.parseAppKeybindings();

				// Check if this is an app-specific keybinding
				const isAppKeybinding = appKeybindings.some(
					(binding) =>
						binding.ctrl === event.ctrlKey &&
						binding.shift === event.shiftKey &&
						binding.alt === event.altKey &&
						binding.meta === event.metaKey &&
						binding.key === event.key,
				);

				if (isAppKeybinding) {
					const appEvent = new KeyboardEvent("keydown", {
						key: event.key,
						ctrlKey: event.ctrlKey,
						shiftKey: event.shiftKey,
						altKey: event.altKey,
						metaKey: event.metaKey,
						bubbles: true,
						cancelable: true,
					});

					// Dispatch to document so it gets picked up by the app's keyboard handler
					document.dispatchEvent(appEvent);

					// Return false to prevent terminal from processing this key
					return false;
				}

				// For all other modifier combinations, let the terminal handle them
				return true;
			}

			// Return true to allow normal processing for other keys
			return true;
		});
	}

	/**
	 * Copy selected text to clipboard
	 */
	copySelection() {
		if (!this.terminal?.hasSelection()) return;
		const selectedStr = this.terminal?.getSelection();
		if (selectedStr && cordova?.plugins?.clipboard) {
			cordova.plugins.clipboard.copy(selectedStr);
		}
	}

	/**
	 * Paste text from clipboard
	 */
	pasteFromClipboard() {
		if (cordova?.plugins?.clipboard) {
			cordova.plugins.clipboard.paste((text) => {
				this.terminal?.paste(text);
			});
		}
	}

	/**
	 * Create terminal container element
	 * @returns {HTMLElement} Container element
	 */
	createContainer() {
		this.container = document.createElement("div");
		this.container.className = "terminal-container";
		this.container.style.cssText = `
      width: 100%;
      height: 100%;
      position: relative;
      background: ${this.options.theme.background};
      overflow: hidden;
      box-sizing: border-box;
    `;

		return this.container;
	}

	/**
	 * Mount terminal to container
	 * @param {HTMLElement} container - Container element
	 */
	mount(container) {
		if (!container) {
			container = this.createContainer();
		}

		this.container = container;

		// Apply terminal background color to container to match theme
		this.container.style.background = this.options.theme.background;

		try {
			// Open first to ensure a stable renderer is attached
			this.terminal.open(container);
			this.bindVisualViewportLayoutSync();

			// Renderer selection: 'canvas' (default core), 'webgl', or 'auto'
			if (
				this.options.renderer === "webgl" ||
				this.options.renderer === "auto"
			) {
				try {
					const addon = new WebglAddon();
					this.terminal.loadAddon(addon);
					if (typeof addon.onContextLoss === "function") {
						addon.onContextLoss(() => this._handleWebglContextLoss());
					}
					this.webglAddon = addon;
				} catch (error) {
					console.error("Failed to enable WebGL renderer:", error);
					try {
						this.webglAddon?.dispose?.();
					} catch {}
					this.webglAddon = null; // stay on canvas
				}
			}
			const terminalSettings = getTerminalSettings();
			// Load ligatures addon if enabled
			if (terminalSettings.fontLigatures) {
				this.loadLigaturesAddon();
			}

			// First render pass: schedule a fit once the frame is ready.
			// Auto-focusing here opens the soft keyboard before MOTD/prompt arrives and
			// can shrink the viewport while restored tabs are still computing their first
			// PTY size, causing hard-wrapped output on first paint.
			if (typeof requestAnimationFrame === "function") {
				requestAnimationFrame(() => {
					this.fitAddon.fit();
					this.setupTouchSelection();
				});
			} else {
				setTimeout(() => {
					this.fitAddon.fit();
					this.setupTouchSelection();
				}, 0);
			}
		} catch (error) {
			console.error("Failed to mount terminal:", error);
		}

		return container;
	}

	/**
	 * Create new terminal session using global Terminal API
	 * @returns {Promise<string>} Terminal PID
	 */
	async createSession() {
		if (!this.serverMode) {
			throw new Error(
				"Terminal is in local mode, cannot create server session",
			);
		}

		if (this._sessionCreationPromise) {
			return this._sessionCreationPromise;
		}

		// The same terminal tab can hit createSession twice while mount/reconnect work
		// overlaps. Without a per-instance single-flight guard, one attempt can consume
		// the ready marker while the other times out and tears down a healthy session.
		const sessionCreationPromise = this.createSessionInternal();
		this._sessionCreationPromise = sessionCreationPromise;

		try {
			return await sessionCreationPromise;
		} finally {
			if (this._sessionCreationPromise === sessionCreationPromise) {
				this._sessionCreationPromise = null;
			}
		}
	}

	async createSessionInternal() {
		try {
			// Use the pre-install generation snapshot if available.  Waiters capture
		// this BEFORE the shared install operation so that an uninstall that
		// happens between install completion and createSessionInternal entry
		// (which bumps the generation) is detected as stale.
		let observedEnvironmentGeneration =
			this._preInstallEnvironmentGeneration ?? terminalEnvironmentGeneration;
		delete this._preInstallEnvironmentGeneration;
			const ensureAttemptIsStillValid = () => {
				if (this._isDisposed) {
					throw new TerminalSessionStaleError();
				}

				// Terminal startup mutates a single shared AXS/rootfs environment.
				// If another terminal has already created a newer healthy session,
				// this older async flow must fail fast instead of repairing and
				// tearing down the newer instance underneath it.
				if (terminalEnvironmentGeneration !== observedEnvironmentGeneration) {
					throw new TerminalSessionStaleError();
				}
			};

			// Check if terminal is installed before starting AXS
			const installed = await Terminal.isInstalled();
			ensureAttemptIsStillValid();
			if (!installed) {
				throw new Error(
					"Terminal not installed. Please install terminal first.",
				);
			}

			// Start AXS if not running
			const axsRunning = await Terminal.isAxsRunning();
			ensureAttemptIsStillValid();

			// Poll by hitting the actual HTTP endpoint, not just checking PID liveness.
			// isAxsRunning() only does kill -0 on the PID file, which can return true
			// while the HTTP server inside proot is still booting.
			const fetchWithTimeout = async (url, options = {}, timeoutMs = 2000) => {
				const hasAbortSignalTimeout =
					typeof AbortSignal !== "undefined" &&
					typeof AbortSignal.timeout === "function";

				if (hasAbortSignalTimeout) {
					return fetch(url, {
						...options,
						signal: AbortSignal.timeout(timeoutMs),
					});
				}

				if (typeof AbortController === "undefined") {
					return fetch(url, options);
				}

				const controller = new AbortController();
				const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
				try {
					return await fetch(url, {
						...options,
						signal: controller.signal,
					});
				} finally {
					clearTimeout(timeoutId);
				}
			};

			const pollAxs = async (maxRetries = 30, intervalMs = 1000) => {
				for (let i = 0; i < maxRetries; i++) {
					// Exit early when the terminal was disposed or the environment was
					// invalidated (e.g. uninstall called closeAllTerminals while this
					// terminal was still initializing and not yet in the terminals map).
					ensureAttemptIsStillValid();
					await new Promise((r) => setTimeout(r, intervalMs));
					ensureAttemptIsStillValid();
					try {
						const resp = await fetchWithTimeout(
							`http://localhost:${this.options.port}/`,
							{ method: "GET" },
							2000,
						);
						if (resp.ok || resp.status < 500) return true;
					} catch (_) {
						// HTTP not yet reachable
					}
				}
				return false;
			};

			const writeLifecycleLog = (message, isError = false) => {
				const cleanMessage = String(message ?? "").replace(/^(stdout|stderr)\s+/, "");
				if (cleanMessage) {
					startupLifecycleOutputSeen = true;
					if (startupProgressNoticeTimer) {
						clearTimeout(startupProgressNoticeTimer);
						startupProgressNoticeTimer = null;
					}
					this.terminal.write(
						`${isError ? "\x1b[31m" : ""}${cleanMessage}\x1b[0m\r\n`,
					);
					// Forward to console so the debug client can observe lifecycle events.
					// Noise from proot (INFO/WARNING) is suppressed at source via
					// PROOT_VERBOSE=-1 in init-sandbox.sh; only real messages reach here.
					if (isError) {
						console.error(cleanMessage);
					} else {
						console.log(cleanMessage);
					}
				}
			};

			const runSharedEnvironmentOperation = async (type, run) => {
				if (this.environmentCoordinator?.runExclusive) {
					return this.environmentCoordinator.runExclusive({
						type,
						run: async () => {
							// Shared startup/repair/refresh owners intentionally bump the terminal
							// environment generation before waiters resume their own local checks.
							// Reusing the stale pre-wait generation here makes the waiter abort its
							// normal connect path, leaving the tab stuck on the transient waiting
							// screen and forcing the UI to fall back to the internal terminal_N id.
							observedEnvironmentGeneration = terminalEnvironmentGeneration;
							return run();
						},
					});
				}

				return run();
			};

			let startupProgressNoticeTimer = null;
			let startupLifecycleOutputSeen = false;
			const clearStartupProgressNoticeTimer = () => {
				if (startupProgressNoticeTimer) {
					clearTimeout(startupProgressNoticeTimer);
					startupProgressNoticeTimer = null;
				}
			};

			const showStartupProgressNotice = (message, delayMs = 0) => {
				clearStartupProgressNoticeTimer();
				const writeNotice = () => {
					if (startupLifecycleOutputSeen) {
						return;
					}
					this.terminal.write(`\x1b[36m${message}\x1b[0m\r\n`);
				};

				// Terminal startup currently waits for the shared AXS/proot bootstrap before
				// the first lifecycle line arrives. Without an early foreground notice, users
				// see a long black screen and misread normal startup work as a freeze.
				if (delayMs <= 0) {
					writeNotice();
					return;
				}

				startupProgressNoticeTimer = setTimeout(() => {
					startupProgressNoticeTimer = null;
					writeNotice();
				}, delayMs);
			};

			const syncTerminalLayout = async () => {
				const hasRenderableLayout = () => {
					if (!this.container) {
						return false;
					}

					const rect = this.container.getBoundingClientRect();
					return rect.width >= 10 && rect.height >= 10;
				};

				const runFit = () => {
					// Shared startup waiters can resume after their tab has already moved to the
					// background. Fitting xterm while the container is hidden collapses cols to a
					// bogus tiny value, and the subsequent POST /terminals creates a PTY with an
					// incorrect grid size. Only pre-fit when the terminal has a real renderable layout.
					if (!hasRenderableLayout()) {
						return;
					}

					this.fit();
				};

				if (typeof requestAnimationFrame === "function") {
					await new Promise((resolve) => {
						requestAnimationFrame(() => {
							runFit();
							resolve();
						});
					});
					return;
				}

				runFit();
			};

			const startAxsAndWaitForReady = async (installing = false) => {
				let readyResolve;
				let readyReject;
				let readySettled = false;
				let readyTimeoutId = null;
				startupLifecycleOutputSeen = false;
				showStartupProgressNotice("Starting terminal environment...");
				showStartupProgressNotice(
					"Terminal environment is still starting. Waiting for AXS output...",
					1500,
				);

				const readyPromise = new Promise((resolve, reject) => {
					readyResolve = resolve;
					readyReject = reject;
				});

				const settleReady = (resolver, value) => {
					if (readySettled) {
						return;
					}

					readySettled = true;
					if (readyTimeoutId) {
						clearTimeout(readyTimeoutId);
						readyTimeoutId = null;
					}
					resolver(value);
				};

				const handleLifecycleMessage = (message, isError = false) => {
					const cleanMessage = String(message ?? "").replace(/^(stdout|stderr)\s+/, "");

					if (cleanMessage.includes(AXS_READY_MARKER)) {
						settleReady(readyResolve, true);
						return;
					}

					writeLifecycleLog(message, isError);

					if (cleanMessage.startsWith("exit ")) {
						settleReady(
							readyReject,
							new Error(`AXS exited before becoming ready: ${cleanMessage}`),
						);
					}
				};

				const startResult = await Terminal.startAxs(
					installing,
					(message) => handleLifecycleMessage(message, false),
					(message) => handleLifecycleMessage(message, true),
				);

				if (installing) {
					clearStartupProgressNoticeTimer();
					return startResult;
				}

				// 不设超时，无限等待 AXS ready 信号。
				try {
					await readyPromise;
				} finally {
					clearStartupProgressNoticeTimer();
				}
			};

			if (!axsRunning) {
				await runSharedEnvironmentOperation("startup", async () => {
					ensureAttemptIsStillValid();
					const sharedAxsRunning = await Terminal.isAxsRunning();
					ensureAttemptIsStillValid();
					if (sharedAxsRunning) {
						return;
					}

					await startAxsAndWaitForReady(false);
				});
				ensureAttemptIsStillValid();
			}

			// Always wait for the HTTP endpoint, even if the PID is already alive.
			// kill -0 only tells us the outer process exists; the embedded server may
			// still be starting, especially after crash recovery on slower devices.
			// Cold starts can spend tens of seconds finishing apk work inside proot.
			// If we repair too early, we kill the first AXS instance just as it becomes
			// reachable and force an unnecessary reinstall loop.
			const initialPollRetries = axsRunning ? 10 : 1;
			if (!(await pollAxs(initialPollRetries))) {
				// pollAxs may have returned false because uninstall invalidated the
				// environment rather than a genuine startup failure.  Throw stale error
				// instead of the generic "not reachable" message so the caller cleans up
				// the tab silently.
				ensureAttemptIsStillValid();
				// repair 重试机制已移除，HTTP 不可达直接报错
				throw new Error("AXS HTTP endpoint is not reachable after startup");
			}

			// Session size must be measured after the mounted terminal has had a frame to lay
			// out. If PTY creation runs with the pre-fit grid, the first prompt is wrapped using
			// a bogus narrow width and later resize cannot un-break the already rendered line.
			await syncTerminalLayout();

			const requestBody = {
				cols: this.terminal.cols,
				rows: this.terminal.rows,
			};

			const parsePtyOpenError = (payload) => {
				if (typeof payload !== "string") {
					return null;
				}

				const trimmed = payload.trim();
				if (!trimmed.startsWith("{")) {
					return null;
				}

				try {
					const parsed = JSON.parse(trimmed);
					return typeof parsed?.error === "string" ? parsed.error : null;
				} catch {
					return null;
				}
			};

			const openTerminalSession = async () => {
				const response = await fetch(
					`http://localhost:${this.options.port}/terminals`,
					{
						method: "POST",
						headers: {
							"Content-Type": "application/json",
						},
						body: JSON.stringify(requestBody),
					},
				);

				if (!response.ok) {
					throw new Error(`HTTP error! status: ${response.status}`);
				}

				const rawData = await response.text();
				let pid = rawData.trim();
				if (pid.startsWith("{")) {
					try {
						const parsed = JSON.parse(pid);
						if (parsed.pid != null) {
							pid = String(parsed.pid);
						}
					} catch {}
				}
				return {
					data: pid,
					ptyOpenError: parsePtyOpenError(rawData),
				};
			};

			let sessionResult = await openTerminalSession();
			ensureAttemptIsStillValid();

			// Detect PTY errors from axs server (e.g. incompatible binary)
			if (sessionResult.ptyOpenError?.includes("Failed to open PTY")) {
				writeLifecycleLog("AXS PTY creation failed, refreshing axs binary and retrying...", true);

				await runSharedEnvironmentOperation("refresh", async () => {
					// Refresh replaces the shared axs binary/process. Older in-flight
					// session attempts must stop before they can attach to the old state.

					try {
						ensureAttemptIsStillValid();
						await Terminal.stopAxs();
					} catch (_) {
						/* ignore */
					}

					await Terminal.refreshAxs(
						(message) => writeLifecycleLog(message, false),
						(message) => writeLifecycleLog(message, true),
						true,
					);
					ensureAttemptIsStillValid();

					await startAxsAndWaitForReady(false);
					ensureAttemptIsStillValid();

					if (!(await pollAxs(1))) {
						ensureAttemptIsStillValid();
						throw new Error("Failed to restart AXS after refreshing binary");
					}
				});
				ensureAttemptIsStillValid();

				sessionResult = await openTerminalSession();
				ensureAttemptIsStillValid();
				if (sessionResult.ptyOpenError?.includes("Failed to open PTY")) {
					throw new Error("Failed to open PTY");
				}
			}

			this.pid = sessionResult.data.trim();
			return this.pid;
		} catch (error) {
			if (error?.name === "TerminalSessionStaleError") {
				throw error;
			}
			console.error("Failed to create terminal session:", error);
			throw error;
		}
	}

	/**
	 * Connect to terminal session via WebSocket
	 * @param {string} pid - Terminal PID
	 */
	async connectToSession(pid) {
		if (!this.serverMode) {
			throw new Error(
				"Terminal is in local mode, cannot connect to server session",
			);
		}

		const isReconnecting = !!pid;

		try {
			if (!pid) {
				pid = await this.createSession();
			}
		} catch (error) {
			if (error?.name === "TerminalSessionStaleError") {
				return;
			}
			throw error;
		}

		this.pid = pid;
		this._relocationSniffDisabled = false;
		clearTimeout(this._relocationSniffTimer);
		this._relocationSniffTimer = setTimeout(() => {
			this._relocationSniffDisabled = true;
		}, 15000);

		if (isReconnecting) {
			await this.syncExistingSessionLayoutBeforeReconnect();
		}

		const wsUrl = `ws://localhost:${this.options.port}/terminals/${pid}`;
		this._bootstrapOutputSeen = false;
		this._pendingFocusAfterBootstrap = false;

		this.websocket = new WebSocket(wsUrl);

		// The backend replays scrollback immediately after the WebSocket upgrade.
		// If AttachAddon is only installed in onopen, those first binary frames can
		// arrive before xterm is listening and the initial MOTD/prompt is lost.
		if (this.attachAddon) {
			try {
				this.attachAddon.dispose();
			} catch (_) {}
			this.attachAddon = null;
		}
		this.attachAddon = new AttachAddon(this.websocket);
		this.terminal.loadAddon(this.attachAddon);
		this.terminal.unicode.activeVersion = "11";

		this.websocket.onopen = () => {
			this.isConnected = true;
			this.onConnect?.();

			// Keep the initial PTY size from the session-create POST. Re-focusing here
			// opens the soft keyboard before the first shell output arrives, and that
			// viewport change can still corrupt the initial prompt layout on restored tabs.
			// Focus is deferred until bootstrap output is actually visible.
		};

		this.websocket.onmessage = (event) => {
			if (typeof event.data === "string") {
				try {
					const message = JSON.parse(event.data);
					if (message.type === "exit") {
						this.onProcessExit?.(message.data);
						return;
					}
				} catch (error) {
					// Not a JSON message, let attachAddon handle it
				}
			}
		};

		// Also sniff the data to detect critical Alpine container corruption (e.g. bash/readline broken)
		this.websocket.addEventListener("message", async (event) => {
			this.markBootstrapOutputReady();

			const MAX_SNIFF_BYTES = 4096;
			const containsBootstrapMarker = /motd|welcome|root@localhost|\[rc:|\[motd:/i;

			try {
				let text = "";
				if (typeof event.data === "string") {
					text = event.data.slice(0, MAX_SNIFF_BYTES);
				} else if (event.data instanceof ArrayBuffer) {
					const byteLength = Math.min(event.data.byteLength, MAX_SNIFF_BYTES);
					const view = new Uint8Array(event.data, 0, byteLength);
					text = new TextDecoder("utf-8", { fatal: false }).decode(view);
				} else if (event.data instanceof Blob) {
					const slice =
						event.data.size > MAX_SNIFF_BYTES
							? event.data.slice(0, MAX_SNIFF_BYTES)
							: event.data;
					text = await new Response(slice).text();
				}

				if (!text) {
					return;
				}

				// If the shell finishes bootstrap while the tab is hidden (e.g. automatic
				// tab switch), xterm keeps the hidden-tab viewport state and the first visible
				// paint can show stale scrollback instead of the live prompt/MOTD region.
				// Remember that hidden bootstrap arrived so the next visible-layout sync can
				// explicitly re-anchor the viewport once the tab becomes visible again.
				if (!this.container?.offsetParent && containsBootstrapMarker.test(text)) {
					this._hiddenBootstrapOutputNeedsVisibleAnchor = true;
				}

				if (this._relocationSniffDisabled) {
					return;
				}

				if (
					text.includes("Error relocating") &&
					text.includes("symbol not found")
				) {
					console.error(
						"Detected critical Alpine libc corruption! Terminating and triggering reinstall.",
					);
					if (this.onCrashData) {
						this.onCrashData("relocation_error");
					}
					this._relocationSniffDisabled = true;
					clearTimeout(this._relocationSniffTimer);
				}
			} catch (err) {}
		});

		this.websocket.onclose = (event) => {
			this.isConnected = false;
			this.onDisconnect?.();
		};

		this.websocket.onerror = (error) => {
			this.onError?.(error);
		};
	}

	async syncExistingSessionLayoutBeforeReconnect() {
		if (!this.serverMode || !this.pid || !this.container) {
			return;
		}

		const rect = this.container.getBoundingClientRect();
		if (rect.width < 10 || rect.height < 10) {
			return;
		}

		// Restored sessions replay scrollback immediately after the WebSocket upgrade.
		// Waiting only for ResizeObserver proves the tab has dimensions, but it does not
		// guarantee the corresponding POST /resize has already reached the backend. When
		// reconnect races ahead of that resize, the restored prompt can replay with the
		// previous narrow grid, causing split prompt text or a blank first frame.
		this.fit();
		if (this.terminal.cols > 0 && this.terminal.rows > 0) {
			await this.resizeTerminal(this.terminal.cols, this.terminal.rows);
		}
	}

	/**
	 * Resize terminal
	 * @param {number} cols - Number of columns
	 * @param {number} rows - Number of rows
	 */
	async resizeTerminal(cols, rows) {
		if (!this.pid || !this.serverMode) return;

		try {
			await fetch(
				`http://localhost:${this.options.port}/terminals/${this.pid}/resize`,
				{
					method: "POST",
					headers: {
						"Content-Type": "application/json",
					},
					body: JSON.stringify({ cols, rows }),
				},
			);
		} catch (error) {
			console.error("Failed to resize terminal:", error);
		}
	}

	/**
	 * Fit terminal to container
	 */
	fit() {
		if (this.fitAddon) {
			this.fitAddon.fit();
		}
	}

	/**
	 * Write data to terminal
	 * @param {string} data - Data to write
	 */
	write(data) {
		if (
			this.serverMode &&
			this.isConnected &&
			this.websocket &&
			this.websocket.readyState === WebSocket.OPEN
		) {
			// Send data through WebSocket instead of direct write
			this.websocket.send(data);
		} else {
			// For local mode or disconnected terminals, write directly
			this.terminal.write(data);
		}
	}

	rebuildWebglRenderer(reason = "unspecified") {
		if (!this.webglAddon) {
			return false;
		}

		try {
			// When a tab transitions from hidden to visible under Android WebView, the WebGL
			// renderer can remain bound to stale hidden-tab surfaces even after a normal
			// fit/refresh cycle. Rebuilding the renderer at that visibility boundary forces
			// xterm to bind fresh canvases to the live viewport.
			this.webglAddon.dispose();
			const addon = new WebglAddon();
			if (typeof addon.onContextLoss === "function") {
				addon.onContextLoss(() => this._handleWebglContextLoss());
			}
			this.terminal.loadAddon(addon);
			this.webglAddon = addon;
			return true;
		} catch (error) {
			console.error("Failed to rebuild WebGL renderer:", error);
			return false;
		}
	}

	/**
	 * Write line to terminal
	 * @param {string} data - Data to write
	 */
	writeln(data) {
		this.terminal.writeln(data);
	}

	/**
	 * Clear terminal
	 */
	clear() {
		this.terminal.clear();
	}

	markBootstrapOutputReady() {
		if (this._bootstrapOutputSeen) {
			return;
		}

		this._bootstrapOutputSeen = true;
		this.scheduleVisibleLayoutSync("bootstrap-output");
		if (this._pendingFocusAfterBootstrap) {
			this._pendingFocusAfterBootstrap = false;
			this.focusWhenReady();
		}
	}

	scheduleVisibleLayoutSync(reason = "unspecified") {
		if (this._visibleLayoutSyncFrame !== null) {
			cancelAnimationFrame?.(this._visibleLayoutSyncFrame);
			this._visibleLayoutSyncFrame = null;
		}
		if (this._visibleLayoutSyncTimeout !== null) {
			clearTimeout(this._visibleLayoutSyncTimeout);
			this._visibleLayoutSyncTimeout = null;
		}

		const runSync = () => {
			this._visibleLayoutSyncFrame = null;
			this.syncVisibleLayout();
		};

		if (typeof requestAnimationFrame === "function") {
			this._visibleLayoutSyncFrame = requestAnimationFrame(runSync);
		} else {
			setTimeout(runSync, 0);
		}

		// The black block can reappear one more frame later when WebView finishes the IME
		// viewport scroll after xterm already fit to the new height. Run one delayed sync in
		// the settled layout as well so the relocated xterm layer snaps back into place.
		this._visibleLayoutSyncTimeout = setTimeout(() => {
			this._visibleLayoutSyncTimeout = null;
			this.syncVisibleLayout();
		}, 180);
	}

	bindVisualViewportLayoutSync() {
		if (this._visualViewportSyncHandler) {
			return;
		}

		// ResizeObserver covers the terminal container itself, but Android WebView can apply
		// an extra visualViewport scroll after the IME animation settles. That late shift can
		// leave a non-scrollable black block, so visible-layout correction must also listen
		// to visualViewport changes directly.
		this._visualViewportSyncHandler = (event) => {
			this.scheduleVisibleLayoutSync("visual-viewport");
		};

		window.addEventListener("resize", this._visualViewportSyncHandler, {
			passive: true,
		});
		window.visualViewport?.addEventListener(
			"resize",
			this._visualViewportSyncHandler,
			{ passive: true },
		);
		window.visualViewport?.addEventListener(
			"scroll",
			this._visualViewportSyncHandler,
			{ passive: true },
		);
	}

	unbindVisualViewportLayoutSync() {
		if (!this._visualViewportSyncHandler) {
			return;
		}

		window.removeEventListener("resize", this._visualViewportSyncHandler);
		window.visualViewport?.removeEventListener(
			"resize",
			this._visualViewportSyncHandler,
		);
		window.visualViewport?.removeEventListener(
			"scroll",
			this._visualViewportSyncHandler,
		);
		this._visualViewportSyncHandler = null;
	}

	syncVisibleLayout() {
		if (!this.container || !this.terminal) {
			return;
		}

		const rect = this.container.getBoundingClientRect();
		if (rect.width < 10 || rect.height < 10) {
			return;
		}

		const xtermElement = this.container.querySelector(".xterm");
		const viewportElement = this.container.querySelector(".xterm-viewport");
		const isCurrentlyVisible = !!this.container.offsetParent;
		const becameVisible =
			isCurrentlyVisible && !this._wasVisibleOnLastLayoutSync;
		this._wasVisibleOnLastLayoutSync = isCurrentlyVisible;
		const isViewportRelocated =
			xtermElement &&
			Math.abs(xtermElement.getBoundingClientRect().top - rect.top) > 4;

		this.fit();
		if (becameVisible && this.webglAddon) {
			this.rebuildWebglRenderer("visible-layout-reactivation");
		}

		const shouldAnchorHiddenBootstrapViewport =
			becameVisible && this._hiddenBootstrapOutputNeedsVisibleAnchor;

		if (isViewportRelocated || shouldAnchorHiddenBootstrapViewport) {
			// When a previously hidden terminal is reactivated with the IME already affecting
			// layout, WebView/xterm can restore a stale internal viewport scroll offset, causing
			// xterm.top to go negative and leaving a black gap. Re-anchor both xterm's logical
			// viewport and the DOM scroller to the live bottom row as soon as the tab is visible.
			// The same re-anchor is required when bootstrap output arrived while the tab was
			// hidden: otherwise the first visible paint can show stale scrollback.
			this.container.scrollTop = 0;
			this.terminal.scrollToBottom();
			if (viewportElement) {
				viewportElement.scrollTop = viewportElement.scrollHeight;
			}
			this._hiddenBootstrapOutputNeedsVisibleAnchor = false;
		}

		if (this.terminal.rows > 0) {
			this.terminal.clearTextureAtlas?.();
			this.terminal.refresh(0, this.terminal.rows - 1);
		}
	}

	focusTerminalTextareaWithoutScroll() {
		// When reactivating a terminal while the IME is already open, WebView may
		// auto-scroll the focused xterm textarea using stale hidden-tab geometry,
		// shifting the xterm layer above the visible container. Focusing without
		// viewport scrolling keeps input active while leaving layout ownership to
		// the existing fit/resize path.
		this.terminal.textarea.focus({ preventScroll: true });
	}

	/**
	 * Focus terminal
	 */
	focusWhenReady() {
		if (this.serverMode && !this._bootstrapOutputSeen) {
			this._pendingFocusAfterBootstrap = true;
			return;
		}

		if (typeof requestAnimationFrame === "function") {
			requestAnimationFrame(() => {
				requestAnimationFrame(() => {
					this.focus();
				});
			});
			return;
		}

		setTimeout(() => {
			this.focus();
		}, 0);
	}

	/**
	 * Focus terminal
	 */
	focus() {
		this.focusTerminalTextareaWithoutScroll();
		this.scheduleVisibleLayoutSync("focus-immediate");
		if (this._focusLayoutSyncTimeout !== null) {
			clearTimeout(this._focusLayoutSyncTimeout);
		}
		// Android WebView can apply one more IME-driven viewport shift after the
		// textarea is already focused. Re-running the visible-layout sync slightly
		// later catches that final relocation and corrects the negative top position
		// that leaves a black block at the bottom.
		this._focusLayoutSyncTimeout = setTimeout(() => {
			this._focusLayoutSyncTimeout = null;
			this.scheduleVisibleLayoutSync("focus-delayed");
		}, 320);
	}

	/**
	 * Blur terminal
	 */
	blur() {
		this.terminal.blur();
	}

	/**
	 * Search in terminal
	 * @param {string} term - Search term
	 * @param {number} skip Number of search results to skip
	 * @param {boolean} backward Whether to search backward
	 */
	search(term, skip, backward) {
		if (this.searchAddon) {
			const searchOptions = {
				regex: appSettings.value.search.regExp || false,
				wholeWord: appSettings.value.search.wholeWord || false,
				caseSensitive: appSettings.value.search.caseSensitive || false,
				decorations: {
					matchBorder: "#FFA500",
					activeMatchBorder: "#FFFF00",
				},
			};
			if (!term) {
				return false;
			}

			if (backward) {
				return this.searchAddon.findPrevious(term, searchOptions);
			} else {
				return this.searchAddon.findNext(term, searchOptions);
			}
		}
		return false;
	}

	/**
	 * Update terminal theme
	 * @param {object|string} theme - Theme object or theme name
	 */
	updateTheme(theme) {
		if (typeof theme === "string") {
			theme = TerminalThemeManager.getTheme(theme);
		}
		this.options.theme = { ...this.options.theme, ...theme };
		this.terminal.options.theme = this.options.theme;
	}

	/**
	 * Update terminal options
	 * @param {object} options - Options to update
	 */
	updateOptions(options) {
		Object.keys(options).forEach((key) => {
			if (key === "theme") {
				this.updateTheme(options.theme);
			} else {
				this.terminal.options[key] = options[key];
				this.options[key] = options[key];
			}
		});
	}

	/**
	 * Load image addon
	 */
	loadImageAddon() {
		if (!this.imageAddon) {
			try {
				this.imageAddon = new ImageAddon();
				this.terminal.loadAddon(this.imageAddon);
			} catch (error) {
				console.error("Failed to load ImageAddon:", error);
			}
		}
	}

	/**
	 * Dispose image addon
	 */
	disposeImageAddon() {
		if (this.imageAddon) {
			try {
				this.imageAddon.dispose();
				this.imageAddon = null;
			} catch (error) {
				console.error("Failed to dispose ImageAddon:", error);
			}
		}
	}

	/**
	 * Update image support setting
	 * @param {boolean} enabled - Whether to enable image support
	 */
	updateImageSupport(enabled) {
		if (enabled) {
			this.loadImageAddon();
		} else {
			this.disposeImageAddon();
		}
	}

	/**
	 * Load ligatures addon
	 */
	loadLigaturesAddon() {
		if (!this.ligaturesAddon) {
			try {
				this.ligaturesAddon = new LigaturesAddon();
				this.terminal.loadAddon(this.ligaturesAddon);
			} catch (error) {
				console.error("Failed to load LigaturesAddon:", error);
			}
		}
	}

	/**
	 * Dispose ligatures addon
	 */
	disposeLigaturesAddon() {
		if (this.ligaturesAddon) {
			try {
				this.ligaturesAddon.dispose();
				this.ligaturesAddon = null;
			} catch (error) {
				console.error("Failed to dispose LigaturesAddon:", error);
			}
		}
	}

	/**
	 * Update font ligatures setting
	 * @param {boolean} enabled - Whether to enable font ligatures
	 */
	updateFontLigatures(enabled) {
		if (enabled) {
			this.loadLigaturesAddon();
		} else {
			this.disposeLigaturesAddon();
		}
	}

	/**
	 * Load terminal font if it's not already loaded
	 */
	async loadTerminalFont() {
		// Use original name without quotes for Acode fonts.get
		const fontFamily = this.options.fontFamily
			.replace(/^"|"$/g, "")
			.replace(/",\s*monospace$/, "");
		if (fontFamily && fonts.get(fontFamily)) {
			try {
				await fonts.loadFont(fontFamily);
				// Make Xterm.js aware that the font is fully loaded
				// Setting options.fontFamily triggers a re-eval of character dimensions
				if (this.terminal) {
					this.terminal.options.fontFamily = `"${fontFamily}", monospace`;
					if (this.webglAddon) {
						try {
							this.webglAddon.clearTextureAtlas();
						} catch (e) {}
					}
					// Ensure terminal dimensions are updated after font load changes char size
					setTimeout(() => this.fit(), 100);
				}
			} catch (error) {
				console.warn(`Failed to load terminal font ${fontFamily}:`, error);
			}
		}
	}

	/**
	 * Increase terminal font size
	 */
	increaseFontSize() {
		const currentSize = this.terminal.options.fontSize;
		const newSize = Math.min(currentSize + 1, 24); // Max font size 24
		this.updateFontSize(newSize);
	}

	/**
	 * Decrease terminal font size
	 */
	decreaseFontSize() {
		const currentSize = this.terminal.options.fontSize;
		const newSize = Math.max(currentSize - 1, 8); // Min font size 8
		this.updateFontSize(newSize);
	}

	/**
	 * Update terminal font size and refresh display
	 */
	updateFontSize(fontSize) {
		if (fontSize === this.terminal.options.fontSize) return;

		this.terminal.options.fontSize = fontSize;
		this.options.fontSize = fontSize;

		// Update terminal settings properly
		const currentSettings = appSettings.value.terminalSettings || {};
		const updatedSettings = { ...currentSettings, fontSize };
		appSettings.update({ terminalSettings: updatedSettings }, false);

		// Refresh terminal display
		this.terminal.refresh(0, this.terminal.rows - 1);

		// Fit terminal to container after font size change to prevent empty space
		setTimeout(() => {
			if (this.fitAddon) {
				this.fitAddon.fit();
			}
		}, 50);

		// Update touch selection cell dimensions if it exists
		if (this.touchSelection) {
			setTimeout(() => {
				this.touchSelection.updateCellDimensions();
			}, 100);
		}
	}

	/**
	 * Terminate terminal session
	 */
	async terminate() {
		clearTimeout(this._relocationSniffTimer);
		this._relocationSniffDisabled = true;
		if (this._focusLayoutSyncTimeout !== null) {
			clearTimeout(this._focusLayoutSyncTimeout);
			this._focusLayoutSyncTimeout = null;
		}
		if (this._visibleLayoutSyncFrame !== null) {
			cancelAnimationFrame?.(this._visibleLayoutSyncFrame);
			this._visibleLayoutSyncFrame = null;
		}
		if (this._visibleLayoutSyncTimeout !== null) {
			clearTimeout(this._visibleLayoutSyncTimeout);
			this._visibleLayoutSyncTimeout = null;
		}
		this.unbindVisualViewportLayoutSync();

		if (this.websocket) {
			this.websocket.close();
		}

		if (this.pid && this.serverMode) {
			try {
				await fetch(
					`http://localhost:${this.options.port}/terminals/${this.pid}/terminate`,
					{
						method: "POST",
					},
				);
			} catch {
				// Expected: terminal process may have already exited and acodex-server disconnected
			}
		}
	}

	/**
	 * Dispose terminal
	 */
	dispose() {
		this._isDisposed = true;
		this.terminate();

		// Dispose touch selection
		if (this.touchSelection) {
			this.touchSelection.destroy();
			this.touchSelection = null;
		}

		// Dispose addons
		this.disposeImageAddon();
		this.disposeLigaturesAddon();

		if (this.terminal) {
			this.terminal.dispose();
		}

		if (this.container) {
			this.container.remove();
		}
	}

	// Event handlers (can be overridden)
	onConnect() {}
	onDisconnect() {}
	onError(error) {}
	onTitleChange(title) {}
	onBell() {}
	onProcessExit(exitData) {}
}

// Internal helpers for WebGL renderer lifecycle
TerminalComponent.prototype._handleWebglContextLoss = function () {
	try {
		console.warn("WebGL context lost; falling back to canvas renderer");
		try {
			this.webglAddon?.dispose?.();
		} catch {}
		this.webglAddon = null;
	} catch (e) {
		console.error("Error handling WebGL context loss:", e);
	}
};
