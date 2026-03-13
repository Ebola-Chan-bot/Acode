const Executor = require("./Executor");

const ALPINE_RELEASES_BASE_URL = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases";
const latestAlpineUrlCache = new Map();
let sharedInstallState = null;

const formatFailureMessage = (value) => {
    if (!value) return "Unknown error";
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.message || value.stack || String(value);
    try {
        return JSON.stringify(value);
    } catch (_) {
        return String(value);
    }
};

const formatLogMessage = (parts) => parts.map((part) => formatFailureMessage(part)).join(" ");

const addSharedInstallListener = (logger, err_logger) => {
    if (!sharedInstallState) {
        return () => {};
    }

    const listener = { logger, err_logger };
    sharedInstallState.listeners.add(listener);
    return () => {
        sharedInstallState?.listeners.delete(listener);
    };
};

const emitSharedInstallMessage = (channel, message) => {
    if (!sharedInstallState) {
        return;
    }

    for (const listener of sharedInstallState.listeners) {
        if (channel === "error") {
            listener.err_logger?.(message);
        } else {
            listener.logger?.(message);
        }
    }
};

const withSharedInstall = async (logger, err_logger, run) => {
    if (sharedInstallState) {
        const detachListener = addSharedInstallListener(logger, err_logger);
        try {
            return await sharedInstallState.promise;
        } finally {
            detachListener();
        }
    }

    const installState = {
        listeners: new Set(),
        promise: null,
    };
    sharedInstallState = installState;

    const detachListener = addSharedInstallListener(logger, err_logger);
    const sharedLogger = (...parts) => {
        emitSharedInstallMessage("log", formatLogMessage(parts));
    };
    const sharedErrLogger = (...parts) => {
        emitSharedInstallMessage("error", formatLogMessage(parts));
    };

    installState.promise = Promise.resolve(run(sharedLogger, sharedErrLogger)).finally(() => {
        detachListener();
        if (sharedInstallState === installState) {
            sharedInstallState = null;
        }
    });

    return installState.promise;
};

const resolveLatestAlpineUrl = async (releaseArch) => {
    const cachedUrl = latestAlpineUrlCache.get(releaseArch);
    if (cachedUrl) {
        return cachedUrl;
    }

    const filesDir = await new Promise((resolve, reject) => {
        system.getFilesDir(resolve, reject);
    });
    const metadataUrl = `${ALPINE_RELEASES_BASE_URL}/${releaseArch}/latest-releases.yaml`;
    const metadataPath = `${filesDir}/.alpine-latest-releases-${releaseArch}.yaml`;

    await Executor.download(metadataUrl, metadataPath);

    const metadata = await Executor.execute(`cat "${metadataPath}"`);
    const matches = [...metadata.matchAll(/^\s*file:\s*(alpine-minirootfs-[^\s]+\.tar\.gz)\s*$/gm)];
    const latestMatch = matches.at(-1);
    if (!latestMatch) {
        throw new Error(`Failed to resolve latest Alpine minirootfs for ${releaseArch}`);
    }

    const alpineUrl = `${ALPINE_RELEASES_BASE_URL}/${releaseArch}/${latestMatch[1]}`;
    latestAlpineUrlCache.set(releaseArch, alpineUrl);
    return alpineUrl;
};

const resolveAlpineBranch = (alpineUrl) => {
    const match = /\/alpine-minirootfs-(\d+\.\d+)\.\d+-/.exec(alpineUrl);
    if (!match) {
        throw new Error(`Failed to resolve Alpine branch from URL: ${alpineUrl}`);
    }
    return `v${match[1]}`;
};

const resolveInstallTargets = (arch) => {
    if (arch === "arm64-v8a") {
        return {
            arch,
            alpineReleaseArch: "aarch64",
            libproot: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot.so",
            libproot32: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot32.so",
            libTalloc: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libtalloc.so",
            prootUrl: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm64/libproot-xed.so",
            axsUrl: "https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-arm64",
        };
    }

    if (arch === "armeabi-v7a") {
        return {
            arch,
            alpineReleaseArch: "armhf",
            libproot: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libproot.so",
            libproot32: null,
            libTalloc: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libtalloc.so",
            prootUrl: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/arm32/libproot-xed.so",
            axsUrl: "https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-armv7",
        };
    }

    if (arch === "x86_64") {
        return {
            arch,
            alpineReleaseArch: "x86_64",
            libproot: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot.so",
            libproot32: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot32.so",
            libTalloc: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libtalloc.so",
            prootUrl: "https://raw.githubusercontent.com/Acode-Foundation/Acode/main/src/plugins/proot/libs/x64/libproot-xed.so",
            axsUrl: "https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-x86_64",
        };
    }

    throw new Error(`Unsupported architecture: ${arch}`);
};

