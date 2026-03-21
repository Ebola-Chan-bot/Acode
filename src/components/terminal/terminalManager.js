/**
 * Terminal Manager
 * Handles terminal session creation and management
 */

import EditorFile from "lib/editorFile";
import TerminalComponent from "./terminal";
import TerminalTouchSelection from "./terminalTouchSelection";
import "@xterm/xterm/css/xterm.css";
import quickTools from "components/quickTools";
import toast from "components/toast";
import alert from "dialogs/alert";
import confirm from "dialogs/confirm";
import openFile from "lib/openFile";
import openFolder from "lib/openFolder";
import appSettings from "lib/settings";
import helpers from "utils/helpers";

const TERMINAL_SESSION_STORAGE_KEY = "acodeTerminalSessions";
const pushTerminalRestoreDebugLog = (event, payload = {}, level = "info") => { // 仅调试用
	if (typeof window === "undefined" || typeof window.__HDC_DEBUG_PUSH !== "function") return; // 仅调试用
	window.__HDC_DEBUG_PUSH({ // 仅调试用
		type: "console", // 仅调试用
		level, // 仅调试用
		args: ["[terminal-restore]", event, payload], // 仅调试用
		timestamp: Date.now(), // 仅调试用
	}); // 仅调试用
}; // 仅调试用

const consumeTerminalCloseTrigger = (terminalFile) => { // 仅调试用
	const trigger = terminalFile?._terminalCloseTrigger || null; // 仅调试用
	if (terminalFile) terminalFile._terminalCloseTrigger = null; // 仅调试用
	return trigger; // 仅调试用
}; // 仅调试用

class TerminalManager {
	constructor() {
		this.terminals = new Map();
		this.terminalCounter = 0;
		this.sharedEnvironmentOperation = null;
		this.reservedTerminalNumbers = new Set();
		this.nextSharedEnvironmentOperationId = 1;
		this.lastAlertedSharedEnvironmentInterruptionId = null;
	}

	writeSharedEnvironmentNotice(component, message, color = "36") {
		if (!component || typeof component.write !== "function") return;
		component.write(`\x1b[${color}m${message}\x1b[0m\r\n`);
	}

	createSharedEnvironmentInterruptedError(ownerName, operationTitle, operationId = null) {
		const error = new Error(
			`${ownerName}'s terminal ${operationTitle} was interrupted because that terminal was closed.`,
		);
		error.sharedEnvironmentInterrupted = true;
		error.sharedEnvironmentOperationId = operationId;
		return error;
		return error;
	}

	showSharedEnvironmentInterruptedAlertOnce(error) {
		if (!error?.sharedEnvironmentInterrupted) {
			return;
		}

		const operationId = error.sharedEnvironmentOperationId;
		if (
			operationId !== null &&
			operationId !== undefined &&
			this.lastAlertedSharedEnvironmentInterruptionId === operationId
		) {
			return;
		}

		this.lastAlertedSharedEnvironmentInterruptionId =
			operationId ?? this.lastAlertedSharedEnvironmentInterruptionId;
		alert(strings["error"], error.message);
	}

	getSharedEnvironmentOperationTitle(type) {
		switch (type) {
			case "startup":
				return "startup";
			case "install":
				return "installation";
			case "repair":
				return "repair";
			case "refresh":
				return "repair";
			case "uninstall":
				return "uninstall";
			case "uninstall-full":
				return "full uninstall";
			default:
				return "maintenance";
		}
	}

	async runSharedEnvironmentOperation({
		type,
		ownerName,
		ownerTerminalId = null,
		progressTerminal = null,
		run,
	}) {
		const progressComponent = progressTerminal?.component || null;
		const operationTitle = this.getSharedEnvironmentOperationTitle(type);

		if (this.sharedEnvironmentOperation) {
			const activeOperation = this.sharedEnvironmentOperation;
			const activeTitle = this.getSharedEnvironmentOperationTitle(
				activeOperation.type,
			);
			if (progressComponent) {
				this.writeSharedEnvironmentNotice(
					progressComponent,
					`Waiting for ${activeOperation.ownerName}'s terminal ${activeTitle} to finish...`,
				);
			}

			try {
				await activeOperation.promise;
				if (progressComponent && !progressComponent.isConnected) {
					// Waiter terminals are still empty at this point: they only contain the shared
					// "Waiting..." / "Rechecking..." notices. Keeping those lines makes the tab look
					// stuck even after the local re-check creates and connects a fresh PTY, because
					// the user lands on stale status text instead of the new MOTD/prompt. Clear the
					// transient wait buffer before resuming the waiter's normal startup path.
					progressComponent.clear();
				}

				// Waiters must resume via their own normal path after the owner finishes.
				// Reusing the owner's resolved promise skips the waiter's local re-checks,
				// which can leave that terminal stuck showing the wait message even though
				// the shared install/startup already completed successfully.
				return run();
			} catch (error) {
				const failureMessage = error?.sharedEnvironmentInterrupted
					? `Shared terminal ${activeTitle} was interrupted. Closing this terminal...`
					: `Shared terminal ${activeTitle} failed. Closing this terminal...`;
				if (progressComponent) {
					this.writeSharedEnvironmentNotice(
						progressComponent,
						failureMessage,
						"31",
					);
				}
				throw error;
			}
		}

		const operation = {
			id: this.nextSharedEnvironmentOperationId++,
			type,
			ownerName: ownerName || "Terminal maintenance",
			ownerTerminalId,
			interrupted: false,
			settled: false,
			interrupt: null,
			promise: null,
		};

		let rejectInterruptedOperation;
		const interruptedPromise = new Promise((_, reject) => {
			rejectInterruptedOperation = reject;
		});

		const runPromise = (async () => await run())();
		void runPromise.catch(() => {});

		operation.interrupt = (error) => {
			if (operation.interrupted || operation.settled) {
				return;
			}

			operation.interrupted = true;
			rejectInterruptedOperation(error);
		};

		operation.promise = Promise.race([
			runPromise,
			interruptedPromise,
		]).finally(() => {
			operation.settled = true;
			try {
			} finally {
				if (this.sharedEnvironmentOperation === operation) {
					this.sharedEnvironmentOperation = null;
				}
			}
		});

		this.sharedEnvironmentOperation = operation;
		return operation.promise;
	}

	interruptSharedEnvironmentOperationForTerminal(terminalId, terminalName) {
		const operation = this.sharedEnvironmentOperation;
		if (!operation || !terminalId) {
			return;
		}

		if (operation.ownerTerminalId !== terminalId) {
			return;
		}

		const operationTitle = this.getSharedEnvironmentOperationTitle(operation.type);
		operation.interrupt?.(
			this.createSharedEnvironmentInterruptedError(
				terminalName || operation.ownerName || "Shared terminal",
				operationTitle,
				operation.id,
			),
		);
	}

