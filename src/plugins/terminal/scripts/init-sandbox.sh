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
printf '[sandbox:invoke-shell=%s,script=%s,installing=%s,args=%s]\n' "/bin/sh" "$PREFIX/init-alpine.sh" "$1" "$*" >&2 # 仅调试用
awk '/^Sig(Q|Pnd|Blk|Ign|Cgt):/ {print}' "/proc/$$/status" 2>/dev/null | sed 's/^/[sandbox:self-status-before] /' >&2 # 仅调试用
# 仅调试用: Session process info via /proc/PID/stat — the old ps -o probe
# used pid,ppid,pgid,sid,tpgid,stat,comm,args which Android toybox doesn't
# support, dumping 100+ lines of help text instead of process data.
for _sb_p in $$ $PPID; do awk '{printf("[sandbox:session-before] pid=%s comm=%s state=%s ppid=%s pgrp=%s sid=%s tty=%s tpgid=%s\n", $1, $2, $3, $4, $5, $6, $7, $8)}' "/proc/$_sb_p/stat" 2>/dev/null >&2; done # 仅调试用
cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null | sed 's/^/[sandbox:ptrace_scope] /' >&2 || echo "[sandbox:ptrace_scope=<unavailable>]" >&2 # 仅调试用
grep -E '^(Seccomp|NoNewPrivs):' "/proc/$$/status" 2>/dev/null | sed 's/^/[sandbox:seccomp] /' >&2 || echo "[sandbox:seccomp=<unavailable>]" >&2 # 仅调试用
# 仅调试用: Keep signal 54 ignored across fork+exec while the exit-182 investigation
# continues. Fresh logs show failing proot already has SigIgn 7fffffffffc0f053 before
# exit 182, so this trap is no longer treated as proof of root cause; the new logs below
# are meant to distinguish "proot itself got 54" from "proot returned a tracee status 182".
trap '' 54 # 仅调试用
printf '[sandbox:sig54-pre-ignored]\n' >&2 # 仅调试用
# 仅调试用: Start proot asynchronously and sample /proc/$proot_pid before a fast
# signal-54 death erases the child/tracer state. The failing window has no
# [alpine:L1], so the missing fact is whether proot ever spawns /bin/sh at all.
$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@" & # 仅调试用
proot_pid=$! # 仅调试用
printf '[sandbox:proot-pid=%s]\n' "$proot_pid" >&2 # 仅调试用
# 仅调试用: Immediate proot status capture — race to read /proc before signal 54
# kills proot (observed death within first 50ms probe in session 5).
awk '/^(Name|State|Tgid|Pid|PPid|TracerPid|Sig(Q|Pnd|Blk|Ign|Cgt)):/' "/proc/$proot_pid/status" 2>/dev/null | sed "s/^/[sandbox:proot-immediate] /" >&2 || printf '[sandbox:proot-immediate=<gone>]\n' >&2 # 仅调试用
for _sb_p in $$ $PPID $proot_pid; do awk '{printf("[sandbox:session-with-proot] pid=%s comm=%s state=%s ppid=%s pgrp=%s sid=%s tty=%s tpgid=%s\n", $1, $2, $3, $4, $5, $6, $7, $8)}' "/proc/$_sb_p/stat" 2>/dev/null >&2; done # 仅调试用
probe_round=1 # 仅调试用
while [ "$probe_round" -le 5 ]; do # 仅调试用
    if [ ! -d "/proc/$proot_pid" ]; then # 仅调试用
        printf '[sandbox:proot-proc-missing#%s]\n' "$probe_round" >&2 # 仅调试用
        # 仅调试用: Check if dead proot is a zombie (still reapable) or fully gone.
        # kill -0 succeeds for zombies; /proc/PID/status may still be readable.
        if kill -0 "$proot_pid" 2>/dev/null; then # 仅调试用
            printf '[sandbox:proot-zombie=%s]\n' "$proot_pid" >&2 # 仅调试用
            awk '/^(Name|State|SigPnd|ShdPnd|SigIgn):/' "/proc/$proot_pid/status" 2>/dev/null | sed "s/^/[sandbox:proot-zombie-status] /" >&2 # 仅调试用
        else # 仅调试用
            printf '[sandbox:proot-fully-gone=%s]\n' "$proot_pid" >&2 # 仅调试用
        fi # 仅调试用
        break # 仅调试用
    fi
    awk '/^(Name|State|Tgid|Pid|PPid|TracerPid|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt):/ {print}' "/proc/$proot_pid/status" 2>/dev/null | sed "s/^/[sandbox:proot-status#$probe_round] /" >&2 # 仅调试用
    awk -v round="$probe_round" '{printf("[sandbox:proot-stat#%s] pid=%s state=%s ppid=%s pgrp=%s session=%s tty_nr=%s tpgid=%s flags=%s\\n", round, $1, $3, $4, $5, $6, $7, $8, $9)}' "/proc/$proot_pid/stat" 2>/dev/null >&2 # 仅调试用
    _sandbox_proot_cmdline=$(tr '\0' ' ' < "/proc/$proot_pid/cmdline" 2>/dev/null) # 仅调试用
    if [ -n "$_sandbox_proot_cmdline" ]; then printf '[sandbox:proot-cmdline#%s] %s\n' "$probe_round" "$_sandbox_proot_cmdline" >&2; else printf '[sandbox:proot-cmdline#%s=<empty>]\n' "$probe_round" >&2; fi # 仅调试用
    _sandbox_proot_tasks=$(ls "/proc/$proot_pid/task" 2>/dev/null | tr '\n' ' ') # 仅调试用
    if [ -n "$_sandbox_proot_tasks" ]; then printf '[sandbox:proot-tasks#%s=%s]\n' "$probe_round" "$_sandbox_proot_tasks" >&2; else printf '[sandbox:proot-tasks#%s=<none>]\n' "$probe_round" >&2; fi # 仅调试用
    _sandbox_proot_wchan=$(cat "/proc/$proot_pid/wchan" 2>/dev/null) # 仅调试用
    if [ -n "$_sandbox_proot_wchan" ]; then printf '[sandbox:proot-wchan#%s=%s]\n' "$probe_round" "$_sandbox_proot_wchan" >&2; else printf '[sandbox:proot-wchan#%s=<empty>]\n' "$probe_round" >&2; fi # 仅调试用
    _sandbox_children=$(cat "/proc/$proot_pid/task/$proot_pid/children" 2>/dev/null) # 仅调试用
    if [ -n "$_sandbox_children" ]; then # 仅调试用
        printf '[sandbox:proot-children#%s=%s]\n' "$probe_round" "$_sandbox_children" >&2 # 仅调试用
        for _sandbox_child in $_sandbox_children; do # 仅调试用
            if [ ! -d "/proc/$_sandbox_child" ]; then # 仅调试用
                printf '[sandbox:child-missing#%s=%s]\n' "$probe_round" "$_sandbox_child" >&2 # 仅调试用
                continue # 仅调试用
            fi
            awk '/^(Name|State|Tgid|Pid|PPid|TracerPid|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt):/ {print}' "/proc/$_sandbox_child/status" 2>/dev/null | sed "s/^/[sandbox:child-status#$probe_round:$_sandbox_child] /" >&2 # 仅调试用
            _sandbox_child_cmdline=$(tr '\0' ' ' < "/proc/$_sandbox_child/cmdline" 2>/dev/null) # 仅调试用
            if [ -n "$_sandbox_child_cmdline" ]; then printf '[sandbox:child-cmdline#%s:%s] %s\n' "$probe_round" "$_sandbox_child" "$_sandbox_child_cmdline" >&2; else printf '[sandbox:child-cmdline#%s:%s=<empty>]\n' "$probe_round" "$_sandbox_child" >&2; fi # 仅调试用
        done
    else
        printf '[sandbox:proot-children#%s=<none>]\n' "$probe_round" >&2 # 仅调试用
    fi
    probe_round=$((probe_round + 1)) # 仅调试用
    sleep 0.05 # 仅调试用
