export LD_LIBRARY_PATH=$PREFIX

mkdir -p "$PREFIX/tmp"
mkdir -p "$PREFIX/alpine/tmp"
mkdir -p "$PREFIX/public"

export PROOT_TMP_DIR=$PREFIX/tmp

# Disable seccomp filter in proot to avoid SIGSEGV/SIGBUS on kernels
# with strict seccomp policies (e.g. Huawei/HarmonyOS, Samsung Knox)
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

if [ -e "/proc/self/fd/0" ]; then
  ARGS="$ARGS -b /proc/self/fd/0:/dev/stdin"
fi

if [ -e "/proc/self/fd/1" ]; then
  ARGS="$ARGS -b /proc/self/fd/1:/dev/stdout"
fi

if [ -e "/proc/self/fd/2" ]; then
  ARGS="$ARGS -b /proc/self/fd/2:/dev/stderr"
fi


ARGS="$ARGS -r $PREFIX/alpine"
ARGS="$ARGS -0"
ARGS="$ARGS --link2symlink"
# --sysvipc removed: SysV IPC emulation causes Bus Error on some Android kernels
ARGS="$ARGS -L"

echo "DEBUG-SANDBOX: PROOT=$PROOT"
echo "DEBUG-SANDBOX: PREFIX=$PREFIX"
echo "DEBUG-SANDBOX: init-alpine.sh=$(ls -la $PREFIX/init-alpine.sh 2>&1)"
echo "DEBUG-SANDBOX: /bin/sh in rootfs=$(ls -la $PREFIX/alpine/bin/sh 2>&1)"
echo "DEBUG-SANDBOX: busybox=$(ls -la $PREFIX/alpine/bin/busybox 2>&1)"
echo "DEBUG-SANDBOX: running proot with args: $ARGS"

# === PTY diagnostics (OUTSIDE proot, Android/卓易通 layer) ===
echo "DEBUG-PTY-OUTSIDE: === PTY diagnostic (outside proot) ==="
echo "DEBUG-PTY-OUTSIDE: /dev/ptmx exists: $(test -e /dev/ptmx && echo YES || echo NO)"
echo "DEBUG-PTY-OUTSIDE: /dev/ptmx stat: $(ls -la /dev/ptmx 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/pts exists: $(test -e /dev/pts && echo YES || echo NO)"
echo "DEBUG-PTY-OUTSIDE: /dev/pts stat: $(ls -lad /dev/pts 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/pts contents: $(ls -la /dev/pts/ 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/pts/ptmx stat: $(ls -la /dev/pts/ptmx 2>&1)"

# Test 1: Actually try to OPEN /dev/ptmx (not just ls it)
if exec 3<>/dev/ptmx 2>/dev/null; then
    echo "DEBUG-PTY-OUTSIDE: open(/dev/ptmx) = SUCCESS (fd 3)"
    # If open succeeded, check what the kernel says about slave
    echo "DEBUG-PTY-OUTSIDE: /proc/self/fd/3: $(ls -la /proc/self/fd/3 2>&1)"
    echo "DEBUG-PTY-OUTSIDE: ptsname via /proc: $(cat /proc/self/fdinfo/3 2>&1)"
    # Try to find the slave number
    PTY_SLAVE=$(cat /proc/self/fdinfo/3 2>&1 | grep -o 'tty-index:.*' || echo 'unknown')
    echo "DEBUG-PTY-OUTSIDE: slave index: $PTY_SLAVE"
    # Close fd
    exec 3>&- 2>/dev/null
else
    echo "DEBUG-PTY-OUTSIDE: open(/dev/ptmx) = FAILED: $(exec 3<>/dev/ptmx 2>&1)"
fi

# Test 2: /proc/mounts to see if devpts is mounted
echo "DEBUG-PTY-OUTSIDE: /proc/mounts devpts: $(grep devpts /proc/mounts 2>&1 || echo 'NOT MOUNTED')"
echo "DEBUG-PTY-OUTSIDE: /proc/filesystems pts: $(grep pts /proc/filesystems 2>&1 || echo 'not found')"
echo "DEBUG-PTY-OUTSIDE: mount | pts: $(mount 2>&1 | grep -i pts || echo 'not found')"

# Test 3: /dev listing for anything PTY-related
echo "DEBUG-PTY-OUTSIDE: /dev/pt*: $(ls -la /dev/pt* 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/tty*: $(ls -la /dev/tty /dev/tty0 /dev/ttyS0 2>&1)"

# Test 4: Process identity and security context
echo "DEBUG-PTY-OUTSIDE: id: $(id 2>&1)"
echo "DEBUG-PTY-OUTSIDE: getenforce: $(getenforce 2>&1)"
echo "DEBUG-PTY-OUTSIDE: SELinux context: $(cat /proc/self/attr/current 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/ptmx context: $(ls -laZ /dev/ptmx 2>&1)"
echo "DEBUG-PTY-OUTSIDE: /dev/pts context: $(ls -ladZ /dev/pts 2>&1)"

# Test 5: Run pre-compiled PTY test binary outside proot
PTY_TEST_OUT=""
for p in /sdcard/Download/pty_test /storage/emulated/0/Download/pty_test /storage/media/100/local/files/Docs/Download/pty_test; do
    if [ -f "$p" ]; then
        PTY_TEST_OUT="$p"
        break
    fi
done
if [ -n "$PTY_TEST_OUT" ]; then
    echo "DEBUG-PTY-OUTSIDE: found pre-compiled test at $PTY_TEST_OUT"
    cp "$PTY_TEST_OUT" "$PREFIX/pty_test" 2>&1
    chmod 755 "$PREFIX/pty_test" 2>&1
    if [ -x "$PREFIX/pty_test" ]; then
        echo "DEBUG-PTY-OUTSIDE: running pre-compiled PTY test..."
        "$PREFIX/pty_test" 2>&1 | while IFS= read -r line; do
            echo "DEBUG-PTY-OUTSIDE: [C] $line"
        done
        rm -f "$PREFIX/pty_test"
    else
        echo "DEBUG-PTY-OUTSIDE: failed to make pty_test executable"
    fi
else
    echo "DEBUG-PTY-OUTSIDE: no pre-compiled pty_test found"
fi

echo "DEBUG-PTY-OUTSIDE: === end PTY diagnostic ==="

# --setup-only mode: run init-alpine.sh for setup, then RETURN to caller
# (instead of exit) so the caller can start AXS outside proot.
SETUP_ONLY=false
for _arg in "$@"; do
    [ "$_arg" = "--setup-only" ] && SETUP_ONLY=true
done

$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@"
PROOT_EXIT=$?
echo "DEBUG-SANDBOX: proot exited with code $PROOT_EXIT"

if [ "$SETUP_ONLY" = "true" ]; then
    # Return to caller shell — PROOT, ARGS, and all env vars remain set
    # so the caller can use them to start AXS outside proot.
    true
else
    exit $PROOT_EXIT
fi