	closeAllTerminals(noticeMessage = null) {
		const terminals = Array.from(this.terminals.entries());
		pushTerminalRestoreDebugLog( // 仅调试用
			"close-all-terminals", // 仅调试用
			{ // 仅调试用
				noticeMessage: noticeMessage || null, // 仅调试用
				terminalIds: terminals.map(([terminalId]) => terminalId), // 仅调试用
			}, // 仅调试用
			"warn", // 仅调试用
		); // 仅调试用

		for (const [terminalId, terminal] of terminals) {
			if (noticeMessage) {
				this.writeSharedEnvironmentNotice(
					terminal.component,
					noticeMessage,
					"33",
				);
			}

			this.closeTerminal(terminalId, true);
		}
	}

	async uninstallTerminalEnvironment(deleteCache = false) {
		const type = deleteCache ? "uninstall-full" : "uninstall";
		await this.runSharedEnvironmentOperation({
			type,
			ownerName: "Settings",
			ownerTerminalId: null,
			run: async () => {
				this.closeAllTerminals(
					"Terminal environment is being uninstalled. Closing all terminal tabs...",
				);

				if (deleteCache) {
					await Terminal.uninstallFull();
				} else {
					await Terminal.uninstall();
				}

				return { success: true };
			},
		});
	}

	extractTerminalNumber(name) {
		if (!name) return null;
		const match = String(name).match(/^Terminal\s+(\d+)(?:\b| - )/i);
		if (!match) return null;
		const number = Number.parseInt(match[1], 10);
		return Number.isInteger(number) && number > 0 ? number : null;
	}

	getNextAvailableTerminalNumber() {
		const usedNumbers = new Set();

		for (const terminal of this.terminals.values()) {
			const number = terminal?.terminalNumber;
			if (Number.isInteger(number) && number > 0) {
				usedNumbers.add(number);
			}
		}

		for (const number of this.reservedTerminalNumbers.values()) {
			usedNumbers.add(number);
		}

		let nextNumber = 1;
		while (usedNumbers.has(nextNumber)) {
			nextNumber++;
		}

		return nextNumber;
	}

	async getPersistedSessions() {
		try {
			const stored = helpers.parseJSON(
				localStorage.getItem(TERMINAL_SESSION_STORAGE_KEY),
			);
			if (!Array.isArray(stored)) return [];
			if (!(await Terminal.isAxsRunning())) {
				return [];
			}
			return stored
				.map((entry) => {
					if (!entry) return null;
					if (typeof entry === "string") {
						return { pid: entry, name: `Terminal ${entry}` };
					}
					if (typeof entry === "object" && entry.pid) {
						const pid = String(entry.pid);
						return {
							pid,
							name: entry.name || `Terminal ${pid}`,
						};
					}
					return null;
				})
				.filter(Boolean);
		} catch (error) {
			console.error("Failed to read persisted terminal sessions:", error);
			return [];
		}
	}

	savePersistedSessions(sessions) {
		try {
			localStorage.setItem(
				TERMINAL_SESSION_STORAGE_KEY,
				JSON.stringify(sessions),
			);
		} catch (error) {
			console.error("Failed to persist terminal sessions:", error);
		}
	}

	async persistTerminalSession(pid, name) {
		if (!pid) return;

		const pidStr = String(pid);
		const sessions = await this.getPersistedSessions();
		const existingIndex = sessions.findIndex(
			(session) => session.pid === pidStr,
		);
		const sessionData = {
			pid: pidStr,
			name: name || `Terminal ${pidStr}`,
		};

		if (existingIndex >= 0) {
			sessions[existingIndex] = {
				...sessions[existingIndex],
				...sessionData,
			};
		} else {
			sessions.push(sessionData);
		}

		this.savePersistedSessions(sessions);
	}

	async removePersistedSession(pid) {
		if (!pid) return;

		const pidStr = String(pid);
		const sessions = await this.getPersistedSessions();
		const nextSessions = sessions.filter((session) => session.pid !== pidStr);

		if (nextSessions.length !== sessions.length) {
			this.savePersistedSessions(nextSessions);
		}
	}

	async restorePersistedSessions() {
		const sessions = await this.getPersistedSessions();

		if (!sessions.length) return;

		const manager = window.editorManager;
		const activeFileId = manager?.activeFile?.id;
		const restoredTerminals = [];
		const failedSessions = [];

		for (const session of sessions) {
			if (!session?.pid) continue;
			if (this.terminals.has(session.pid)) continue;

			try {
				const instance = await this.createServerTerminal({
					pid: session.pid,
					name: session.name,
					reconnecting: true,
					render: false,
					deferInitialRestoreActivation: true,
				});
				if (instance) restoredTerminals.push(instance);
			} catch (error) {
				console.error(
					`Failed to restore terminal session ${session.pid}:`,
					error,
				);
				failedSessions.push(session.name || session.pid);
				this.removePersistedSession(session.pid);
			}
		}

		// Show alert for failed sessions (don't await to not block UI)
		if (failedSessions.length > 0) {
			const message =
				failedSessions.length === 1
					? `Failed to restore terminal: ${failedSessions[0]}`
					: `Failed to restore ${failedSessions.length} terminals: ${failedSessions.join(", ")}`;
			alert(strings["error"], message);
		}

		// Restored terminal tabs transiently steal editor focus while openFile creates
		// them. If we trust manager.activeFile here, the last created terminal becomes
		// the implicit "active" tab and its hidden onfocus reconnect runs immediately,
		// which is exactly how Terminal 1/2 were restored against a 0x0 container and
		// how Terminal 3 kept winning focus after restore.
		for (const restoredTerminal of restoredTerminals) {
			restoredTerminal.armDeferredInitialization?.();
		}

		const fileToRestore = activeFileId && manager?.getFile
			? manager.getFile(activeFileId, "id")
			: null;
		if (fileToRestore) {
			fileToRestore.makeActive();
		} else if (restoredTerminals.length) {
			restoredTerminals[0]?.file?.makeActive();
		}
	}

