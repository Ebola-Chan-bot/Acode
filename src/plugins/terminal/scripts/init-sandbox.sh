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

# Suppress proot INFO/WARNING diagnostic messages (e.g. vdso guard zone,
# PIE relocation, root tracee exit status). Only ERROR is preserved.
# Root cause: proot's note() prints to stderr at verbose>=0 by default,
# flooding the terminal lifecycle output with internal diagnostics.
export PROOT_VERBOSE=-1

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

# Kill lingering proot from previous session before starting a new one.
# Using PID file for precision (not pkill) to avoid killing unrelated processes.
_old_pid=$(cat "$PREFIX/pid" 2>/dev/null)
if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
    kill -TERM "$_old_pid" 2>/dev/null
    _wait_i=0
    while [ "$_wait_i" -lt 20 ] && kill -0 "$_old_pid" 2>/dev/null; do
        sleep 0.1
        _wait_i=$((_wait_i + 1))
    done
    if kill -0 "$_old_pid" 2>/dev/null; then
        kill -KILL "$_old_pid" 2>/dev/null
        sleep 0.2
    fi
fi
# Clear stale ptrace tracking files
rm -rf "$PROOT_TMP_DIR"/*

$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@" &
proot_pid=$!
wait "$proot_pid"
exit $?
