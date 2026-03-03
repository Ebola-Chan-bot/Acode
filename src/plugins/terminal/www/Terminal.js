const Executor = require("./Executor");

const Terminal = {
    // Track AXS operational mode: null, 'inside-proot', or 'outside-proot'
    _axsMode: null,
    // Set to true when inside-proot AXS is unreachable from WebView
    _outsideProot: false,
    /**
     * Starts the AXS environment by writing init scripts and executing the sandbox.
     * @param {boolean} [installing=false] - Whether AXS is being started during installation.
     * @param {Function} [logger=console.log] - Function to log standard output.
     * @param {Function} [err_logger=console.error] - Function to log errors.
     * @returns {Promise<boolean>} - Returns true if installation completes with exit code 0, void if not installing
     */
    async startAxs(installing = false, logger = console.log, err_logger = console.error) {
        // Keep app alive in background
        await Executor.moveToForeground().catch(() => {});

        // Set up native Java logging to debug server (survives background)
        console.log(`[Terminal:startAxs] __debugHost=${window.__debugHost}`);
        if (window.__debugHost) {
            try {
                const r = await Executor.setLogServer(`http://${window.__debugHost}`);
                console.log(`[Terminal:startAxs] setLogServer result: ${r}`);
            } catch (e) {
                console.error(`[Terminal:startAxs] setLogServer failed:`, e);
            }
        }

        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        // === Run PTY capability test immediately (no sandbox needed) ===
        try {
            await new Promise((resolve, reject) => {
                system.copyAsset("pty_test", `${filesDir}/pty_test`, resolve, reject);
            });
            await new Promise((resolve, reject) => {
                system.setExec(`${filesDir}/pty_test`, "true", resolve, reject);
            });
            const ptyResult = await Executor.execute(`${filesDir}/pty_test`);
            console.log("[PTY-TEST] " + ptyResult);
            logger("[PTY-TEST] " + ptyResult);
        } catch (e) {
            console.error("[PTY-TEST] failed:", e);
            logger("[PTY-TEST] error: " + e);
        }
        // === End PTY test ===

        if (installing) {
            return new Promise((resolve, reject) => {
                readAsset("init-alpine.sh", async (content) => {
                    system.writeText(`${filesDir}/init-alpine.sh`, content, logger, err_logger);
                });

                readAsset("rm-wrapper.sh", async (content) => {
                    system.deleteFile(`${filesDir}/alpine/bin/rm`, logger, err_logger);
                    system.writeText(`${filesDir}/alpine/bin/rm`, content, logger, err_logger);
                    system.setExec(`${filesDir}/alpine/bin/rm`, true, logger, err_logger);
                });

                readAsset("init-sandbox.sh", (content) => {
                    system.writeText(`${filesDir}/init-sandbox.sh`, content, logger, err_logger);

                    Executor.start("sh", (type, data) => {
                        logger(`${type} ${data}`);

                        // Check for exit code during installation
                        if (type === "exit") {
                            const success = data === "0";
                            if (success) {
                                // Delete old .configured if it's a directory (from earlier proot mkdir -p).
                                // Then create it as a file via writeText (idempotent).
                                const writeMarker = () => {
                                    system.writeText(`${filesDir}/.configured`, "1", () => {
                                        console.log(`[Terminal:startAxs] .configured marker created`);
                                        resolve(true);
                                    }, (err) => {
                                        console.error(`[Terminal:startAxs] Failed to create .configured:`, err);
                                        resolve(true); // still consider install OK
                                    });
                                };
                                // Try to remove old directory first, ignore errors
                                Executor.execute(`rm -rf "${filesDir}/.configured"`).then(writeMarker).catch(writeMarker);
                            } else {
                                resolve(false);
                            }
                        }
                    }).then(async (uuid) => {
                        await Executor.write(uuid, `source ${filesDir}/init-sandbox.sh ${installing ? "--installing" : ""}; exit`);
                    }).catch((error) => {
                        err_logger("Failed to start AXS:", error);
                        resolve(false);
                    });
                });
            });
        } else {
            readAsset("rm-wrapper.sh", async (content) => {
                system.deleteFile(`${filesDir}/alpine/bin/rm`, logger, () => {});
                system.writeText(`${filesDir}/alpine/bin/rm`, content, logger, () => {});
                system.setExec(`${filesDir}/alpine/bin/rm`, true, logger, () => {});
            });

            readAsset("init-alpine.sh", async (content) => {
                system.writeText(`${filesDir}/init-alpine.sh`, content, logger, () => {});
            });

            readAsset("init-sandbox.sh", (content) => {
                system.writeText(`${filesDir}/init-sandbox.sh`, content, logger, () => {});

                Executor.start("sh", (type, data) => {
                    // Always log non-installing output to console for debugging
                    console.log(`[Terminal:startAxs:non-install] ${type} ${data}`);
                    // Parse AXS listening address from stdout or stderr
                    // (Rust tracing/log may write to either stream)
                    if ((type === 'stdout' || type === 'stderr') && data.includes('listening on')) {
                        const match = data.match(/listening on (\S+):(\d+)/);
                        if (match) {
                            Terminal.axsHost = match[1];
                            Terminal.axsPort = parseInt(match[2]);
                            Terminal._axsRunning = true;
                            Terminal._axsMode = Terminal._outsideProot ? 'outside-proot' : 'inside-proot';
                            console.log(`[Terminal:startAxs] AXS address detected: ${Terminal.axsHost}:${Terminal.axsPort} (mode=${Terminal._axsMode})`);
                        }
                    }
                    // Detect AXS exit
                    if (type === 'exit') {
                        Terminal._axsRunning = false;
                        Terminal._axsMode = null;
                        console.log(`[Terminal:startAxs:non-install] process exited: ${data}`);
                    }
                }).then(async (uuid) => {
                    if (Terminal._outsideProot) {
                        // === Outside-proot mode (fallback) ===
                        // AXS runs outside proot for network accessibility.
                        // PTY may fail on some devices (卓易通/HarmonyOS).
                        const cmd = [
                            `source ${filesDir}/init-sandbox.sh --setup-only`,
                            // PTY diagnostics
                            `echo "DEBUG-PTY: /dev/ptmx: $(ls -la /dev/ptmx 2>&1)"`,
                            `echo "DEBUG-PTY: /dev/pts: $(ls -la /dev/pts/ 2>&1)"`,
                            `echo "DEBUG-PTY: id: $(id 2>&1)"`,
                            `echo "DEBUG-PTY: getenforce: $(getenforce 2>&1)"`,
                            // Determine which shell is available in Alpine
                            `if [ -f "$PREFIX/alpine/usr/bin/bash" ] || [ -f "$PREFIX/alpine/bin/bash" ]; then`,
                            `    SHELL_CMD="/bin/bash --rcfile $PREFIX/alpine/initrc -i"`,
                            `else`,
                            `    SHELL_CMD="/bin/sh -l"`,
                            `fi`,
                            // Start AXS outside proot
                            `echo "DEBUG-PHASE2: starting AXS outside proot"`,
                            `"$PREFIX/axs" --ip --allow-any-origin -c "$PROOT $ARGS $SHELL_CMD" &`,
                            `AXS_PID=$!`,
                            `echo $AXS_PID > $PREFIX/pid`,
                            `echo "DEBUG-PHASE2: AXS PID=$AXS_PID"`,
                            `wait $AXS_PID`,
                        ].join('\n');
                        await Executor.write(uuid, cmd);
                    } else {
                        // === Inside-proot mode (default) ===
                        // AXS runs inside proot where PTY works via proot's
                        // syscall interception. init-sandbox.sh starts proot which
                        // runs init-alpine.sh which starts AXS.
                        await Executor.write(uuid, `source ${filesDir}/init-sandbox.sh; exit`);
                    }
                }).catch((error) => {
                    console.error(`[Terminal:startAxs:non-install] Executor failed:`, error);
                });
            });
        }
    },

    /**
     * Stops the AXS process by forcefully killing it.
     * @returns {Promise<void>}
     */
    async stopAxs() {
        Terminal._axsRunning = false;
        Terminal._axsMode = null;
        Terminal.axsHost = null;
        Terminal.axsPort = null;
        await Executor.execute(`kill -KILL $(cat $PREFIX/pid)`);
    },

    /**
     * Checks if the AXS process is currently running.
     * @returns {Promise<boolean>} - `true` if AXS is running, `false` otherwise.
     */
    async isAxsRunning() {
        // Fast path: detected "listening on" from AXS stdout
        if (Terminal._axsRunning) return true;

        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        const pidExists = await new Promise((resolve, reject) => {
            system.fileExists(`${filesDir}/pid`, false, (result) => {
                resolve(result == 1);
            }, reject);
        });

        if (!pidExists) return false;

        const result = await Executor.BackgroundExecutor.execute(`kill -0 $(cat $PREFIX/pid) 2>/dev/null && echo "true" || echo "false"`);
        return String(result).toLowerCase() === "true";
    },

    /**
     * Get the device's LAN IP address.
     * On HarmonyOS/卓易通, localhost doesn't reach processes in the Android layer,
     * so we need the LAN IP for AXS connections.
     * @returns {Promise<string>} - LAN IP or "localhost" as fallback.
     */
    async getDeviceIp() {
        try {
            // ip route: "... src 192.168.x.x ..."
            const result = await Executor.BackgroundExecutor.execute(
                `ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+' || hostname -I 2>/dev/null | awk '{print $1}' || echo localhost`
            );
            const ip = String(result).trim();
            console.log(`[Terminal:getDeviceIp] detected: ${ip}`);
            return ip && ip !== "" ? ip : "localhost";
        } catch (e) {
            console.error(`[Terminal:getDeviceIp] failed:`, e);
            return "localhost";
        }
    },

    /**
     * Installs Alpine by downloading binaries and extracting the root filesystem.
     * Also sets up additional dependencies for F-Droid variant.
     * Supports incremental install: skips already-completed steps based on
     * marker files (.downloaded, .extracted, .configured) and existing binaries.
     * @param {Function} [logger=console.log] - Function to log standard output.
     * @param {Function} [err_logger=console.error] - Function to log errors.
     * @returns {Promise<boolean>} - Returns true if installation completes with exit code 0
     */
    async install(logger = console.log, err_logger = console.error, _retried = false) {
        if (!(await this.isSupported())) return false;

        // Start foreground service to prevent Android from killing the app
        // during lengthy downloads/extraction when user switches away
        await Executor.moveToForeground().catch(() => {});

        // Set up native Java logging to debug server (survives background)
        if (window.__debugHost) {
            await Executor.setLogServer(`http://${window.__debugHost}`).catch(() => {});
        }

        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        const arch = await new Promise((resolve, reject) => {
            system.getArch(resolve, reject);
        });

        // Helper: check if a file exists
        const fileExists = (path) => new Promise((resolve) => {
            system.fileExists(path, false, (result) => resolve(result == 1), () => resolve(false));
        });

        // Check which stages are already done
        const alreadyDownloaded = await fileExists(`${filesDir}/.downloaded`);
        const alreadyExtracted = await fileExists(`${filesDir}/.extracted`);
        const alreadyConfigured = await fileExists(`${filesDir}/.configured`);

        console.log(`[Terminal:install] stages: downloaded=${alreadyDownloaded} extracted=${alreadyExtracted} configured=${alreadyConfigured}`);

        // Only do full cleanup if nothing was downloaded yet (fresh install)
        if (!alreadyDownloaded) {
            try {
                await this.uninstall();
            } catch (e) {
                // suppress error
            }
        }

        try {
            let alpineUrl;
            let axsUrl;
            let prootUrl;
            let libTalloc;
            let libproot = null;
            let libproot32 = null;

            if (arch === "arm64-v8a") {
                libproot = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot.so";
                libproot32 = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot32.so";
                libTalloc = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libtalloc.so";
                prootUrl = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot-xed.so";
                axsUrl = `https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-arm64`;
                alpineUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz";
            } else if (arch === "armeabi-v7a") {
                libproot = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libproot.so";
                libTalloc = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libtalloc.so";
                prootUrl = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libproot-xed.so";
                axsUrl = `https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-armv7`;
                alpineUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/armhf/alpine-minirootfs-3.21.0-armhf.tar.gz";
            } else if (arch === "x86_64") {
                libproot = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot.so";
                libproot32 = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot32.so";
                libTalloc = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libtalloc.so";
                prootUrl = "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot-xed.so";
                axsUrl = `https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-x86_64`;
                alpineUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz";
            } else {
                throw new Error(`Unsupported architecture: ${arch}`);
            }

            // ── Phase 1: Download (skip if .downloaded marker exists) ──
            if (!alreadyDownloaded) {
                // Check individual files and only download what's missing
                const hasAlpineTar = await fileExists(`${filesDir}/alpine.tar.gz`);
                const hasAxs = await fileExists(`${filesDir}/axs`);

                if (!hasAlpineTar) {
                    logger("⬇️  Downloading sandbox filesystem...");
                    await Executor.download(alpineUrl, `${filesDir}/alpine.tar.gz`);
                } else {
                    logger("✅  Sandbox filesystem already downloaded");
                }

                if (!hasAxs) {
                    logger("⬇️  Downloading axs...");
                    await Executor.download(axsUrl, `${filesDir}/axs`);
                } else {
                    logger("✅  AXS binary already downloaded");
                }

                const isFdroid = await Executor.execute("echo $FDROID");
                if (isFdroid === "true") {
                    logger("🐧  F-Droid flavor detected, checking additional files...");

                    const hasProot = await fileExists(`${filesDir}/libproot-xed.so`);
                    if (!hasProot) {
                        logger("⬇️  Downloading compatibility layer...");
                        await Executor.download(prootUrl, `${filesDir}/libproot-xed.so`);
                    }

                    const hasTalloc = await fileExists(`${filesDir}/libtalloc.so.2`);
                    if (!hasTalloc) {
                        logger("⬇️  Downloading supporting library...");
                        await Executor.download(libTalloc, `${filesDir}/libtalloc.so.2`);
                    }

                    if (libproot != null && !(await fileExists(`${filesDir}/libproot.so`))) {
                        await Executor.download(libproot, `${filesDir}/libproot.so`);
                    }

                    if (libproot32 != null && !(await fileExists(`${filesDir}/libproot32.so`))) {
                        await Executor.download(libproot32, `${filesDir}/libproot32.so`);
                    }
                }

                logger("✅  All downloads completed");

                logger("📁  Setting up directories...");
                await new Promise((resolve, reject) => {
                    system.mkdirs(`${filesDir}/.downloaded`, resolve, reject);
                });
            } else {
                logger("✅  Downloads cached, skipping download phase");
            }

            // ── Phase 2: Extract (skip if .extracted marker exists) ──
            if (!alreadyExtracted) {
                const alpineDir = `${filesDir}/alpine`;

                // Clean up partial extraction from previous failed attempt
                await Executor.execute(`rm -rf ${alpineDir}`).catch(() => {});
                await new Promise((resolve, reject) => {
                    system.mkdirs(alpineDir, resolve, reject);
                });

                logger("📦  Extracting sandbox filesystem...");
                // 卓易通 toybox gzclose() ioctl bug breaks shell-based gzip.
                // Decompress in Java via GZIPInputStream, then plain tar extract.
                const tarFile = `${filesDir}/alpine.tar`;
                await Executor.gunzip(`${filesDir}/alpine.tar.gz`, tarFile);
                await Executor.execute(`tar --no-same-owner -xf ${tarFile} -C ${alpineDir}`);
                await Executor.execute(`rm -f ${tarFile}`);

                logger("⚙️  Applying basic configuration...");
                system.writeText(`${alpineDir}/etc/resolv.conf`, `nameserver 8.8.4.4\nnameserver 8.8.8.8`);

                readAsset("rm-wrapper.sh", async (content) => {
                    system.deleteFile(`${alpineDir}/bin/rm`, logger, err_logger);
                    system.writeText(`${alpineDir}/bin/rm`, content, logger, err_logger);
                    system.setExec(`${alpineDir}/bin/rm`, true, logger, err_logger);
                });

                logger("✅  Extraction complete");
                await new Promise((resolve, reject) => {
                    system.mkdirs(`${filesDir}/.extracted`, resolve, reject);
                });
            } else {
                logger("✅  Extraction cached, skipping extraction phase");
            }

            // ── Phase 3: Configure (always run — installs packages, creates configs) ──
            logger("⚙️  Updating sandbox enviroment...");
            const installResult = await this.startAxs(true, logger, err_logger);
            // .configured marker is now created inside startAxs(true) via system.writeText
            return installResult;

        } catch (e) {
            err_logger("Installation failed:", e);
            console.error("Installation failed:", e);
            // Clean up everything so retry starts fresh (including potentially corrupted downloads)
            await Executor.execute(`rm -rf ${filesDir}/.downloaded ${filesDir}/.extracted ${filesDir}/.configured ${filesDir}/alpine ${filesDir}/alpine.tar.gz ${filesDir}/alpine.tar`).catch(() => {});
            if (!_retried) {
                logger("🔄  Retrying installation from scratch...");
                return this.install(logger, err_logger, true);
            }
            return false;
        }
    },

    /**
     * Checks if alpine is already installed.
     * @returns {Promise<boolean>} - Returns true if all required files and directories exist.
     */
    isInstalled() {
        return new Promise(async (resolve, reject) => {
            const filesDir = await new Promise((resolve, reject) => {
                system.getFilesDir(resolve, reject);
            });

            const alpineExists = await new Promise((resolve, reject) => {
                system.fileExists(`${filesDir}/alpine`, false, (result) => {
                    resolve(result == 1);
                }, reject);
            });

            const downloaded = alpineExists && await new Promise((resolve, reject) => {
                system.fileExists(`${filesDir}/.downloaded`, false, (result) => {
                    resolve(result == 1);
                }, reject);
            });

            const extracted = alpineExists && await new Promise((resolve, reject) => {
                system.fileExists(`${filesDir}/.extracted`, false, (result) => {
                    resolve(result == 1);
                }, reject);
            });

            const configured = alpineExists && await new Promise((resolve, reject) => {
                system.fileExists(`${filesDir}/.configured`, false, (result) => {
                    resolve(result == 1);
                }, reject);
            });

            const result = alpineExists && downloaded && extracted && configured;
            console.log(`[Terminal:isInstalled] alpine=${alpineExists} downloaded=${downloaded} extracted=${extracted} configured=${configured} => ${result}`);
            resolve(result);
        });
    },

    /**
     * Checks if the current device architecture is supported.
     * @returns {Promise<boolean>} - `true` if architecture is supported, otherwise `false`.
     */
    isSupported() {
        return new Promise((resolve, reject) => {
            system.getArch((arch) => {
                resolve(["arm64-v8a", "armeabi-v7a", "x86_64"].includes(arch));
            }, reject);
        });
    },
    /**
     * Creates a backup of the Alpine Linux installation
     * @async
     * @function backup
     * @description Creates a compressed tar archive of the Alpine installation
     * @returns {Promise<string>} Promise that resolves to the file URI of the created backup file (aterm_backup.tar)
     * @throws {string} Rejects with "Alpine is not installed." if Alpine is not currently installed
     * @throws {string} Rejects with command output if backup creation fails
     * @example
     * try {
     *   const backupPath = await backup();
     *   console.log(`Backup created at: ${backupPath}`);
     * } catch (error) {
     *   console.error(`Backup failed: ${error}`);
     * }
     */
    backup() {
        return new Promise(async (resolve, reject) => {
            if (!await this.isInstalled()) {
                reject("Alpine is not installed.");
                return;
            }

            const cmd = `
            set -e

            INCLUDE_FILES="alpine .downloaded .extracted axs"
            if [ "$FDROID" = "true" ]; then
                INCLUDE_FILES="$INCLUDE_FILES libtalloc.so.2 libproot-xed.so"
            fi

            EXCLUDE="--exclude=alpine/data --exclude=alpine/system --exclude=alpine/vendor --exclude=alpine/sdcard --exclude=alpine/storage --exclude=alpine/public"

            tar -cf "$PREFIX/aterm_backup.tar" -C "$PREFIX" $EXCLUDE $INCLUDE_FILES
            echo "ok"
            `;

            const result = await Executor.execute(cmd);
            if (result === "ok") {
                resolve(cordova.file.dataDirectory + "aterm_backup.tar");
            } else {
                reject(result);
            }
        });
    },
    /**
     * Restores Alpine Linux installation from a backup file
     * @async
     * @function restore
     * @description Restores the Alpine installation from a previously created backup file (aterm_backup.tar).
     * This function stops any running Alpine processes, removes existing installation files, and extracts
     * the backup to restore the previous state. The backup file must exist in the expected location.
     * @returns {Promise<string>} Promise that resolves to "ok" when restoration completes successfully
     * @throws {string} Rejects with "Backup File does not exist" if aterm_backup.tar is not found
     * @throws {string} Rejects with command output if restoration fails
     * @example
     * try {
     *   await restore();
     *   console.log("Alpine installation restored successfully");
     * } catch (error) {
     *   console.error(`Restore failed: ${error}`);
     * }
     */
    restore() {
        return new Promise(async (resolve, reject) => {
            if (await this.isAxsRunning()) {
                await this.stopAxs();
            }

            const cmd = `
            sleep 2

            INCLUDE_FILES="$PREFIX/alpine $PREFIX/.downloaded $PREFIX/.extracted $PREFIX/axs"

            if [ "$FDROID" = "true" ]; then
                INCLUDE_FILES="$INCLUDE_FILES $PREFIX/libtalloc.so.2 $PREFIX/libproot-xed.so"
            fi

            for item in $INCLUDE_FILES; do
                rm -rf -- "$item"
            done

            tar -xf "$PREFIX/aterm_backup.bin" -C "$PREFIX"
            echo "ok"
            `;

            const result = await Executor.execute(cmd);
            if (result === "ok") {
                resolve(result);
            } else {
                reject(result);
            }
        });
    },
    /**
     * Removes the .configured marker so the next terminal open triggers re-install.
     * Does NOT delete the rootfs or downloaded files — only the config flag.
     * @returns {Promise<boolean>} - `true` if marker is removed, `false` otherwise.
     */
    async resetConfigured() {
        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        try {
            await Executor.execute(`rm -rf "$PREFIX/.configured" "${filesDir}/.configured"`);
        } catch (error) {
            // continue to existence check below
        }

        const stillExists = await new Promise((resolve, reject) => {
            system.fileExists(`${filesDir}/.configured`, false, (result) => {
                resolve(result == 1);
            }, reject);
        });

        return !stillExists;
    },

    /**
     * Uninstalls the Alpine Linux installation
     * @async
     * @function uninstall
     * @description Removes the Alpine Linux rootfs and config markers, but preserves
     * downloaded binaries (alpine.tar.gz, axs) as cache for faster re-install.
     * Use uninstallFull() to also remove the download cache.
     * @returns {Promise<string>} Promise that resolves to "ok" when uninstallation completes successfully
     * @throws {string} Rejects with command output if uninstallation fails
     */
    uninstall() {
        return new Promise(async (resolve, reject) => {
            if (await this.isAxsRunning()) {
                await this.stopAxs();
            }

            // Remove rootfs and markers, but keep downloaded files as cache
            // (alpine.tar.gz, axs binary, libproot*.so, libtalloc.so.2)
            const cmd = `
            set -e

            INCLUDE_FILES="$PREFIX/alpine $PREFIX/.downloaded $PREFIX/.extracted $PREFIX/.configured"

            for item in $INCLUDE_FILES; do
                rm -rf -- "$item"
            done

            echo "ok"
            `;
            const result = await Executor.execute(cmd);
            if (result === "ok") {
                resolve(result);
            } else {
                reject(result);
            }
        });
    }
};


function readAsset(assetPath, callback) {
    const assetUrl = "file:///android_asset/" + assetPath;

    window.resolveLocalFileSystemURL(assetUrl, fileEntry => {
        fileEntry.file(file => {
            const reader = new FileReader();
            reader.onloadend = () => callback(reader.result);
            reader.readAsText(file);
        }, console.error);
    }, console.error);
}

module.exports = Terminal;