	/**
	 * Create a new terminal session
	 * @param {object} options - Terminal options
	 * @returns {Promise<object>} Terminal instance info
	 */
	async createTerminal(options = {}) {
		try {
			const { render, serverMode, ...terminalOptions } = options;
			const shouldRender = render !== false;
			const isServerMode = serverMode !== false;
			const isReconnecting = terminalOptions.reconnecting === true;
			const shouldDeferHiddenReconnect =
				!shouldRender && isServerMode && isReconnecting && !!terminalOptions.pid;
			const shouldArmDeferredRestoreInitialization =
				shouldDeferHiddenReconnect &&
				terminalOptions.deferInitialRestoreActivation === true;

			const terminalId = `terminal_${++this.terminalCounter}`;
			const providedName =
				typeof options.name === "string" ? options.name.trim() : "";
			const terminalNumber = providedName
				? this.extractTerminalNumber(providedName)
				: this.getNextAvailableTerminalNumber();
			if (Number.isInteger(terminalNumber) && terminalNumber > 0) {
				this.reservedTerminalNumbers.add(terminalNumber);
			}
			const terminalName = providedName || `Terminal ${terminalNumber}`;
			const titlePrefix = terminalNumber
				? `Terminal ${terminalNumber}`
				: terminalName;

			// Create terminal component
			const terminalComponent = new TerminalComponent({
				serverMode: isServerMode,
				...terminalOptions,
			});
			if (shouldDeferHiddenReconnect) {
				terminalComponent.pid = String(terminalOptions.pid).trim();
			}
			terminalComponent._restoreInitializationArmed =
				!shouldArmDeferredRestoreInitialization;
			terminalComponent.terminalDisplayName = terminalName;
			terminalComponent.environmentCoordinator = {
				runExclusive: ({ type, run }) =>
					this.runSharedEnvironmentOperation({
						type,
						ownerName: terminalName,
						ownerTerminalId: terminalId,
						progressTerminal: { component: terminalComponent },
						run,
					}),
			};

			// Create container
			const terminalContainer = tag("div", {
				className: "terminal-content",
				id: `terminal-${terminalId}`,
			});

			// Terminal styles (inject once)
			if (!document.getElementById("acode-terminal-styles")) {
				const terminalStyles = this.getTerminalStyles();
				const terminalStyle = tag("style", {
					id: "acode-terminal-styles",
					textContent: terminalStyles,
				});
				document.body.appendChild(terminalStyle);
			}

			// Create EditorFile for terminal
			const terminalFile = new EditorFile(terminalName, {
				type: "terminal",
				content: terminalContainer,
				tabIcon: "licons terminal",
				render: shouldRender,
			});
			terminalFile.onfocus = () => {
				terminalFile._resolveActivationReady?.();
				terminalFile._resolveActivationReady = null;
				terminalFile._activationReadyPromise = null;

				requestAnimationFrame(() => {
					terminalComponent.syncVisibleLayout?.();
					terminalComponent.focusWhenReady();
				});
			};
			terminalFile.onclose = () => {
				pushTerminalRestoreDebugLog( // 仅调试用
					"tab-onclose", // 仅调试用
					{ // 仅调试用
						terminalId, // 仅调试用
						terminalName, // 仅调试用
						trigger: consumeTerminalCloseTrigger(terminalFile), // 仅调试用
					}, // 仅调试用
					"warn", // 仅调试用
				); // 仅调试用
				this.interruptSharedEnvironmentOperationForTerminal(
					terminalId,
					terminalName,
				);

				try {
					terminalComponent.dispose();
				} catch {}
			};
			terminalFile._skipTerminalCloseConfirm = false; // 仅调试用
			const originalRemove = terminalFile.remove.bind(terminalFile); // 仅调试用
			terminalFile.remove = async (force = false) => { // 仅调试用
				terminalFile._terminalCloseTrigger = { // 仅调试用
					type: "remove", // 仅调试用
					force, // 仅调试用
					skipConfirm: !!terminalFile._skipTerminalCloseConfirm, // 仅调试用
					activeFileId: window.editorManager?.activeFile?.id || null, // 仅调试用
				}; // 仅调试用
				pushTerminalRestoreDebugLog( // 仅调试用
					"tab-remove-request", // 仅调试用
					{ // 仅调试用
						terminalId, // 仅调试用
						terminalName, // 仅调试用
						trigger: terminalFile._terminalCloseTrigger, // 仅调试用
					}, // 仅调试用
					"warn", // 仅调试用
				); // 仅调试用
				terminalFile._skipTerminalCloseConfirm = false; // 仅调试用
				return originalRemove(force); // 仅调试用
			}; // 仅调试用

			// Wait for tab creation and setup
			return await new Promise((resolve, reject) => {
				setTimeout(async () => {
					try {
						const initializeTerminalSession = async () => {
							const activeFile = window.editorManager?.activeFile;
							const isActiveTerminalTab = activeFile?.id === terminalFile.id;
							pushTerminalRestoreDebugLog( // 仅调试用
								"initialize-entry", // 仅调试用
								{ // 仅调试用
									terminalId, // 仅调试用
									terminalName, // 仅调试用
									pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
									activeFileId: activeFile?.id || null, // 仅调试用
									terminalFileId: terminalFile.id, // 仅调试用
									isActiveTerminalTab, // 仅调试用
									hasDeferredPromise: !!terminalComponent._deferredInitializationPromise, // 仅调试用
								}, // 仅调试用
							); // 仅调试用

							// Hidden restored terminals must never mount or reconnect until their tab is
							// actually active. Runtime logs proved that startup could still initialize
							// background tabs here, which opened fresh PTYs for Terminal 2/3 while
							// Terminal 1 remained selected and later caused mismatched restored state.
							// NOTE: hasVisibleLayout (offsetParent) is intentionally NOT checked here.
							// onfocus fires synchronously inside makeActive() before the DOM applies
							// the new active-tab CSS, so offsetParent is always null at this point
							// even for legitimate user tab-clicks, making the check a false negative.
							if (
								shouldDeferHiddenReconnect &&
								!terminalComponent._deferredInitializationPromise &&
								!isActiveTerminalTab
							) {
								pushTerminalRestoreDebugLog( // 仅调试用
									"defer-hidden-reconnect", // 仅调试用
									{ // 仅调试用
										terminalId, // 仅调试用
										terminalName, // 仅调试用
										pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
										activeFileId: activeFile?.id || null, // 仅调试用
										terminalFileId: terminalFile.id, // 仅调试用
									}, // 仅调试用
								); // 仅调试用
								return null;
							}

							// Restored terminals created with render:false are not attached to the
							// DOM yet. Mounting xterm and opening the PTY while the tab is hidden
							// makes the first POST /terminals use a transient narrow grid, so the
							// initial "root@localhost" prompt is hard-wrapped before the tab is
							// ever shown. Hidden restored sessions must wait until first focus.
							if (terminalComponent._deferredInitializationPromise) {
								pushTerminalRestoreDebugLog( // 仅调试用
									"reuse-deferred-promise", // 仅调试用
									{ // 仅调试用
										terminalId, // 仅调试用
										terminalName, // 仅调试用
										pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
									}, // 仅调试用
								); // 仅调试用
								return terminalComponent._deferredInitializationPromise;
							}

							terminalComponent._deferredInitializationPromise = (async () => {
						// Mount terminal component
						terminalComponent.mount(terminalContainer);
						this.setupTerminalResizeObserver(
							terminalFile,
							terminalComponent,
							terminalId,
						);

						if (terminalComponent.serverMode) {
							// Run install check after mount so install logs can stream into this
							// exact terminal tab (via progressTerminal.component), instead of
							// opening a separate "Terminal Installation" tab. Keeping it inside
							// this init try/catch also reuses the same cleanup path on failure
							// (dispose component + remove broken tab).
							const installationResult = await this.checkAndInstallTerminal(
								false,
								{
									component: terminalComponent,
									terminalId,
								},
								{ ownerTerminalId: terminalId, ownerName: terminalName },
							);
							if (!installationResult.success) {
								throw new Error(installationResult.error);
							}
						}

						// Connect to session if in server mode
						if (terminalComponent.serverMode) {
						await this.waitForTerminalLayoutReady(
							terminalFile,
							terminalComponent,
							terminalId,
						);
						pushTerminalRestoreDebugLog( // 仅调试用
							"layout-ready", // 仅调试用
							{ // 仅调试用
								terminalId, // 仅调试用
								terminalName, // 仅调试用
								pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
								cols: terminalComponent.terminal?.cols ?? null, // 仅调试用
								rows: terminalComponent.terminal?.rows ?? null, // 仅调试用
							}, // 仅调试用
						); // 仅调试用
							await terminalComponent.connectToSession(terminalOptions.pid);
						pushTerminalRestoreDebugLog( // 仅调试用
							"connect-resolved", // 仅调试用
							{ // 仅调试用
								terminalId, // 仅调试用
								terminalName, // 仅调试用
								pid: terminalComponent.pid || null, // 仅调试用
								isConnected: !!terminalComponent.isConnected, // 仅调试用
								isReconnecting, // 仅调试用
							}, // 仅调试用
						); // 仅调试用
							// Track whether this is a restored (reconnected) session so onProcessExit
							// can distinguish unexpected exits from a stale previous session vs.
							// the user intentionally running `exit` in a fresh shell.
							terminalComponent._isReconnectedSession = isReconnecting;
							if (isReconnecting) {
								terminalComponent.write(
									"\x1b[36m[Restored existing terminal session. MOTD is only shown when a new shell starts.]\x1b[0m\r\n",
								);
							}
						} else {
							// For local mode, just write a welcome message
							terminalComponent.write(
								"Local terminal mode - ready for output\r\n",
							);
						}

						// Use PID as unique ID if available, otherwise fall back to terminalId
						const uniqueId = terminalComponent.pid || terminalId;

						// Setup event handlers
						this.setupTerminalHandlers(
							terminalFile,
							terminalComponent,
							uniqueId,
							titlePrefix,
						);

								return uniqueId;
							})();

							return terminalComponent._deferredInitializationPromise;
						};

						if (shouldDeferHiddenReconnect) {
							const uniqueId = terminalComponent.pid;
							const instance = {
								id: uniqueId,
								name: terminalName,
								terminalNumber,
								component: terminalComponent,
								file: terminalFile,
								container: terminalContainer,
								armDeferredInitialization: () => {
									terminalComponent._restoreInitializationArmed = true;
								},
							};

							terminalFile.onfocus = async () => {
								try {
									if (!terminalComponent._restoreInitializationArmed) {
										pushTerminalRestoreDebugLog( // 仅调试用
											"onfocus-blocked-until-restore-settled", // 仅调试用
											{ // 仅调试用
												terminalId, // 仅调试用
												terminalName, // 仅调试用
												pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
											}, // 仅调试用
										); // 仅调试用
										return;
									}
									pushTerminalRestoreDebugLog( // 仅调试用
										"onfocus-begin", // 仅调试用
										{ // 仅调试用
											terminalId, // 仅调试用
											terminalName, // 仅调试用
											pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
											hasDeferredPromise: !!terminalComponent._deferredInitializationPromise, // 仅调试用
										}, // 仅调试用
									); // 仅调试用
									const initializedId = await initializeTerminalSession();
									pushTerminalRestoreDebugLog( // 仅调试用
										"onfocus-result", // 仅调试用
										{ // 仅调试用
											terminalId, // 仅调试用
											terminalName, // 仅调试用
											initializedId: initializedId || null, // 仅调试用
											pid: terminalComponent.pid || terminalOptions.pid || null, // 仅调试用
											isConnected: !!terminalComponent.isConnected, // 仅调试用
										}, // 仅调试用
										initializedId ? "info" : "warn", // 仅调试用
									); // 仅调试用
									if (!initializedId) {
										return;
									}
									terminalComponent.focusWhenReady();
								} catch (error) {
									console.error(
										`Failed to initialize restored terminal ${uniqueId}:`,
										error,
									);
									this.closeTerminal(uniqueId, true);
									alert(
										strings["error"],
										`Failed to restore terminal: ${terminalName}`,
									);
								}
							};

							this.terminals.set(uniqueId, instance);
							if (Number.isInteger(terminalNumber) && terminalNumber > 0) {
								this.reservedTerminalNumbers.delete(terminalNumber);
							}
							resolve(instance);
							return;
						}

						const uniqueId = await initializeTerminalSession();

						const instance = {
							id: uniqueId,
							name: terminalName,
							terminalNumber,
							component: terminalComponent,
							file: terminalFile,
							container: terminalContainer,
						};

						this.terminals.set(uniqueId, instance);

						if (terminalComponent.serverMode && terminalComponent.pid) {
							await this.persistTerminalSession(
								terminalComponent.pid,
								terminalName,
							);
						}
						if (Number.isInteger(terminalNumber) && terminalNumber > 0) {
							this.reservedTerminalNumbers.delete(terminalNumber);
						}
						resolve(instance);
					} catch (error) {
						if (Number.isInteger(terminalNumber) && terminalNumber > 0) {
							this.reservedTerminalNumbers.delete(terminalNumber);
						}
						if (error?.name === "TerminalSessionStaleError") {
							try {
								terminalComponent.dispose();
							} catch {}

							try {
								terminalFile._skipTerminalCloseConfirm = true;
								terminalFile.remove(true);
							} catch {}

							resolve(null);
							return;
						}

						if (error?.sharedEnvironmentInterrupted) {
							try {
								terminalComponent.dispose();
							} catch {}

							try {
								terminalFile._skipTerminalCloseConfirm = true;
								terminalFile.remove(true);
							} catch {}

							this.showSharedEnvironmentInterruptedAlertOnce(error);
							resolve(null);
							return;
						}

						console.error("Failed to initialize terminal:", error);

						// Cleanup on failure - dispose component and remove broken tab
						try {
							terminalComponent.dispose();
						} catch (disposeError) {
							console.error(
								"Error disposing terminal component:",
								disposeError,
							);
						}

						try {
							// Force remove the tab without confirmation
							terminalFile._skipTerminalCloseConfirm = true;
							terminalFile.remove(true);
						} catch (removeError) {
							console.error("Error removing terminal tab:", removeError);
						}

						// Show alert for terminal creation failure
						const errorMessage = error?.message || "Unknown error";
						alert(
							strings["error"],
							`Failed to create terminal: ${errorMessage}`,
						);

						reject(error);
					}
				}, 100);
			});
		} catch (error) {
			if (Number.isInteger(terminalNumber) && terminalNumber > 0) {
				this.reservedTerminalNumbers.delete(terminalNumber);
			}
			throw error;
		}
	}