const getInstallTargets = async (arch) => {
    const targets = resolveInstallTargets(arch);
    const alpineUrl = await resolveLatestAlpineUrl(targets.alpineReleaseArch);
    return {
        ...targets,
        alpineUrl,
        alpineBranch: resolveAlpineBranch(alpineUrl),
    };
};

const renderInitAlpineContent = (content, alpineBranch) => {
    return content.replaceAll("__ALPINE_BRANCH__", alpineBranch);
};

const Terminal = {
    async getDownloadTargets() {
        const arch = await new Promise((resolve, reject) => {
            system.getArch(resolve, reject);
        });

        const { alpineUrl, axsUrl } = await getInstallTargets(arch);
        return { arch, alpineUrl, axsUrl };
    },

    async refreshAxs(logger = console.log, err_logger = console.error, force = false) {
        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        const { alpineUrl, axsUrl } = await this.getDownloadTargets();
        const manifestPath = `${filesDir}/.download-manifest`;
        const currentManifest = [alpineUrl, axsUrl].join("\n");
        const savedManifest = await Executor.execute(`cat "${manifestPath}" 2>/dev/null || echo ""`).catch(() => "");
        const hasAxs = await new Promise((resolve) => {
            system.fileExists(`${filesDir}/axs`, false, (result) => resolve(result == 1), () => resolve(false));
        });

        if (!force && hasAxs && savedManifest === currentManifest) {
            return false;
        }

        logger(force ? "♻️  Refreshing axs binary..." : "🔄  AXS source changed, refreshing binary...");
        logger(`🌐  axs source: ${axsUrl}`);

        await Executor.execute(`rm -rf "${filesDir}/axs"`).catch(() => {});

        try {
            await Executor.download(axsUrl, `${filesDir}/axs`, (progress) => {
                const total = progress.total > 0 ? progress.total : 0;
                logger(`⬇️  axs ${progress.downloaded}/${total}`);
            });
            await writeTextFile(manifestPath, currentManifest);
            logger("✅  AXS binary ready");
            return true;
        } catch (error) {
            err_logger("Failed to refresh axs:", error);
            throw error;
        }
    },

    /**
     * Starts the AXS environment by writing init scripts and executing the sandbox.
     * @param {boolean} [installing=false] - Whether AXS is being started during installation.
     * @param {Function} [logger=console.log] - Function to log standard output.
     * @param {Function} [err_logger=console.error] - Function to log errors.
    * @returns {Promise<boolean|{success: boolean, error?: string, exitCode?: string}>} - Returns installation result details when installing, void if not installing
     */
    async startAxs(installing = false, logger = console.log, err_logger = console.error) {
        // Keep app alive in background
        await Executor.moveToForeground().catch(() => {});

        const filesDir = await new Promise((resolve, reject) => {
            system.getFilesDir(resolve, reject);
        });

        await this.refreshAxs(logger, err_logger);

        const { alpineBranch } = await this.getDownloadTargets().then(async ({ arch }) => getInstallTargets(arch));
        const initAlpineContent = renderInitAlpineContent(await readAsset("init-alpine.sh"), alpineBranch);
        const initSandboxContent = await readAsset("init-sandbox.sh");
        const rmWrapperContent = await readAsset("rm-wrapper.sh");

        if (installing) {
            return new Promise((resolve) => {
                (async () => {
                    await writeTextFile(`${filesDir}/init-alpine.sh`, initAlpineContent);
                    await deleteFileIfExists(`${filesDir}/alpine/bin/rm`);
                    await writeTextFile(`${filesDir}/alpine/bin/rm`, rmWrapperContent);
                    await setExecutable(`${filesDir}/alpine/bin/rm`, true);
                    await writeTextFile(`${filesDir}/init-sandbox.sh`, initSandboxContent);

                    Executor.start("sh", (type, data) => {
                        logger(`${type} ${data}`);

                        if (type === "exit") {
                            const success = data === "0";
                            if (success) {
                                const writeMarker = () => {
                                    system.writeText(`${filesDir}/.configured`, "1", () => {
                                        resolve(true);
                                    }, () => {
                                        resolve(true);
                                    });
                                };
                                Executor.execute(`rm -rf "${filesDir}/.configured"`).then(writeMarker).catch(writeMarker);
                            } else {
                                resolve({
                                    success: false,
                                    error: `Terminal installation failed with exit code ${data}`,
                                    exitCode: data,
                                });
                            }
                        }
                    }).then(async (uuid) => {
                        await Executor.write(uuid, `. "${filesDir}/init-sandbox.sh" --installing; exit`);
                    }).catch((error) => {
                        err_logger("Failed to start AXS:", error);
                        resolve({
                            success: false,
                            error: formatFailureMessage(error),
                        });
                    });
                })().catch((error) => {
                    err_logger("Failed to prepare AXS installation:", error);
                    resolve({
                        success: false,
                        error: formatFailureMessage(error),
                    });
                });
            });
        } else {
            await writeTextFile(`${filesDir}/init-alpine.sh`, initAlpineContent);
            await deleteFileIfExists(`${filesDir}/alpine/bin/rm`);
            await writeTextFile(`${filesDir}/alpine/bin/rm`, rmWrapperContent);
            await setExecutable(`${filesDir}/alpine/bin/rm`, true);
            await writeTextFile(`${filesDir}/init-sandbox.sh`, initSandboxContent);

            Executor.start("sh", (type, data) => {
                logger(`${type} ${data}`);
            }).then(async (uuid) => {
                await Executor.write(uuid, `. "${filesDir}/init-sandbox.sh"; exit`);
            }).catch((error) => {
                err_logger("Failed to start AXS:", error);
            });
        }
    },

    /**
     * Stops the AXS process by forcefully killing it.
     * @returns {Promise<void>}
     */
    async stopAxs() {
        await Executor.execute(`kill -KILL $(cat $PREFIX/pid) 2>/dev/null`);
    },

    /**
     * Checks if the AXS process is currently running.
     * @returns {Promise<boolean>} - `true` if AXS is running, `false` otherwise.
     */
    async isAxsRunning() {
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
     * Installs Alpine by downloading binaries and extracting the root filesystem.
     * Also sets up additional dependencies for F-Droid variant.
     * Supports incremental install: skips already-completed steps based on
     * marker files (.downloaded, .extracted, .configured) and existing binaries.
     * @param {Function} [logger=console.log] - Function to log standard output.
     * @param {Function} [err_logger=console.error] - Function to log errors.
     * @returns {Promise<boolean|{success: boolean, error?: string, exitCode?: string}>} - Returns true on success or failure details when installation fails
     */
    async install(logger = console.log, err_logger = console.error, _retried = false) {
        return withSharedInstall(logger, err_logger, async (logger, err_logger) => {
        if (!(await this.isSupported())) {
            return {
                success: false,
                error: "Terminal is not supported on this device architecture",
            };
        }

        // Start foreground service to prevent Android from killing the app
        // during lengthy downloads/extraction when user switches away
        await Executor.moveToForeground().catch(() => {});

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
        const writeText = (path, content) => new Promise((resolve, reject) => {
            system.writeText(path, content, resolve, reject);
        });

        const formatBytes = (bytes) => {
            if (bytes < 1024) return bytes + " B";
            if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
            return (bytes / 1048576).toFixed(1) + " MB";
        };
        const formatEta = (seconds) => {
            if (seconds < 60) return seconds + "s";
            const m = Math.floor(seconds / 60);
            const s = seconds % 60;
            return m + "m" + (s > 0 ? s + "s" : "");
        };
        const formatInstallError = (error) => {
            if (!error) return "unknown error";
            if (typeof error === "string") return error;
            if (error instanceof Error) return error.stack || error.message || String(error);
            try {
                return JSON.stringify(error);
            } catch (_) {
                return String(error);
            }
        };
        const downloadWithLogging = async (label, url, dst, progressHandler) => {
            logger(`🌐  ${label} source: ${url}`);
            try {
                await Executor.download(url, dst, progressHandler);
                logger(`✅  ${label} download finished`);
            } catch (error) {
                logger(`❌  ${label} download failed: ${formatInstallError(error)}`);
                throw error;
            }
        };

        // Check which stages are already done
        let alreadyDownloaded = await fileExists(`${filesDir}/.downloaded`);
        let alreadyExtracted = await fileExists(`${filesDir}/.extracted`);
        let alreadyConfigured = await fileExists(`${filesDir}/.configured`);
        const hasPidFile = await fileExists(`${filesDir}/pid`);
        try {
            const {
                alpineUrl,
                axsUrl,
                prootUrl,
                libTalloc,
                libproot,
                libproot32,
            } = await getInstallTargets(arch);

            // Invalidate download cache if URLs changed (e.g. version bump)
            if (alreadyDownloaded) {
                const currentManifest = [alpineUrl, axsUrl].join("\n");
                const savedManifest = await Executor.execute(`cat "${filesDir}/.download-manifest" 2>/dev/null || echo ""`);
                if (savedManifest !== currentManifest) {
                    logger("🔄  Update detected, clearing download cache...");
                    await Executor.execute(`rm -rf "${filesDir}/.downloaded" "${filesDir}/.extracted" "${filesDir}/.configured" "${filesDir}/alpine" "${filesDir}/alpine.tar.gz" "${filesDir}/alpine.tar" "${filesDir}/axs" "${filesDir}/.download-manifest"`).catch(() => {});
                    alreadyDownloaded = false;
                    alreadyExtracted = false;
                    alreadyConfigured = false;
                }
            }

            // ── Phase 1: Download (skip if .downloaded marker exists) ──
            if (!alreadyDownloaded) {
                // Check individual files and only download what's missing
                const hasAlpineTar = await fileExists(`${filesDir}/alpine.tar.gz`);
                const hasAxs = await fileExists(`${filesDir}/axs`);

                if (!hasAlpineTar) {
                    logger("⬇️  Downloading sandbox filesystem...");
                    await downloadWithLogging("sandbox filesystem", alpineUrl, `${filesDir}/alpine.tar.gz`, (p) => {
                        const dl = formatBytes(p.downloaded);
                        const total = p.total > 0 ? formatBytes(p.total) : "?";
                        const speed = formatBytes(p.speed) + "/s";
                        const eta = p.eta > 0 ? formatEta(p.eta) : "--";
                        logger(`⬇️  ${dl} / ${total}  ${speed}  ETA ${eta}`);
                    });
                } else {
                    logger("✅  Sandbox filesystem already downloaded");
                }

                if (!hasAxs) {
                    logger("⬇️  Downloading axs...");
					await downloadWithLogging("axs", axsUrl, `${filesDir}/axs`, (p) => {
                        const dl = formatBytes(p.downloaded);
                        const total = p.total > 0 ? formatBytes(p.total) : "?";
                        const speed = formatBytes(p.speed) + "/s";
                        const eta = p.eta > 0 ? formatEta(p.eta) : "--";
                        logger(`⬇️  ${dl} / ${total}  ${speed}  ETA ${eta}`);
                    });
                } else {
                    logger("✅  AXS binary already downloaded");
                }

                const isFdroid = await Executor.execute("echo $FDROID");
                if (isFdroid === "true") {
                    logger("🐧  F-Droid flavor detected, checking additional files...");

                    const hasProot = await fileExists(`${filesDir}/libproot-xed.so`);
                    if (!hasProot) {
                        logger("⬇️  Downloading compatibility layer...");
                        await downloadWithLogging("compatibility layer", prootUrl, `${filesDir}/libproot-xed.so`);
                    }

                    const hasTalloc = await fileExists(`${filesDir}/libtalloc.so.2`);
                    if (!hasTalloc) {
                        logger("⬇️  Downloading supporting library...");
                        await downloadWithLogging("supporting library", libTalloc, `${filesDir}/libtalloc.so.2`);
                    }

                    if (libproot != null && !(await fileExists(`${filesDir}/libproot.so`))) {
                        await downloadWithLogging("libproot", libproot, `${filesDir}/libproot.so`);
                    }

                    if (libproot32 != null && !(await fileExists(`${filesDir}/libproot32.so`))) {
                        await downloadWithLogging("libproot32", libproot32, `${filesDir}/libproot32.so`);
                    }
                }

                logger("✅  All downloads completed");

                // Save URL manifest for cache invalidation on version change
                await writeText(`${filesDir}/.download-manifest`, [alpineUrl, axsUrl].join("\n"));

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
                await Executor.execute(`rm -rf "${alpineDir}"`).catch(() => {});
                await new Promise((resolve, reject) => {
                    system.mkdirs(alpineDir, resolve, reject);
                });

                logger("📦  Extracting sandbox filesystem...");
                await Executor.execute(`tar --no-same-owner -xf "${filesDir}/alpine.tar.gz" -C "${alpineDir}"`);

                logger("⚙️  Applying basic configuration...");
                await writeText(`${alpineDir}/etc/resolv.conf`, `nameserver 8.8.4.4\nnameserver 8.8.8.8`);

                const rmWrapperContent = await readAsset("rm-wrapper.sh");
                await deleteFileIfExists(`${alpineDir}/bin/rm`);
                await writeText(`${alpineDir}/bin/rm`, rmWrapperContent);
                await setExecutable(`${alpineDir}/bin/rm`, true);

                logger("✅  Extraction complete");
                await new Promise((resolve, reject) => {
                    system.mkdirs(`${filesDir}/.extracted`, resolve, reject);
                });
            } else {
                logger("✅  Extraction cached, skipping extraction phase");
            }

            // ── Phase 3: Configure (always run — installs packages, creates configs) ──
            logger("⚙️  Updating sandbox enviroment...");
            return this.startAxs(true, logger, err_logger);

        } catch (e) {
            err_logger("Installation failed:", e);
            // Clean up everything so retry starts fresh (including potentially corrupted downloads)
            await Executor.execute(`rm -rf "${filesDir}/.downloaded" "${filesDir}/.extracted" "${filesDir}/.configured" "${filesDir}/alpine" "${filesDir}/alpine.tar.gz" "${filesDir}/alpine.tar" "${filesDir}/.download-manifest"`).catch(() => {});
            if (!_retried) {
                logger("🔄  Retrying installation from scratch...");
                return this.install(logger, err_logger, true);
            }
            return {
                success: false,
                error: formatInstallError(e),
            };
        }
        });
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

            resolve(alpineExists && downloaded && extracted && configured);
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
    },

    /**
     * Fully uninstalls Alpine including download cache.
     * @returns {Promise<string>} Resolves to "ok" when complete.
     */
    uninstallFull() {
        return new Promise(async (resolve, reject) => {
            if (await this.isAxsRunning()) {
                await this.stopAxs();
            }

            const filesDir = await new Promise((resolve, reject) => {
                system.getFilesDir(resolve, reject);
            });

            const cmd = `
            set -e
            rm -rf "${filesDir}/alpine" "${filesDir}/.downloaded" "${filesDir}/.extracted" "${filesDir}/.configured" "${filesDir}/alpine.tar.gz" "${filesDir}/alpine.tar" "${filesDir}/axs" "${filesDir}/libproot-xed.so" "${filesDir}/libtalloc.so.2" "${filesDir}/libproot.so" "${filesDir}/libproot32.so" "${filesDir}/.download-manifest"
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


function writeTextFile(path, content) {
    return new Promise((resolve, reject) => {
        system.writeText(path, content, resolve, reject);
    });
}

function deleteFileIfExists(path) {
    return new Promise((resolve) => {
        system.deleteFile(path, resolve, () => resolve());
    });
}

function setExecutable(path, executable) {
    return new Promise((resolve, reject) => {
        system.setExec(path, executable, resolve, reject);
    });
}

function readAsset(assetPath) {
    const assetUrl = "file:///android_asset/" + assetPath;

    return new Promise((resolve, reject) => {
        window.resolveLocalFileSystemURL(assetUrl, fileEntry => {
            fileEntry.file(file => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result);
                reader.onerror = () => reject(reader.error || new Error(`Failed to read asset: ${assetPath}`));
                reader.readAsText(file);
            }, reject);
        }, reject);
    });
}

module.exports = Terminal;