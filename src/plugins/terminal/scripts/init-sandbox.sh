export LD_LIBRARY_PATH=$PREFIX

mkdir -p "$PREFIX/tmp"
mkdir -p "$PREFIX/alpine/tmp"
mkdir -p "$PREFIX/public"

export PROOT_TMP_DIR=$PREFIX/tmp

# Disable seccomp filter in proot to avoid SIGSEGV/SIGBUS on kernels
# with strict seccomp policies.
# Impact: may slightly reduce syscall-level sandboxing on permissive kernels.
# Rationale: proot's seccomp filter is a performance optimization, not a security
# boundary; disabling it universally is the only way to prevent hard crashes on
# affected devices, with negligible downside on unaffected ones.
export PROOT_NO_SECCOMP=1

if [ "$FDROID" = "true" ]; then

    if [ -f "$PREFIX/libproot.so" ]; then
        export PROOT_LOADER="$PREFIX/libproot.so"
    fi

    if [ -f "$PREFIX/libproot32.so" ]; then
        export PROOT_LOADER32="$PREFIX/libproot32.so"
    fi


    export PROOT="$PREFIX/libproot-xed.so"
    chmod +x $PREFIX/*
else
    if [ -f "$NATIVE_DIR/libproot.so" ]; then
        export PROOT_LOADER="$NATIVE_DIR/libproot.so"
    fi

    if [ -f "$NATIVE_DIR/libproot32.so" ]; then
        export PROOT_LOADER32="$NATIVE_DIR/libproot32.so"
    fi


    if [ -e "$PREFIX/libtalloc.so.2" ] || [ -L "$PREFIX/libtalloc.so.2" ]; then
        rm "$PREFIX/libtalloc.so.2"
    fi

    ln -s "$NATIVE_DIR/libtalloc.so" "$PREFIX/libtalloc.so.2"
    export PROOT="$NATIVE_DIR/libproot-xed.so"
fi

ARGS="--kill-on-exit"



for system_mnt in /apex /odm /product /system /system_ext /vendor /linkerconfig/ld.config.txt /linkerconfig/com.android.art/ld.config.txt /plat_property_contexts /property_contexts; do

 if [ -e "$system_mnt" ]; then
  system_mnt=$(realpath "$system_mnt")
  ARGS="$ARGS -b ${system_mnt}"
 fi
done




unset system_mnt

ARGS="$ARGS -b /sdcard"
ARGS="$ARGS -b /storage"
ARGS="$ARGS -b /dev"
ARGS="$ARGS -b /data"
ARGS="$ARGS -b /dev/urandom:/dev/random"
ARGS="$ARGS -b /proc"
ARGS="$ARGS -b /sys"
ARGS="$ARGS -b $PREFIX"
ARGS="$ARGS -b $PREFIX/public:/public"
ARGS="$ARGS -b $PREFIX/alpine/tmp:/dev/shm"


if [ -e "/proc/self/fd" ]; then
  ARGS="$ARGS -b /proc/self/fd:/dev/fd"
fi


ARGS="$ARGS -r $PREFIX/alpine"
ARGS="$ARGS -0"
ARGS="$ARGS --link2symlink"
# --sysvipc removed: SysV IPC emulation causes Bus Error on some Android kernels.
# Impact: programs relying on SysV semaphores/shared-memory (e.g. PostgreSQL)
# will fail; most CLI tools are unaffected.
# Rationale: Bus Error is an unrecoverable crash that kills the entire proot
# session; the few programs needing SysV IPC are niche in a mobile editor
# context, whereas the crash affects all users on vulnerable kernels.
ARGS="$ARGS -L"

# Android /bin/sh's printf does not support %q, and the previous probe was corrupting
# the very failure window we are trying to inspect. Keep this log strictly %s-based so
# the next 182 repro preserves the real proot arguments instead of replacing them with
# printf errors. 仅调试用
printf '[sandbox:proot-begin,pid=%s,ppid=%s,proot=%s,loader=%s,loader32=%s,prefix=%s,tmp=%s,args=%s]\n' "$$" "$PPID" "$PROOT" "${PROOT_LOADER:-unset}" "${PROOT_LOADER32:-unset}" "$PREFIX" "${PROOT_TMP_DIR:-unset}" "$ARGS" >&2 # 仅调试用
ls -l "$PROOT" "$PREFIX/init-alpine.sh" /bin/sh 2>&1 | sed 's/^/[sandbox:ls] /' >&2 # 仅调试用
# 仅调试用: Pre-proot environment snapshot — diagnose stale state from previous proot
# sessions causing signal 54 (SIGRTMIN+20) on first launch after app reinstall.
# PROOT_TMP_DIR is shared across proot instances; stale tracking files may confuse
# the new proot's ptrace setup.
ls -la "$PROOT_TMP_DIR" 2>&1 | sed 's/^/[sandbox:tmpdir] /' >&2 # 仅调试用
ls -la "$PREFIX/alpine/tmp" 2>&1 | sed 's/^/[sandbox:alpineTmp] /' >&2 # 仅调试用
cat "$PREFIX/pid" 2>/dev/null | sed 's/^/[sandbox:pidfile] /' >&2 || echo "[sandbox:pidfile=<none>]" >&2 # 仅调试用
# 仅调试用: Check for lingering proot/axs/bash processes from previous sessions.
# If old proot is still alive, its --kill-on-exit cleanup may race with new proot.
# BUG FIX: 原来用 `cmd | grep | sed >&2 || echo fallback`, 但 sed 空输入时仍返回 0,
# 导致 || fallback 永远不触发, 两个探针在无匹配时静默输出零字节。
# 改用变量捕获 + 判空, 确保无论是否有匹配都有输出。
_sandbox_ps=$(ps -e -o pid,ppid,comm 2>/dev/null | grep -E 'proot|axs|init-alpine|init-sandbox' | grep -v grep) # 仅调试用
if [ -n "$_sandbox_ps" ]; then echo "$_sandbox_ps" | sed 's/^/[sandbox:ps] /' >&2; else echo "[sandbox:ps=<none>]" >&2; fi # 仅调试用
# 仅调试用: Check /proc/net/tcp for port 8767 (0x2237) — if old axs still holds the port,
# new axs will fail to bind.
_sandbox_port=$(grep ':2237 ' /proc/net/tcp 2>/dev/null) # 仅调试用
if [ -n "$_sandbox_port" ]; then echo "$_sandbox_port" | sed 's/^/[sandbox:port8767] /' >&2; else echo "[sandbox:port8767=<none>]" >&2; fi # 仅调试用
$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@"
proot_rc=$? # 仅调试用
printf '[sandbox:proot-rc=%s,installing=%s,args=%s]\n' "$proot_rc" "$1" "$*" >&2 # 仅调试用
# 仅调试用: signal analysis — exit codes > 128 indicate the child was killed by
# signal (exit_code - 128). 182 - 128 = 54, which is SIGRTMIN+20 on Linux.
# If [alpine:L1] probe is ABSENT in the log above, /bin/sh never started
# inside proot — the crash is in proot's ptrace setup, not the script.
if [ "$proot_rc" -ne 0 ]; then
    if [ "$proot_rc" -gt 128 ]; then
        printf '[sandbox:signal=%s,code=128+%s]\n' "$((proot_rc - 128))" "$((proot_rc - 128))" >&2
    fi
    stat "$PROOT" "$PREFIX/init-alpine.sh" /bin/sh 2>&1 | sed 's/^/[sandbox:stat] /' >&2
    # Check if libtalloc symlink is valid — broken symlink would prevent proot from loading
    ls -lL "$PREFIX/libtalloc.so.2" 2>&1 | sed 's/^/[sandbox:libtalloc] /' >&2
    # 仅调试用: Post-failure PROOT_TMP_DIR snapshot — compare with pre-launch [sandbox:tmpdir]
    # to detect if proot created then abandoned tracking files during the failed launch.
    ls -la "$PROOT_TMP_DIR" 2>&1 | sed 's/^/[sandbox:tmpdir-after] /' >&2 # 仅调试用
    # 仅调试用: Check if any new proot/axs processes appeared or if old ones are still around
    ps -e -o pid,ppid,comm 2>/dev/null | grep -E 'proot|axs|init-alpine|init-sandbox' | grep -v grep | sed 's/^/[sandbox:ps-after] /' >&2 || echo "[sandbox:ps-after=<none>]" >&2 # 仅调试用
fi
exit "$proot_rc"