	/**
	 * Check if terminal is installed and install if needed
	 * @param {boolean} [forceReinstall=false] - Whether to force reinstall even if already installed.
	 * Usually false for normal terminal creation. Set to true only for recovery flows
	 * (currently relocation_error auto-repair) to bypass the "already installed"
	 * early return and run a full reinstall.
	 * @returns {Promise<{success: boolean, error?: string}>}
	 */
	async checkAndInstallTerminal(
		forceReinstall = false,
		progressTerminal = null,
		options = {},
	) {
		const { skipSharedLock = false, ownerName = null } = options;
		const runInstall = async () => {
			try {
				// Check if terminal is already installed
				const isInstalled = await Terminal.isInstalled();
				if (isInstalled && !forceReinstall) {
					return { success: true };
				}

				// Check if terminal is supported on this device
				const isSupported = await Terminal.isSupported();
				if (!isSupported) {
					return {
						success: false,
						error: "Terminal is not supported on this device architecture",
					};
				}

				// Create installation progress terminal (or reuse current one)
				const installTerminal =
					progressTerminal || (await this.createInstallationTerminal());
				if (progressTerminal?.component) {
					installTerminal.component.write(
						"\x1b[33mInstalling terminal environment...\x1b[0m\r\n",
					);
				}

				// Install terminal with progress logging
				const installResult = await Terminal.install(
					(message) => {
						// Remove stdout/stderr prefix for
						const cleanMessage = message.replace(/^(stdout|stderr)\s+/, "");
						installTerminal.component.write(`${cleanMessage}\r\n`);
					},
					(error) => {
						// Remove stdout/stderr prefix
						const cleanError = error.replace(/^(stdout|stderr)\s+/, "");
						installTerminal.component.write(
							`\x1b[31mError: ${cleanError}\x1b[0m\r\n`,
						);
					},
				);

				// Only return success if Terminal.install() indicates success (exit code 0)
				if (installResult === true || installResult?.success === true) {
					return { success: true };
				} else {
					const installError =
						typeof installResult === "object" && installResult
							? installResult.error
							: null;
					return {
						success: false,
						error:
							installError ||
							"Terminal installation failed - process did not exit with code 0",
					};
				}
			} catch (error) {
				console.error("Terminal installation failed:", error);
				return {
					success: false,
					error: `Terminal installation failed: ${error.message}`,
				};
			}
		};

		if (skipSharedLock) {
			return runInstall();
		}

		return this.runSharedEnvironmentOperation({
			type: forceReinstall ? "repair" : "install",
			ownerName:
				ownerName ||
				progressTerminal?.component?.terminalDisplayName ||
				"Terminal maintenance",
			ownerTerminalId:
				options.ownerTerminalId || progressTerminal?.terminalId || null,
			progressTerminal,
			run: runInstall,
		});
	}