done
wait "$proot_pid" # 仅调试用
proot_rc=$? # 仅调试用
printf '[sandbox:proot-rc=%s,installing=%s,args=%s]\n' "$proot_rc" "$1" "$*" >&2 # 仅调试用
# 仅调试用: signal analysis — exit codes > 128 indicate the child was killed by
# signal (exit_code - 128). 182 - 128 = 54, which is SIGRTMIN+20 on Linux.
# If [alpine:L1] is ABSENT, /bin/sh did not reach script entry. With current evidence,
# that alone no longer proves proot itself died before installing SigIgn; correlate it
# with [sandbox:proot-stat], [sandbox:proot-wchan], and [sandbox:child-status] first.
if [ "$proot_rc" -ne 0 ]; then
    if [ "$proot_rc" -gt 128 ]; then
        printf '[sandbox:signal=%s,code=128+%s]\n' "$((proot_rc - 128))" "$((proot_rc - 128))" >&2
    fi
    awk '/^Sig(Q|Pnd|Blk|Ign|Cgt):/ {print}' "/proc/$$/status" 2>/dev/null | sed 's/^/[sandbox:self-status-after] /' >&2 # 仅调试用
    for _sb_p in $$ $PPID; do awk '{printf("[sandbox:session-after] pid=%s comm=%s state=%s ppid=%s pgrp=%s sid=%s tty=%s tpgid=%s\n", $1, $2, $3, $4, $5, $6, $7, $8)}' "/proc/$_sb_p/stat" 2>/dev/null >&2; done # 仅调试用
    stat "$PROOT" "$PREFIX/init-alpine.sh" /bin/sh 2>&1 | sed 's/^/[sandbox:stat] /' >&2
    # Check if libtalloc symlink is valid — broken symlink would prevent proot from loading
    ls -lL "$PREFIX/libtalloc.so.2" 2>&1 | sed 's/^/[sandbox:libtalloc] /' >&2
    # 仅调试用: Post-failure PROOT_TMP_DIR snapshot — compare with pre-launch [sandbox:tmpdir]
    # to detect if proot created then abandoned tracking files during the failed launch.
    ls -la "$PROOT_TMP_DIR" 2>&1 | sed 's/^/[sandbox:tmpdir-after] /' >&2 # 仅调试用
    # 仅调试用: Check if any new proot/axs processes appeared or if old ones are still around
    # BUG FIX: same sed-always-returns-0 pattern as pre-launch ps probe; use variable capture.
    _sandbox_ps_after=$(ps -e -o pid,ppid,comm 2>/dev/null | grep -E 'proot|axs|init-alpine|init-sandbox' | grep -v grep) # 仅调试用
    if [ -n "$_sandbox_ps_after" ]; then echo "$_sandbox_ps_after" | sed 's/^/[sandbox:ps-after] /' >&2; else echo "[sandbox:ps-after=<none>]" >&2; fi # 仅调试用
fi
exit "$proot_rc"
