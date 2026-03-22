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
const pushTerminalSessionDebugLog = (event, payload = {}, level = "info") => { // 仅调试用
	if (typeof window === "undefined" || typeof window.__HDC_DEBUG_PUSH !== "function") return; // 仅调试用
	window.__HDC_DEBUG_PUSH({ // 仅调试用
		type: "console", // 仅调试用
		level, // 仅调试用
		args: ["[terminal-session]", event, payload], // 仅调试用
		timestamp: Date.now(), // 仅调试用
	}); // 仅调试用
}; // 仅调试用

const sanitizeTerminalDebugPreview = (value) => { // 仅调试用
	if (typeof value !== "string" || value.length === 0) return ""; // 仅调试用
	return value // 仅调试用
		.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "<CSI>") // 仅调试用
		.replace(/\r/g, "\\r") // 仅调试用
		.replace(/\n/g, "\\n") // 仅调试用
		.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, (char) => { // 仅调试用
			const hex = char.charCodeAt(0).toString(16).padStart(2, "0"); // 仅调试用
			return `\\x${hex}`; // 仅调试用
		}); // 仅调试用
}; // 仅调试用

const summarizeTerminalDebugPreview = (value, limit = 240) => { // 仅调试用
	const sanitized = sanitizeTerminalDebugPreview(value); // 仅调试用
	if (sanitized.length <= limit) return sanitized; // 仅调试用
	return `${sanitized.slice(0, limit)}...`; // 仅调试用
}; // 仅调试用

const summarizeTerminalBufferLines = (terminal, maxLines = 3) => { // 仅调试用
	const buffer = terminal?.buffer?.active; // 仅调试用
	if (!buffer || typeof buffer.length !== "number") return []; // 仅调试用
	const start = Math.max(0, buffer.length - maxLines); // 仅调试用
	const lines = []; // 仅调试用
	for (let index = start; index < buffer.length; index += 1) { // 仅调试用
		const line = buffer.getLine(index); // 仅调试用
		const text = line?.translateToString?.(true) || ""; // 仅调试用
		lines.push({ // 仅调试用
			index, // 仅调试用
			text: summarizeTerminalDebugPreview(text, 160), // 仅调试用
		}); // 仅调试用
	} // 仅调试用
	return lines; // 仅调试用
}; // 仅调试用

const collectTerminalVisibilitySnapshot = (component) => { // 仅调试用
	const container = component?.container; // 仅调试用
	const terminal = component?.terminal; // 仅调试用
	const rect = container?.getBoundingClientRect?.() || null; // 仅调试用
	return { // 仅调试用
		hasOffsetParent: !!container?.offsetParent, // 仅调试用
		containerWidth: rect ? Math.round(rect.width) : null, // 仅调试用
		containerHeight: rect ? Math.round(rect.height) : null, // 仅调试用
		rows: terminal?.rows ?? null, // 仅调试用
		cols: terminal?.cols ?? null, // 仅调试用
		bufferLength: terminal?.buffer?.active?.length ?? null, // 仅调试用
		bufferViewportY: terminal?.buffer?.active?.viewportY ?? null, // 仅调试用
		bufferTail: summarizeTerminalBufferLines(terminal), // 仅调试用
	}; // 仅调试用
}; // 仅调试用