	/**
	 * Create a terminal for showing installation progress
	 * @returns {Promise<object>} Installation terminal instance
	 */
	async createInstallationTerminal() {
		const terminalId = `install_terminal_${++this.terminalCounter}`;
		const terminalName = "Terminal Installation";

		// Create terminal component in local mode (no server needed)
		const terminalComponent = new TerminalComponent({
			serverMode: false,
		});

		// Create container
		const terminalContainer = tag("div", {
			className: "terminal-content",
			id: `terminal-${terminalId}`,
		});

		// Terminal styles (inject once)
		if (!document.getElementById("acode-terminal-styles")) {
			const terminalStyles = this.getTerminalStyles();
			const terminalStyle = tag("style", {
				id: "acode-terminal-styles",
				textContent: terminalStyles,
			});
			document.body.appendChild(terminalStyle);
		}

		// Create EditorFile for terminal
		const terminalFile = new EditorFile(terminalName, {
			type: "terminal",
			content: terminalContainer,
			tabIcon: "icon save_alt",
			render: true,
		});

		// Wait for tab creation and setup
		return await new Promise((resolve, reject) => {
			setTimeout(async () => {
				try {
					// Mount terminal component
					terminalComponent.mount(terminalContainer);

					// Write initial message
					terminalComponent.write("🚀 Installing Terminal Environment...\r\n");
					terminalComponent.write(
						"This may take a few minutes depending on your connection.\r\n\r\n",
					);

					// Setup event handlers
					this.setupTerminalHandlers(
						terminalFile,
						terminalComponent,
						terminalId,
					);

					// Set up custom title for installation terminal
					terminalFile.setCustomTitle(
						() => "Installing Terminal Environment...",
					);

					const instance = {
						id: terminalId,
						name: terminalName,
						component: terminalComponent,
						file: terminalFile,
						container: terminalContainer,
					};

					this.terminals.set(terminalId, instance);
					resolve(instance);
				} catch (error) {
					console.error("Failed to create installation terminal:", error);
					reject(error);
				}
			}, 100);
		});
	}

	/**
	 * Bind the ResizeObserver before session creation so the first PTY size is
	 * derived from the real tab dimensions instead of the transient narrow width
	 * that appears while the tab is still entering the layout.
	 * @param {EditorFile} terminalFile - Terminal file instance
	 * @param {TerminalComponent} terminalComponent - Terminal component
	 * @param {string} terminalId - Terminal ID
	 */
	setupTerminalResizeObserver(terminalFile, terminalComponent, terminalId) {
		if (terminalFile._resizeObserver) {
			return;
		}

		terminalFile._initialLayoutReady = false;
		terminalFile._activationReadyPromise = null;
		terminalFile._resolveActivationReady = null;
		terminalFile._initialLayoutReadyPromise = new Promise((resolve) => {
			terminalFile._resolveInitialLayoutReady = resolve;
		});

		let resizeTimeout = null;
		const RESIZE_DEBOUNCE = 200;
		let lastWidth = 0;
		let lastHeight = 0;

		const resizeObserver = new ResizeObserver((entries) => {
			const entry = entries && entries[0];
			const cr = entry?.contentRect;
			const width = cr?.width ?? terminalFile.content?.clientWidth ?? 0;
			const height = cr?.height ?? terminalFile.content?.clientHeight ?? 0;

			if (resizeTimeout) {
				clearTimeout(resizeTimeout);
			}

			resizeTimeout = setTimeout(() => {
				try {
					if (!terminalComponent.terminal || !terminalComponent.container) {
						return;
					}

					if (width < 10 || height < 10) {
						return;
					}

					if (
						Math.abs(width - lastWidth) > 0.5 ||
						Math.abs(height - lastHeight) > 0.5 ||
						!terminalFile._initialLayoutReady
					) {
						terminalComponent.fit();
						lastWidth = width;
						lastHeight = height;
					}

					if (!terminalFile._initialLayoutReady) {
						terminalFile._initialLayoutReady = true;
						terminalFile._resolveInitialLayoutReady?.();
						terminalFile._resolveInitialLayoutReady = null;
					}
				} catch (error) {
					console.error(`Resize error for terminal ${terminalId}:`, error);
				}
			}, RESIZE_DEBOUNCE);
		});

		const containerElement = terminalFile.content;
		if (containerElement && containerElement instanceof Element) {
			resizeObserver.observe(containerElement);
			terminalFile._resizeObserver = resizeObserver;
		} else {
			console.warn("Terminal container not available for ResizeObserver");
		}
	}

