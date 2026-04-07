export LD_LIBRARY_PATH=$PREFIX

mkdir -p "$PREFIX/tmp"
mkdir -p "$PREFIX/alpine/tmp"
mkdir -p "$PREFIX/public"

export PROOT_TMP_DIR=$PREFIX/tmp

# 182 policy switch: set to retry to auto-retry on SIGRT54, or failfast to
# stop immediately for debugging.
AXS_EXIT_182_POLICY="${AXS_EXIT_182_POLICY:-failfast}"

should_retry_on_182() {
    local _rc="$1"
    [ "$_rc" -eq 182 ] || return 1
    [ "$AXS_EXIT_182_POLICY" = "retry" ] || return 1
    return 0
}

# Collect signal masks using only shell builtins (read + case + printf).
# grep/tr are external commands that may be unreliable under proot ptrace.
_collect_masks() { # 仅调试用
    local _m="" _l="" # 仅调试用
    while IFS= read -r _l; do # 仅调试用
        case "$_l" in # 仅调试用
            Sig*) _m="${_m}${_l}|" ;; # 仅调试用
        esac # 仅调试用
    done < /proc/self/status 2>/dev/null # 仅调试用
    printf '%s' "$_m" # 仅调试用
} # 仅调试用

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

# Kill lingering proot from previous session before starting a new one.
# NOTE: Log analysis of 5 sessions showed sandbox:ps=<none> every time — no
# concurrent proot was ever alive. Signal 54 still killed proot as sole instance.
# Concurrent-proot theory was DISPROVEN. This cleanup is kept as defensive
# measure. Root cause of signal 54 is still under investigation.
# Using PID file for precision (not pkill) to avoid killing unrelated processes.
_old_pid=$(cat "$PREFIX/pid" 2>/dev/null)
if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
    printf '[sandbox:cleanup,old_pid=%s,sending=TERM]\n' "$_old_pid" >&2
    kill -TERM "$_old_pid" 2>/dev/null
    _wait_i=0
    while [ "$_wait_i" -lt 20 ] && kill -0 "$_old_pid" 2>/dev/null; do
        sleep 0.1
        _wait_i=$((_wait_i + 1))
    done
    if kill -0 "$_old_pid" 2>/dev/null; then
        printf '[sandbox:cleanup,old_pid=%s,TERM-timeout,sending=KILL]\n' "$_old_pid" >&2
        kill -KILL "$_old_pid" 2>/dev/null
        sleep 0.2
    fi
    printf '[sandbox:cleanup,old_pid=%s,done,still_alive=%s]\n' "$_old_pid" "$(kill -0 "$_old_pid" 2>/dev/null && echo y || echo n)" >&2
fi
# Clear stale ptrace tracking files
rm -rf "$PROOT_TMP_DIR"/*
printf '[sandbox:enter,PREFIX=%s,PROOT=%s]\n' "$PREFIX" "$PROOT" >&2 # 仅调试用

# Signal 54 (SIGRTMIN+20) kills proot or its tracee unpredictably during startup,
# producing exit code 182 (128+54). The signal is transient and a simple retry
# always succeeds within a few attempts.
_proot_retry=0
while true; do
    _proot_retry=$((_proot_retry + 1))

    # Clear stale ptrace tracking files from previous failed attempt
    rm -rf "$PROOT_TMP_DIR"/*

    printf '[sandbox:proot-launch,retry=%s,args=%s]\n' "$_proot_retry" "$*" >&2 # 仅调试用
    printf '[sandbox:proot-pre,retry=%s,proot_exists=%s,proot_exec=%s,sh_exists=%s,sh_exec=%s,init_exists=%s,init_exec=%s,tmp_writable=%s,masks=%s]\n' "$_proot_retry" "$(test -f "$PROOT" && echo y || echo n)" "$(test -x "$PROOT" && echo y || echo n)" "$(test -f /bin/sh && echo y || echo n)" "$(test -x /bin/sh && echo y || echo n)" "$(test -f "$PREFIX/init-alpine.sh" && echo y || echo n)" "$(test -x "$PREFIX/init-alpine.sh" && echo y || echo n)" "$(test -w "$PROOT_TMP_DIR" && echo y || echo n)" "$(_collect_masks)" >&2 # 仅调试用
    $PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@" &
    proot_pid=$!
    wait "$proot_pid"
    proot_rc=$?
    printf '[sandbox:proot-exited,rc=%s,retry=%s]\n' "$proot_rc" "$_proot_retry" >&2 # 仅调试用
    printf '[sandbox:proot-post,rc=%s,retry=%s,inferred_signal=%s,init_exists_after=%s,tmp_writable_after=%s,masks_after=%s]\n' "$proot_rc" "$_proot_retry" "$( [ "$proot_rc" -ge 128 ] && echo $((proot_rc - 128)) || echo '<none>' )" "$(test -f "$PREFIX/init-alpine.sh" && echo y || echo n)" "$(test -w "$PROOT_TMP_DIR" && echo y || echo n)" "$(_collect_masks)" >&2 # 仅调试用

    # Exit code 182 policy is controlled by AXS_EXIT_182_POLICY.
    if [ "$proot_rc" -eq 182 ]; then
        if should_retry_on_182 "$proot_rc"; then
            printf '[sandbox:proot-retry,rc=%s,retry=%s]\n' "$proot_rc" "$_proot_retry" >&2 # 仅调试用
            continue
        fi
        printf '[sandbox:proot-failfast-182,rc=%s,retry=%s]\n' "$proot_rc" "$_proot_retry" >&2 # 仅调试用
        break
    fi

    break
done

exit "$proot_rc"