const collectTerminalRenderSnapshot = (component) => { // 仅调试用
	const container = component?.container; // 仅调试用
	const terminal = component?.terminal; // 仅调试用
	const xtermElement = container?.querySelector?.(".xterm") || null; // 仅调试用
	const screenElement = container?.querySelector?.(".xterm-screen") || null; // 仅调试用
	const viewportElement = container?.querySelector?.(".xterm-viewport") || null; // 仅调试用
	const canvases = Array.from(screenElement?.querySelectorAll?.("canvas") || []); // 仅调试用
	const core = terminal?._core || null; // 仅调试用
	const renderService = core?._renderService || null; // 仅调试用
	const dimensions = renderService?.dimensions || null; // 仅调试用
	const xtermRect = xtermElement?.getBoundingClientRect?.() || null; // 仅调试用
	const screenRect = screenElement?.getBoundingClientRect?.() || null; // 仅调试用
	const viewportRect = viewportElement?.getBoundingClientRect?.() || null; // 仅调试用
	return { // 仅调试用
		rendererType: renderService?._renderer?.constructor?.name || null, // 仅调试用
		xtermClientWidth: xtermElement?.clientWidth ?? null, // 仅调试用
		xtermClientHeight: xtermElement?.clientHeight ?? null, // 仅调试用
		xtermWidth: xtermRect ? Math.round(xtermRect.width) : null, // 仅调试用
		xtermHeight: xtermRect ? Math.round(xtermRect.height) : null, // 仅调试用
		screenClientWidth: screenElement?.clientWidth ?? null, // 仅调试用
		screenClientHeight: screenElement?.clientHeight ?? null, // 仅调试用
		screenWidth: screenRect ? Math.round(screenRect.width) : null, // 仅调试用
		screenHeight: screenRect ? Math.round(screenRect.height) : null, // 仅调试用
		viewportClientWidth: viewportElement?.clientWidth ?? null, // 仅调试用
		viewportClientHeight: viewportElement?.clientHeight ?? null, // 仅调试用
		viewportWidth: viewportRect ? Math.round(viewportRect.width) : null, // 仅调试用
		viewportHeight: viewportRect ? Math.round(viewportRect.height) : null, // 仅调试用
		viewportScrollTop: viewportElement?.scrollTop ?? null, // 仅调试用
		viewportScrollHeight: viewportElement?.scrollHeight ?? null, // 仅调试用
		bufferBaseY: terminal?.buffer?.active?.baseY ?? null, // 仅调试用
		bufferCursorY: terminal?.buffer?.active?.cursorY ?? null, // 仅调试用
		bufferCursorX: terminal?.buffer?.active?.cursorX ?? null, // 仅调试用
		cssCellWidth: dimensions?.css?.cell?.width ?? null, // 仅调试用
		cssCellHeight: dimensions?.css?.cell?.height ?? null, // 仅调试用
		cssCanvasWidth: dimensions?.css?.canvas?.width ?? null, // 仅调试用
		cssCanvasHeight: dimensions?.css?.canvas?.height ?? null, // 仅调试用
		deviceCanvasWidth: dimensions?.device?.canvas?.width ?? null, // 仅调试用
		deviceCanvasHeight: dimensions?.device?.canvas?.height ?? null, // 仅调试用
		canvasCount: canvases.length, // 仅调试用
		canvases: canvases.slice(0, 2).map((canvas) => ({ // 仅调试用
			width: canvas.width, // 仅调试用
			height: canvas.height, // 仅调试用
			clientWidth: canvas.clientWidth, // 仅调试用
			clientHeight: canvas.clientHeight, // 仅调试用
		})), // 仅调试用
	}; // 仅调试用
}; // 仅调试用

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
		this._bootstrapFrameLogCount = 0; // 仅调试用
		this._bootstrapFrameBytesSeen = 0; // 仅调试用
		this._sessionProcessSnapshotPromise = null; // 仅调试用
		this._lastVisibleLayoutSyncReason = "init"; // 仅调试用
		this._layoutSyncSequence = 0; // 仅调试用
		this._renderEventLogCount = 0; // 仅调试用
		this._postRefreshStateLogCount = 0; // 仅调试用

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

		this.terminal.onRender?.((event) => { // 仅调试用
			if (this._renderEventLogCount >= 8) { // 仅调试用
				return; // 仅调试用
			} // 仅调试用
			this._renderEventLogCount += 1; // 仅调试用
			pushTerminalSessionDebugLog( // 仅调试用
				"xterm-render", // 仅调试用
				{ // 仅调试用
					name: this.terminalDisplayName || null, // 仅调试用
					pid: this.pid || null, // 仅调试用
					start: event?.start ?? null, // 仅调试用
					end: event?.end ?? null, // 仅调试用
					visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
					render: collectTerminalRenderSnapshot(this), // 仅调试用
				}, // 仅调试用
				this.container?.offsetParent ? "info" : "warn", // 仅调试用
			); // 仅调试用
		}); // 仅调试用

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
						// Terminal 1's black block came from restoring a stale viewportY after a
						// hidden-tab/IME height change while the prompt was already at the bottom.
						// Preserving the old line index in that state replays a scroll offset that no
						// longer matches the new viewport height, so xterm keeps the DOM layer shifted
						// above its container. If we were already at the live bottom, re-anchor to the
						// live bottom instead of replaying the stale viewportY.
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

					// The remaining Terminal 1 black block happens after the tab is already visible:
					// IME animation shrinks the viewport, xterm recomputes rows, and only then does
					// WebView reapply a stale focused-textarea scroll offset that pushes the entire
					// .xterm layer above the container again. Running the visible-layout correction
					// once more after the debounced resize settles fixes that late relocation, and
					// also makes hidden terminals that received MOTD while inactive repaint correctly
					// when they become the active tab.
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
			// PTY size, which is why Terminal 2/3 still hard-wrap on first paint.
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
			let observedEnvironmentGeneration = terminalEnvironmentGeneration;
			const ensureAttemptIsStillValid = () => {
				if (this._isDisposed) {
					pushTerminalSessionDebugLog( // 仅调试用
						"session-stale", // 仅调试用
						{ // 仅调试用
							name: this.terminalDisplayName || null, // 仅调试用
							pid: this.pid || null, // 仅调试用
							initializationAttemptId: this._debugInitializationAttemptId ?? null, // 仅调试用
							reason: "disposed", // 仅调试用
							observedEnvironmentGeneration, // 仅调试用
							currentEnvironmentGeneration: terminalEnvironmentGeneration, // 仅调试用
						}, // 仅调试用
						"warn", // 仅调试用
					); // 仅调试用
					throw new TerminalSessionStaleError();
				}

				// Terminal startup mutates a single shared AXS/rootfs environment.
				// If another terminal has already created a newer healthy session,
				// this older async flow must fail fast instead of repairing and
				// tearing down the newer instance underneath it.
				if (terminalEnvironmentGeneration !== observedEnvironmentGeneration) {
					pushTerminalSessionDebugLog( // 仅调试用
						"session-stale", // 仅调试用
						{ // 仅调试用
							name: this.terminalDisplayName || null, // 仅调试用
							pid: this.pid || null, // 仅调试用
							initializationAttemptId: this._debugInitializationAttemptId ?? null, // 仅调试用
							reason: "environment-generation-changed", // 仅调试用
							observedEnvironmentGeneration, // 仅调试用
							currentEnvironmentGeneration: terminalEnvironmentGeneration, // 仅调试用
						}, // 仅调试用
						"warn", // 仅调试用
					); // 仅调试用
					throw new TerminalSessionStaleError();
				}
			};

			const markSharedEnvironmentChanged = (reason = "unspecified") => { // 仅调试用
				terminalEnvironmentGeneration += 1;
				observedEnvironmentGeneration = terminalEnvironmentGeneration;
				pushTerminalSessionDebugLog( // 仅调试用
					"shared-environment-generation-bump", // 仅调试用
					{ // 仅调试用
						name: this.terminalDisplayName || null, // 仅调试用
						pid: this.pid || null, // 仅调试用
						initializationAttemptId: this._debugInitializationAttemptId ?? null, // 仅调试用
						reason, // 仅调试用
						newGeneration: terminalEnvironmentGeneration, // 仅调试用
					}, // 仅调试用
				); // 仅调试用
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
					await new Promise((r) => setTimeout(r, intervalMs));
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
					this.terminal.write(
						`${isError ? "\x1b[31m" : ""}${cleanMessage}\x1b[0m\r\n`,
					);
				}
				if (isError) {
					console.error(message);
				} else {
					console.log(message);
				}
			};

			const runSharedEnvironmentOperation = async (type, run) => {
				if (this.environmentCoordinator?.runExclusive) {
					return this.environmentCoordinator.runExclusive({ type, run });
				}

				return run();
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
					// bogus tiny value, and the subsequent POST /terminals creates a PTY that
					// hard-wraps root@localhost on Terminal 2/3 before any later resize can fix it.
					// Only pre-fit when the terminal currently has a real renderable layout.
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
					return startResult;
				}

				await Promise.race([
					readyPromise,
					new Promise((_, reject) => {
						readyTimeoutId = setTimeout(() => {
							reject(new Error("AXS did not emit a ready event"));
						}, 15000);
					}),
				]);
			};

			let axsStartupFailed = false;
			if (!axsRunning) {
				try {
					await runSharedEnvironmentOperation("startup", async () => {
						ensureAttemptIsStillValid();
						const sharedAxsRunning = await Terminal.isAxsRunning();
						ensureAttemptIsStillValid();
						if (!sharedAxsRunning) {
							// Starting/stopping AXS changes the single shared terminal runtime.
							// Bump the shared-environment generation here so older attempts
							// fail fast, while this owner continues on the new generation.
							markSharedEnvironmentChanged("startup"); // 仅调试用
							try {
								await startAxsAndWaitForReady(false);
							} catch (startupError) {
								const startupMessage = String(startupError?.message || "");

								// Freshly bootstrapped proot can occasionally die with exit 182
								// before init-alpine.sh even starts, then succeed immediately on
								// the next identical launch. Retry exactly once here so that this
								// transient cold-start failure is not misreported as installation
								// failure or escalated into an unnecessary full repair.
								if (!startupMessage.includes("exit 182")) {
									throw startupError;
								}

								writeLifecycleLog(
									"AXS cold start exited with 182 before readiness; retrying launch once.",
									true,
								);
								ensureAttemptIsStillValid();
								await startAxsAndWaitForReady(false);
							}
						}
					});
					ensureAttemptIsStillValid();
				} catch (startupError) {
					if (
						startupError?.name === "TerminalSessionStaleError" ||
						startupError?.sharedEnvironmentInterrupted
					) {
						throw startupError;
					}
					// AXS process exited before becoming ready (e.g. exit 182 on a fresh
					// install where the Alpine environment is in a degraded state). Fall
					// through to the repair path which reinstalls the environment.
					writeLifecycleLog(
						`AXS startup failed: ${startupError.message}`,
						true,
					);
					axsStartupFailed = true;
					ensureAttemptIsStillValid();
				}
			}

			// Always wait for the HTTP endpoint, even if the PID is already alive.
			// kill -0 only tells us the outer process exists; the embedded server may
			// still be starting, especially after crash recovery on slower devices.
			// Cold starts can spend tens of seconds finishing apk work inside proot.
			// If we repair too early, we kill the first AXS instance just as it becomes
			// reachable and force an unnecessary reinstall loop.
			const initialPollRetries = axsRunning && !axsStartupFailed ? 10 : 1;
			if (axsStartupFailed || !(await pollAxs(initialPollRetries))) {
				ensureAttemptIsStillValid();
				await runSharedEnvironmentOperation("repair", async () => {
					// AXS failed to become reachable — attempt auto-repair
					toast("Repairing terminal environment...");

					// Repair tears down and rebuilds the shared runtime. Once repair starts,
					// any older concurrent createSession flow must become stale instead of
					// continuing with assumptions from the pre-repair environment.
					markSharedEnvironmentChanged("repair"); // 仅调试用

					try {
						ensureAttemptIsStillValid();
						await Terminal.stopAxs();
					} catch (_) {
						/* ignore */
					}

					const repairOk = await Terminal.startAxs(
						true,
						(message) => writeLifecycleLog(message, false),
						(message) => writeLifecycleLog(message, true),
					);
					ensureAttemptIsStillValid();
					if (!repairOk) {
						try {
							ensureAttemptIsStillValid();
							await Terminal.resetConfigured();
						} catch (_) {
							/* ignore */
						}
						throw new Error("AXS repair failed");
					}

					await startAxsAndWaitForReady(false);
					ensureAttemptIsStillValid();

					if (!(await pollAxs(1))) {
						ensureAttemptIsStillValid();
						try {
							ensureAttemptIsStillValid();
							await Terminal.resetConfigured();
						} catch (_) {
							/* ignore */
						}
						throw new Error("Failed to start AXS server after repair attempt");
					}
				});
				ensureAttemptIsStillValid();
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
				// 仅调试用: parse JSON response to extract PID and launch_detail
				// (axs now returns {"pid":N,"launch_detail":"..."} for PTY backend diagnostics)
				let pid = rawData.trim();
				let launchDetail = null;
				if (pid.startsWith("{")) {
					try {
						const parsed = JSON.parse(pid);
						if (parsed.pid != null) {
							pid = String(parsed.pid);
							launchDetail = parsed.launch_detail || null;
						}
					} catch {}
				}
				return {
					data: pid,
					ptyOpenError: parsePtyOpenError(rawData),
					launchDetail, // 仅调试用
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
					markSharedEnvironmentChanged("refresh"); // 仅调试用

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
			if (sessionResult.launchDetail) { // 仅调试用
				pushTerminalSessionDebugLog("launch-detail", { // 仅调试用
					name: this.terminalDisplayName, // 仅调试用
					pid: this.pid, // 仅调试用
					launchDetail: sessionResult.launchDetail, // 仅调试用
				}); // 仅调试用
			} // 仅调试用
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
				pushTerminalSessionDebugLog( // 仅调试用
					"connect-stale-return", // 仅调试用
					{ // 仅调试用
						name: this.terminalDisplayName || null, // 仅调试用
						pid: this.pid || pid || null, // 仅调试用
						isReconnecting, // 仅调试用
						initializationAttemptId: this._debugInitializationAttemptId ?? null, // 仅调试用
					}, // 仅调试用
					"warn", // 仅调试用
				); // 仅调试用
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
		this._bootstrapFrameLogCount = 0; // 仅调试用
		this._bootstrapFrameBytesSeen = 0; // 仅调试用
		this._sessionProcessSnapshotPromise = null; // 仅调试用
		pushTerminalSessionDebugLog( // 仅调试用
			"connect-begin", // 仅调试用
			{ // 仅调试用
				name: this.terminalDisplayName || null, // 仅调试用
				pid: pid || null, // 仅调试用
				isReconnecting, // 仅调试用
				cols: this.terminal?.cols ?? null, // 仅调试用
				rows: this.terminal?.rows ?? null, // 仅调试用
				containerWidth: this.container ? Math.round(this.container.getBoundingClientRect().width) : null, // 仅调试用
				containerHeight: this.container ? Math.round(this.container.getBoundingClientRect().height) : null, // 仅调试用
			}, // 仅调试用
		); // 仅调试用
		void this.captureSessionProcessSnapshot(); // 仅调试用

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
			pushTerminalSessionDebugLog( // 仅调试用
				"websocket-open", // 仅调试用
				{ // 仅调试用
					name: this.terminalDisplayName || null, // 仅调试用
					pid: this.pid || null, // 仅调试用
					readyState: this.websocket?.readyState ?? null, // 仅调试用
				}, // 仅调试用
			); // 仅调试用
			this.onConnect?.();

			// Keep the initial PTY size from the session-create POST. Re-focusing here
			// opens the soft keyboard before the first shell output arrives, and that
			// viewport change can still corrupt the initial prompt layout on restored tabs.
			// Focus is deferred until bootstrap output is actually visible.
		};

		this.websocket.onmessage = (event) => {
			// Exit events can race with hidden-tab bootstrap. Log the exact client-side
			// visibility/render state at receipt time so backend exit_code=182 can be
			// separated from UI materialization timing on the next reproduction. 仅调试用
			if (typeof event.data === "string") {
				try {
					const message = JSON.parse(event.data);
					if (message.type === "exit") {
						pushTerminalSessionDebugLog( // 仅调试用
							"process-exit-received", // 仅调试用
							{ // 仅调试用
								name: this.terminalDisplayName || null, // 仅调试用
								pid: this.pid || null, // 仅调试用
								exitData: message.data || null, // 仅调试用
								readyState: this.websocket?.readyState ?? null, // 仅调试用
								bootstrapFrameLogCount: this._bootstrapFrameLogCount ?? null, // 仅调试用
								bootstrapFrameBytesSeen: this._bootstrapFrameBytesSeen ?? null, // 仅调试用
								bootstrapOutputReady: !!this._bootstrapOutputReady, // 仅调试用
								visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
								render: collectTerminalRenderSnapshot(this), // 仅调试用
							}, // 仅调试用
							message.data?.exit_code === 0 ? "info" : "warn", // 仅调试用
						); // 仅调试用
						void this.captureSessionProcessSnapshot(); // 仅调试用
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
			let shouldCapturePostWriteBuffer = false; // 仅调试用

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

				if ( // 仅调试用
					this._bootstrapFrameLogCount < 3 && // 仅调试用
					this._bootstrapFrameBytesSeen < 768 // 仅调试用
				) { // 仅调试用
					this._bootstrapFrameLogCount += 1; // 仅调试用
					this._bootstrapFrameBytesSeen += text.length; // 仅调试用
					pushTerminalSessionDebugLog( // 仅调试用
						"bootstrap-frame", // 仅调试用
						{ // 仅调试用
							name: this.terminalDisplayName || null, // 仅调试用
							pid: this.pid || null, // 仅调试用
							frameIndex: this._bootstrapFrameLogCount, // 仅调试用
							byteLength: text.length, // 仅调试用
							preview: summarizeTerminalDebugPreview(text), // 仅调试用
							containsPrompt: /root@localhost|[$#]\s*$/.test(text), // 仅调试用
							containsMotdMarker: /motd|welcome|acode/i.test(text), // 仅调试用
							dataType: typeof event.data === "string" ? "text" : event.data?.constructor?.name || typeof event.data, // 仅调试用
						}, // 仅调试用
					); // 仅调试用
				} // 仅调试用

				if ( // 仅调试用
					this._bootstrapFrameLogCount <= 3 || // 仅调试用
					/motd|welcome|root@localhost|\[rc:|\[motd:/i.test(text) // 仅调试用
				) { // 仅调试用
					shouldCapturePostWriteBuffer = true; // 仅调试用
					pushTerminalSessionDebugLog( // 仅调试用
						"bootstrap-visibility", // 仅调试用
						{ // 仅调试用
							name: this.terminalDisplayName || null, // 仅调试用
							pid: this.pid || null, // 仅调试用
							preview: summarizeTerminalDebugPreview(text, 180), // 仅调试用
							rawPreview: summarizeTerminalDebugPreview(text, 320), // 仅调试用
							containsMotdMarker: /motd|welcome|acode/i.test(text), // 仅调试用
							visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
							render: collectTerminalRenderSnapshot(this), // 仅调试用
						}, // 仅调试用
						this.container?.offsetParent ? "info" : "warn", // 仅调试用
					); // 仅调试用
				} // 仅调试用

				if (shouldCapturePostWriteBuffer) { // 仅调试用
					setTimeout(() => { // 仅调试用
						pushTerminalSessionDebugLog( // 仅调试用
							"post-write-buffer", // 仅调试用
							{ // 仅调试用
								name: this.terminalDisplayName || null, // 仅调试用
								pid: this.pid || null, // 仅调试用
								visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
								render: collectTerminalRenderSnapshot(this), // 仅调试用
							}, // 仅调试用
							this.container?.offsetParent ? "info" : "warn", // 仅调试用
						); // 仅调试用
					}, 0); // 仅调试用
				} // 仅调试用

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

	async captureSessionProcessSnapshot() { // 仅调试用
		if (!this.serverMode || !this.pid || this._sessionProcessSnapshotPromise) { // 仅调试用
			return this._sessionProcessSnapshotPromise; // 仅调试用
		} // 仅调试用

		const executor = window?.Executor?.BackgroundExecutor || window?.Executor; // 仅调试用
		if (!executor || typeof executor.execute !== "function") { // 仅调试用
			return null; // 仅调试用
		} // 仅调试用

		const targetPid = String(this.pid); // 仅调试用
		const snapshotCommand = [ // 仅调试用
			`target_pid="${targetPid}"`, // 仅调试用
			`axs_pid="$(cat "$PREFIX/pid" 2>/dev/null)"`, // 仅调试用
			`target_ppid="$(awk '{print $4}' "/proc/$target_pid/stat" 2>/dev/null)"`, // 仅调试用
			`printf "target_pid=%s\\n" "$target_pid"`, // 仅调试用
			`printf "target_cmd="`, // 仅调试用
			`[ -r "/proc/$target_pid/cmdline" ] && tr '\\000' ' ' < "/proc/$target_pid/cmdline"`, // 仅调试用
			`printf "\\ntarget_ppid=%s\\n" "$target_ppid"`, // 仅调试用
			`printf "parent_cmd="`, // 仅调试用
			`[ -n "$target_ppid" ] && [ -r "/proc/$target_ppid/cmdline" ] && tr '\\000' ' ' < "/proc/$target_ppid/cmdline"`, // 仅调试用
			`printf "\\naxs_pid=%s\\n" "$axs_pid"`, // 仅调试用
			`printf "axs_cmd="`, // 仅调试用
			`[ -n "$axs_pid" ] && [ -r "/proc/$axs_pid/cmdline" ] && tr '\\000' ' ' < "/proc/$axs_pid/cmdline"`, // 仅调试用
			`printf "\\n"`, // 仅调试用
		].join('; '); // 仅调试用

		this._sessionProcessSnapshotPromise = executor // 仅调试用
			.execute(snapshotCommand, true) // 仅调试用
			.then((snapshot) => { // 仅调试用
				pushTerminalSessionDebugLog( // 仅调试用
					"session-process-snapshot", // 仅调试用
					{ // 仅调试用
						name: this.terminalDisplayName || null, // 仅调试用
						pid: this.pid || null, // 仅调试用
						snapshot: summarizeTerminalDebugPreview(snapshot, 400), // 仅调试用
					}, // 仅调试用
				); // 仅调试用
				return snapshot; // 仅调试用
			}) // 仅调试用
			.catch((error) => { // 仅调试用
				pushTerminalSessionDebugLog( // 仅调试用
					"session-process-snapshot-error", // 仅调试用
					{ // 仅调试用
						name: this.terminalDisplayName || null, // 仅调试用
						pid: this.pid || null, // 仅调试用
						errorMessage: error?.message || String(error), // 仅调试用
					}, // 仅调试用
					"warn", // 仅调试用
				); // 仅调试用
				return null; // 仅调试用
			}); // 仅调试用

		return this._sessionProcessSnapshotPromise; // 仅调试用
	} // 仅调试用

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
		// previous narrow grid, which is why Terminal 2/3 still showed split prompt text
		// and Terminal 1 could render a blank first frame after the keyboard resized it.
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
		pushTerminalSessionDebugLog( // 仅调试用
			"terminal-clear", // 仅调试用
			{ // 仅调试用
				name: this.terminalDisplayName || null, // 仅调试用
				pid: this.pid || null, // 仅调试用
				bootstrapOutputSeen: this._bootstrapOutputSeen, // 仅调试用
				bufferLength: this.terminal?.buffer?.active?.length ?? null, // 仅调试用
				viewportY: this.terminal?.buffer?.active?.viewportY ?? null, // 仅调试用
			}, // 仅调试用
			"warn", // 仅调试用
		); // 仅调试用
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
		this._lastVisibleLayoutSyncReason = reason; // 仅调试用
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
		// an extra visualViewport scroll after the IME animation settles. That late shift is
		// what leaves the small non-scrollable black block under Terminal 1, so visible-layout
		// correction must also listen to visualViewport changes directly.
		this._visualViewportSyncHandler = (event) => {
			this.scheduleVisibleLayoutSync(`visual-viewport-${event?.type || "unknown"}`); // 仅调试用
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
		const xtermRectBefore = xtermElement?.getBoundingClientRect() || null; // 仅调试用
		const viewportRectBefore = viewportElement?.getBoundingClientRect() || null; // 仅调试用
		const isViewportRelocated =
			xtermElement &&
			Math.abs(xtermElement.getBoundingClientRect().top - rect.top) > 4;
		const syncSequence = ++this._layoutSyncSequence; // 仅调试用

		this.fit();

		const xtermRectAfter = xtermElement?.getBoundingClientRect() || null; // 仅调试用
		const viewportRectAfter = viewportElement?.getBoundingClientRect() || null; // 仅调试用
		const isViewportStillRelocated = // 仅调试用
			xtermRectAfter && Math.abs(xtermRectAfter.top - rect.top) > 4; // 仅调试用

		if (isViewportRelocated || isViewportStillRelocated) { // 仅调试用
			pushTerminalSessionDebugLog( // 仅调试用
				"visible-layout-sync", // 仅调试用
				{ // 仅调试用
					name: this.terminalDisplayName || null, // 仅调试用
					pid: this.pid || null, // 仅调试用
					reason: this._lastVisibleLayoutSyncReason || null, // 仅调试用
					syncSequence, // 仅调试用
					containerTop: Math.round(rect.top), // 仅调试用
					containerHeight: Math.round(rect.height), // 仅调试用
					xtermTopBefore: xtermRectBefore ? Math.round(xtermRectBefore.top) : null, // 仅调试用
					xtermTopAfter: xtermRectAfter ? Math.round(xtermRectAfter.top) : null, // 仅调试用
					viewportTopBefore: viewportRectBefore ? Math.round(viewportRectBefore.top) : null, // 仅调试用
					viewportTopAfter: viewportRectAfter ? Math.round(viewportRectAfter.top) : null, // 仅调试用
					viewportScrollTop: viewportElement?.scrollTop ?? null, // 仅调试用
					rows: this.terminal?.rows ?? null, // 仅调试用
					cols: this.terminal?.cols ?? null, // 仅调试用
					wasRelocated: !!isViewportRelocated, // 仅调试用
					stillRelocated: !!isViewportStillRelocated, // 仅调试用
				}, // 仅调试用
				isViewportStillRelocated ? "warn" : "info", // 仅调试用
			); // 仅调试用
		} // 仅调试用

		if (isViewportRelocated) {
			// When a previously hidden terminal is reactivated with the IME already affecting
			// layout, WebView/xterm can restore the old internal viewport scroll offset before
			// the new visible height is applied. The runtime trace captured that as xterm.top < 0
			// while the terminal container itself stayed in place, which is exactly the large
			// black non-scrollable area the user still sees on Terminal 1. Re-anchor both xterm's
			// logical viewport and the DOM scroller to the live bottom row as soon as the tab is
			// visible so the rendered layer snaps back into the container immediately.
			const containerScrollTopBefore = this.container.scrollTop; // 仅调试用
			// WebView auto-scrolls the nearest scrollable ancestor (even overflow:hidden ones)
			// to keep the focused xterm textarea visible. This shifts the whole xterm layer
			// above the container, leaving a black gap at the bottom. Resetting the container's
			// own scrollTop to 0 snaps the content back into its correct position.
			this.container.scrollTop = 0;
			this.terminal.scrollToBottom();
			if (viewportElement) {
				viewportElement.scrollTop = viewportElement.scrollHeight;
			}
			const containerScrollTopAfter = this.container.scrollTop; // 仅调试用
			const xtermRectAfterFix = xtermElement?.getBoundingClientRect() || null; // 仅调试用
			pushTerminalSessionDebugLog( // 仅调试用
				"visible-layout-relocation-fix", // 仅调试用
				{ // 仅调试用
					name: this.terminalDisplayName || null, // 仅调试用
					pid: this.pid || null, // 仅调试用
					containerScrollTopBefore, // 仅调试用
					containerScrollTopAfter, // 仅调试用
					xtermTopAfterFix: xtermRectAfterFix ? Math.round(xtermRectAfterFix.top) : null, // 仅调试用
					containerTop: Math.round(rect.top), // 仅调试用
					fixedRelocation: xtermRectAfterFix ? Math.abs(xtermRectAfterFix.top - rect.top) <= 4 : null, // 仅调试用
				}, // 仅调试用
				"warn", // 仅调试用
			); // 仅调试用
		}

		if (this.terminal.rows > 0) {
			this.terminal.clearTextureAtlas?.();
			this.terminal.refresh(0, this.terminal.rows - 1);
			pushTerminalSessionDebugLog( // 仅调试用
				"visible-layout-buffer-snapshot", // 仅调试用
				{ // 仅调试用
					name: this.terminalDisplayName || null, // 仅调试用
					pid: this.pid || null, // 仅调试用
					reason: this._lastVisibleLayoutSyncReason || null, // 仅调试用
					visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
					render: collectTerminalRenderSnapshot(this), // 仅调试用
				}, // 仅调试用
				this.container?.offsetParent ? "info" : "warn", // 仅调试用
			); // 仅调试用
			if (this._postRefreshStateLogCount < 8) { // 仅调试用
				this._postRefreshStateLogCount += 1; // 仅调试用
				requestAnimationFrame?.(() => { // 仅调试用
					pushTerminalSessionDebugLog( // 仅调试用
						"visible-layout-post-refresh", // 仅调试用
						{ // 仅调试用
							name: this.terminalDisplayName || null, // 仅调试用
							pid: this.pid || null, // 仅调试用
							reason: this._lastVisibleLayoutSyncReason || null, // 仅调试用
							visibility: collectTerminalVisibilitySnapshot(this), // 仅调试用
							render: collectTerminalRenderSnapshot(this), // 仅调试用
						}, // 仅调试用
						this.container?.offsetParent ? "info" : "warn", // 仅调试用
					); // 仅调试用
				}); // 仅调试用
			} // 仅调试用
		}
	}

	focusTerminalTextareaWithoutScroll() {
		// When reactivating a terminal while the IME is already open, WebView may
		// auto-scroll the focused xterm textarea using stale hidden-tab geometry.
		// That shifts the whole xterm layer above the visible container, which is
		// exactly what the runtime diagnostics captured with a negative top value.
		// Focusing the textarea without viewport scrolling keeps input active while
		// leaving layout ownership to the existing fit/resize path.
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
		// later catches that final relocation and pulls Terminal 1 back from the
		// negative top position that leaves the black block at the bottom.
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