	/**
	 * Wait for terminal layout to stabilize before connecting to session.
	 * The first PTY inherits xterm's current cols/rows, so reconnecting before the
	 * tab finishes entering layout can permanently hard-wrap the first prompt.
	 */
	async waitForTerminalLayoutReady(terminalFile, terminalComponent, terminalId) {
		const containerElement = terminalFile.content;
		if (!(containerElement instanceof Element)) {
			throw new Error(
				`Terminal ${terminalId} container is not available for initial layout`,
			);
		}

		const hasRenderableTerminalLayout = () => {
			const outerRect = containerElement.getBoundingClientRect();
			const innerRect = terminalComponent.container?.getBoundingClientRect();

			return (
				outerRect.width >= 10 &&
				outerRect.height >= 10 &&
				innerRect?.width >= 10 &&
				innerRect?.height >= 10
			);
		};

		const waitForRenderableTerminalLayout = async () => {
			if (hasRenderableTerminalLayout()) {
				return;
			}

			await new Promise((resolve, reject) => {
				const startTime = Date.now();
				const pollLayout = () => {
					if (hasRenderableTerminalLayout()) {
						resolve();
						return;
					}

					// Active tab selection fires before WebView finishes applying the new
					// tab CSS and xterm's own container catches up. Waiting for the actual
					// mounted xterm box prevents connectToSession from still seeing 0x0 and
					// opening Terminal 2/3 on an invisible grid that later paints as black.
					if (Date.now() - startTime >= 4000) {
						reject(
							new Error(
								`Terminal ${terminalId} xterm container did not become renderable before session connect`,
							),
						);
						return;
					}

					if (typeof requestAnimationFrame === "function") {
						requestAnimationFrame(pollLayout);
						return;
					}

					setTimeout(pollLayout, 16);
				};

				pollLayout();
			});
		};

		if (terminalFile._initialLayoutReady && hasRenderableTerminalLayout()) {
			return;
		}

		const isActiveTerminalTab =
			window.editorManager?.activeFile?.id === terminalFile.id;
		if (!isActiveTerminalTab) {
			if (!terminalFile._activationReadyPromise) {
				terminalFile._activationReadyPromise = new Promise((resolve) => {
					terminalFile._resolveActivationReady = resolve;
				});
			}

			await terminalFile._activationReadyPromise;

			if (terminalFile._initialLayoutReady) {
				return;
			}
		}

		const waitForObserver = terminalFile._initialLayoutReadyPromise;
		if (!waitForObserver) {
			throw new Error(
				`Terminal ${terminalId} layout observer is not ready before session connect`,
			);
		}

		await Promise.race([
			waitForObserver,
			new Promise((_, reject) => {
				setTimeout(() => {
					reject(
						new Error(
							`Terminal ${terminalId} did not receive an initial layout event before session connect`,
						),
					);
				}, 4000);
			}),
		]);

		await waitForRenderableTerminalLayout();
	}

	/**
	 * Setup terminal event handlers
	 * @param {EditorFile} terminalFile - Terminal file instance
	 * @param {TerminalComponent} terminalComponent - Terminal component
	 * @param {string} terminalId - Terminal ID
	 */
	async setupTerminalHandlers(
		terminalFile,
		terminalComponent,
		terminalId,
		titlePrefix = terminalId,
	) {
		// Reuse a stable display name inside debug-only close logs. The previous
		// instrumentation referenced an out-of-scope terminalName and crashed the
		// remove path after uninstall had already started closing tabs.
		const terminalDisplayName =
			terminalComponent.terminalDisplayName || terminalFile.filename || titlePrefix;
		this.setupTerminalResizeObserver(
			terminalFile,
			terminalComponent,
			terminalId,
		);
		const textarea = terminalComponent.terminal?.textarea;
		if (textarea) {
			const onFocus = () => {
				const { $toggler } = quickTools;
				$toggler.classList.add("hide");
				clearTimeout(this.togglerTimeout);
				this.togglerTimeout = setTimeout(() => {
					$toggler.style.display = "none";
				}, 300);
			};

			const onBlur = () => {
				const { $toggler } = quickTools;
				clearTimeout(this.togglerTimeout);
				$toggler.style.display = "";
				setTimeout(() => {
					$toggler.classList.remove("hide");
				}, 10);
			};

			textarea.addEventListener("focus", onFocus);
			textarea.addEventListener("blur", onBlur);

			terminalComponent.cleanupFocusHandlers = () => {
				textarea.removeEventListener("focus", onFocus);
				textarea.removeEventListener("blur", onBlur);
			};
		}

		// Handle tab focus/blur
		terminalFile.onfocus = () => {
			terminalFile._resolveActivationReady?.();
			terminalFile._resolveActivationReady = null;
			terminalFile._activationReadyPromise = null;

			requestAnimationFrame(() => {
				terminalComponent.syncVisibleLayout?.();
				terminalComponent.focusWhenReady();
			});
		};

		// Handle tab close
		terminalFile.onclose = () => {
			pushTerminalRestoreDebugLog( // 仅调试用
				"tab-onclose", // 仅调试用
				{ // 仅调试用
					terminalId, // 仅调试用
					terminalName: terminalDisplayName, // 仅调试用
					trigger: consumeTerminalCloseTrigger(terminalFile), // 仅调试用
				}, // 仅调试用
				"warn", // 仅调试用
			); // 仅调试用
			this.closeTerminal(terminalId);
		};

		terminalFile._skipTerminalCloseConfirm = false;
		const originalRemove = terminalFile.remove.bind(terminalFile);
		terminalFile.remove = async (force = false) => {
			terminalFile._terminalCloseTrigger = { // 仅调试用
				type: "remove", // 仅调试用
				force, // 仅调试用
				skipConfirm: !!terminalFile._skipTerminalCloseConfirm, // 仅调试用
				activeFileId: window.editorManager?.activeFile?.id || null, // 仅调试用
			}; // 仅调试用
			pushTerminalRestoreDebugLog( // 仅调试用
				"tab-remove-request", // 仅调试用
				{ // 仅调试用
					terminalId, // 仅调试用
					terminalName: terminalDisplayName, // 仅调试用
					trigger: terminalFile._terminalCloseTrigger, // 仅调试用
				}, // 仅调试用
				"warn", // 仅调试用
			); // 仅调试用
			if (
				!terminalFile._skipTerminalCloseConfirm &&
				this.shouldConfirmTerminalClose()
			) {
				const message = `${strings["close"]} ${strings["terminal"]}?`;
				const shouldClose = await confirm(strings["confirm"], message);
				if (!shouldClose) return;
			}

			terminalFile._skipTerminalCloseConfirm = false;
			return originalRemove(force);
		};

		// Terminal event handlers
		terminalComponent.onConnect = () => {
			console.log(`Terminal ${terminalId} connected`);
		};

		terminalComponent.onDisconnect = () => {
			console.log(`Terminal ${terminalId} disconnected`);
		};

		terminalComponent.onError = (error) => {
			pushTerminalRestoreDebugLog( // 仅调试用
				"component-error", // 仅调试用
				{ // 仅调试用
					terminalId, // 仅调试用
					terminalName: terminalDisplayName, // 仅调试用
					errorMessage: error?.message || String(error), // 仅调试用
				}, // 仅调试用
				"error", // 仅调试用
			); // 仅调试用
			console.error(`Terminal ${terminalId} error:`, error);

			// Close the terminal and remove the tab
			this.closeTerminal(terminalId, true);

			// Show alert for connection error
			const errorMessage = error?.message || "Connection lost";
			alert(strings["error"], `Terminal connection error: ${errorMessage}`);
		};

		terminalComponent.onTitleChange = async (title) => {
			if (title) {
				// Keep the tab prefix stable for this terminal instance.
				const formattedTitle = `${titlePrefix} - ${title}`;
				terminalFile.filename = formattedTitle;

				if (terminalComponent.serverMode && terminalComponent.pid) {
					await this.persistTerminalSession(
						terminalComponent.pid,
						formattedTitle,
					);
				}

				// Refresh the header subtitle if this terminal is active
				if (
					editorManager.activeFile &&
					editorManager.activeFile.id === terminalFile.id
				) {
					// Force refresh of the header subtitle
					terminalFile.setCustomTitle(getTerminalTitle);
				}
			}
		};

		terminalComponent.onProcessExit = (exitData) => {
			// Format exit message based on exit code and signal
			let message;
			if (exitData.signal) {
				message = `Process terminated by signal ${exitData.signal}`;
			} else if (exitData.exit_code === 0) {
				message = `Process exited successfully (code ${exitData.exit_code})`;
			} else {
				message = `Process exited with code ${exitData.exit_code}`;
			}

			// For reconnected (restored) sessions, a non-zero exit often means the
			// previous session's shell was left mid-command and finished naturally
			// after reconnect. Auto-closing the tab in that case is disorienting:
			// the user's tab disappears without warning. Show the exit message in
			// the terminal output instead and let the user decide to close manually.
			// Zero exit (user typed `exit`) still auto-closes for both session types.
			if (terminalComponent._isReconnectedSession && exitData.exit_code !== 0) {
				terminalComponent.write(
					`\r\n\x1b[31m[${message}]\x1b[0m\r\n`,
				);
				toast(message);
				return;
			}

			this.closeTerminal(terminalId);
			terminalFile._skipTerminalCloseConfirm = true;
			terminalFile.remove(true);
			toast(message);
		};

		// Auto-recovery for corrupted rootfs (in-place, no new tab or toast)
		terminalComponent.onCrashData = async (reason) => {
			if (reason === "relocation_error") {
				try {
					// Disconnect websocket to stop feeding garbage
					if (terminalComponent.websocket) {
						terminalComponent.websocket.close();
					}
					terminalComponent.isConnected = false;

					// Write recovery status directly into the current terminal
					terminalComponent.clear();
					terminalComponent.write(
						"\x1b[33m⚠ Detected terminal environment corruption (libc/readline).\x1b[0m\r\n",
					);
					terminalComponent.write(
						"\x1b[33m  Starting automatic repair...\x1b[0m\r\n\r\n",
					);

					// Uninstall corrupted rootfs
					terminalComponent.write("Removing corrupted rootfs...\r\n");
					if (
						!window.Terminal ||
						typeof window.Terminal.uninstall !== "function"
					) {
						throw new Error(
							"Terminal uninstall API is unavailable; cannot repair corrupted rootfs.",
						);
					}
					await this.runSharedEnvironmentOperation({
						type: "repair",
						ownerName: terminalComponent.terminalDisplayName || "Terminal",
						ownerTerminalId: terminalId,
						progressTerminal: { component: terminalComponent },
						run: async () => {
							terminalComponent.write("Rootfs removed. Reinstalling...\r\n\r\n");
							await window.Terminal.uninstall();
							const result = await this.checkAndInstallTerminal(
								true,
								{
									component: terminalComponent,
								},
								{
									skipSharedLock: true,
									ownerName:
										terminalComponent.terminalDisplayName || "Terminal",
								},
							);

							if (!result.success) {
								throw new Error(result.error);
							}

							return result;
						},
					});

					terminalComponent.write(
						"\r\n\x1b[32m✔ Recovery complete. Reconnecting session...\x1b[0m\r\n",
					);
					// Clear the terminal buffer so the new shell prompt starts clean
					terminalComponent.clear();
					// Reconnect a fresh session in the same terminal
					await terminalComponent.connectToSession();
				} catch (e) {
					console.error("In-place terminal recovery failed:", e);
					terminalComponent.write(
						`\r\n\x1b[31m✘ Recovery error: ${e.message}\x1b[0m\r\n`,
					);
				}
			}
		};

		// Handle acode CLI open commands (OSC 7777)
		terminalComponent.onOscOpen = async (type, path) => {
			if (!path) return;

			// Convert proot path
			const fileUri = this.convertProotPath(path);
			// Extract folder/file name from normalized path
			const name = this.getPathDisplayName(path);

			try {
				if (type === "folder") {
					// Open folder in sidebar
					await openFolder(fileUri, { name, saveState: true, listFiles: true });
					toast(`Opened folder: ${name}`);
				} else {
					// Open file in editor
					await openFile(fileUri, { render: true });
				}
			} catch (error) {
				console.error("Failed to open from terminal:", error);
				toast(`Failed to open: ${path}`);
			}
		};

		// Store references for cleanup
		terminalFile._terminalId = terminalId;
		terminalFile.terminalComponent = terminalComponent;

		// Set up custom title function for terminal
		const getTerminalTitle = () => {
			if (terminalComponent.pid) {
				return `PID: ${terminalComponent.pid}`;
			}
			// fallback to terminal name
			return `${terminalId}`;
		};

		terminalFile.setCustomTitle(getTerminalTitle);
	}

	/**
	 * Close a terminal session
	 * @param {string} terminalId - Terminal ID
	 */
	closeTerminal(terminalId, removeTab = false) {
		const terminal = this.terminals.get(terminalId);
		if (!terminal) return;

		try {
			pushTerminalRestoreDebugLog( // 仅调试用
				"close-terminal", // 仅调试用
				{ // 仅调试用
					terminalId, // 仅调试用
					terminalName: terminal.name, // 仅调试用
					removeTab, // 仅调试用
					pid: terminal.component?.pid || null, // 仅调试用
					trigger: consumeTerminalCloseTrigger(terminal.file), // 仅调试用
					activeFileId: window.editorManager?.activeFile?.id || null, // 仅调试用
				}, // 仅调试用
				"warn", // 仅调试用
			); // 仅调试用
			if (terminal.component.serverMode && terminal.component.pid) {
				this.removePersistedSession(terminal.component.pid);
			}

			this.interruptSharedEnvironmentOperationForTerminal(
				terminalId,
				terminal.name,
			);

			// Cleanup resize observer
			if (terminal.file._resizeObserver) {
				terminal.file._resizeObserver.disconnect();
				terminal.file._resizeObserver = null;
			}

			// Cleanup focus handlers
			if (terminal.component.cleanupFocusHandlers) {
				terminal.component.cleanupFocusHandlers();
			}

			// Dispose terminal component
			terminal.component.dispose();

			// Remove from map
			this.terminals.delete(terminalId);

			// Optionally remove the tab as well
			if (removeTab && terminal.file) {
				try {
					terminal.file._skipTerminalCloseConfirm = true;
					terminal.file.remove(true);
				} catch (removeError) {
					console.error("Error removing terminal tab:", removeError);
				}
			}

			if (this.getAllTerminals().size <= 0) {
				Executor.stopService();
			}

			console.log(`Terminal ${terminalId} closed`);
		} catch (error) {
			console.error(`Error closing terminal ${terminalId}:`, error);
		}
	}

	/**
	 * Get terminal by ID
	 * @param {string} terminalId - Terminal ID
	 * @returns {object|null} Terminal instance
	 */
	getTerminal(terminalId) {
		return this.terminals.get(terminalId) || null;
	}

	/**
	 * Get all active terminals
	 * @returns {Map} All terminals
	 */
	getAllTerminals() {
		return this.terminals;
	}

	/**
	 * Register a touch-selection "More" menu option.
	 * @param {object} option
	 * @returns {string|null}
	 */
	addTouchSelectionMoreOption(option) {
		return TerminalTouchSelection.addMoreOption(option);
	}

	/**
	 * Remove a touch-selection "More" menu option.
	 * @param {string} id
	 * @returns {boolean}
	 */
	removeTouchSelectionMoreOption(id) {
		return TerminalTouchSelection.removeMoreOption(id);
	}

	/**
	 * List touch-selection "More" menu options.
	 * @returns {Array<object>}
	 */
	getTouchSelectionMoreOptions() {
		return TerminalTouchSelection.getMoreOptions();
	}

	/**
	 * Write to a specific terminal
	 * @param {string} terminalId - Terminal ID
	 * @param {string} data - Data to write
	 */
	writeToTerminal(terminalId, data) {
		const terminal = this.getTerminal(terminalId);
		if (terminal) {
			terminal.component.write(data);
		}
	}

	/**
	 * Clear a specific terminal
	 * @param {string} terminalId - Terminal ID
	 */
	clearTerminal(terminalId) {
		const terminal = this.getTerminal(terminalId);
		if (terminal) {
			terminal.component.clear();
		}
	}

	/**
	 * Get terminal styles for shadow DOM
	 * @returns {string} CSS styles
	 */
	getTerminalStyles() {
		return `
			.terminal-content {
				width: 100%;
				height: 100%;
				box-sizing: border-box;
				background: #1e1e1e;
				overflow: hidden;
				position: relative;
			}

			.terminal-content .xterm {
				padding: 0.25rem;
				box-sizing: border-box;
			}
		`;
	}

	/**
	 * Create a local terminal (no server connection)
	 * @param {object} options - Terminal options
	 * @returns {Promise<object>} Terminal instance
	 */
	async createLocalTerminal(options = {}) {
		return this.createTerminal({
			...options,
			serverMode: false,
		});
	}

	/**
	 * Create a server terminal (with backend connection)
	 * @param {object} options - Terminal options
	 * @returns {Promise<object>} Terminal instance
	 */
	async createServerTerminal(options = {}) {
		return this.createTerminal({
			...options,
			serverMode: true,
		});
	}

	/**
	 * Handle keyboard resize events for all terminals
	 * This is called when the virtual keyboard opens/closes on mobile
	 */
	handleKeyboardResize() {
		// Add a small delay to let the UI settle
		setTimeout(() => {
			this.terminals.forEach((terminal) => {
				try {
					if (terminal.component && terminal.component.terminal) {
						// Force a re-fit for all terminals
						terminal.component.fit();

						// If terminal has lots of content, try to preserve scroll position
						const buffer = terminal.component.terminal.buffer?.active;
						if (
							buffer &&
							buffer.length > terminal.component.terminal.rows * 2
						) {
							// For content-heavy terminals, ensure we stay near the bottom if we were there
							const wasNearBottom =
								buffer.viewportY >=
								buffer.length - terminal.component.terminal.rows - 5;
							if (wasNearBottom) {
								// Scroll to bottom after resize
								setTimeout(() => {
									terminal.component.terminal.scrollToBottom();
								}, 100);
							}
						}
					}
				} catch (error) {
					console.error(
						`Error handling keyboard resize for terminal ${terminal.id}:`,
						error,
					);
				}
			});
		}, 150);
	}

	/**
	 * Stabilize terminal viewport after resize operations
	 */
	stabilizeTerminals() {
		this.terminals.forEach((terminal) => {
			try {
				if (terminal.component && terminal.component.terminal) {
					// Clear any touch selections during stabilization
					if (
						terminal.component.touchSelection &&
						terminal.component.touchSelection.isSelecting
					) {
						terminal.component.touchSelection.clearSelection();
					}

					// Re-fit and refresh
					terminal.component.fit();

					// Focus the active terminal to ensure proper state
					if (terminal.file && terminal.file.isOpen) {
						setTimeout(() => {
							terminal.component.focus();
						}, 50);
					}
				}
			} catch (error) {
				console.error(`Error stabilizing terminal ${terminal.id}:`, error);
			}
		});
	}

	/**
	 * Convert proot internal path to app-accessible path
	 * @param {string} prootPath - Path from inside proot environment
	 * @returns {string} App filesystem path
	 */
	convertProotPath(prootPath) {
		if (!prootPath) return prootPath;

		const packageName = window.BuildInfo?.packageName || "com.foxdebug.acode";
		const dataDir = `/data/user/0/${packageName}`;
		const alpineRoot = `${dataDir}/files/alpine`;

		let convertedPath;

		if (prootPath.startsWith("/public")) {
			// /public -> /data/user/0/com.foxdebug.acode/files/public
			convertedPath = `file://${dataDir}/files${prootPath}`;
		} else if (
			prootPath.startsWith("/sdcard") ||
			prootPath.startsWith("/storage") ||
			prootPath.startsWith("/data")
		) {
			convertedPath = `file://${prootPath}`;
		} else if (prootPath.startsWith("/")) {
			// Everything else is relative to alpine root
			convertedPath = `file://${alpineRoot}${prootPath}`;
		} else {
			convertedPath = prootPath;
		}

		//console.log(`Path conversion: ${prootPath} -> ${convertedPath}`);
		return convertedPath;
	}

	/**
	 * Get a stable display name from a filesystem path.
	 * Handles trailing "." and ".." segments (e.g. "/a/b/." -> "b").
	 * @param {string} path
	 * @returns {string}
	 */
	getPathDisplayName(path) {
		if (!path) return "folder";

		const normalized = [];
		for (const segment of String(path).split("/")) {
			if (!segment || segment === ".") continue;
			if (segment === "..") {
				if (normalized.length) normalized.pop();
				continue;
			}
			normalized.push(segment);
		}

		return normalized.pop() || "folder";
	}

	shouldConfirmTerminalClose() {
		const settings = appSettings?.value?.terminalSettings;
		if (settings && settings.confirmTabClose === false) {
			return false;
		}
		return true;
	}
}

// Create singleton instance
const terminalManager = new TerminalManager();

export default terminalManager;
