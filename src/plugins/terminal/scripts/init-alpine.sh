echo "DEBUG-ALPINE: script started, args=$@"
set -x

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin:/system/bin:/system/xbin:$PREFIX/local/bin
export PS1="\[\e[38;5;46m\]\u\[\033[39m\]@localhost \[\033[39m\]\w \[\033[0m\]\\$ "
export HOME=/home
export TERM=xterm-256color

# === PTY diagnostics (INSIDE proot) ===
echo "DEBUG-PTY-INSIDE: === PTY diagnostic (inside proot) ==="
echo "DEBUG-PTY-INSIDE: kernel: $(uname -r 2>&1)"
echo "DEBUG-PTY-INSIDE: /dev/ptmx exists: $(test -e /dev/ptmx && echo YES || echo NO)"
echo "DEBUG-PTY-INSIDE: /dev/ptmx stat: $(ls -la /dev/ptmx 2>&1)"
echo "DEBUG-PTY-INSIDE: /dev/pts exists: $(test -e /dev/pts && echo YES || echo NO)"
echo "DEBUG-PTY-INSIDE: /dev/pts stat: $(ls -lad /dev/pts 2>&1)"
echo "DEBUG-PTY-INSIDE: /dev/pts contents: $(ls -la /dev/pts/ 2>&1)"
echo "DEBUG-PTY-INSIDE: /dev/pts/ptmx stat: $(ls -la /dev/pts/ptmx 2>&1)"
echo "DEBUG-PTY-INSIDE: /dev/pt*: $(ls -la /dev/pt* 2>&1)"
echo "DEBUG-PTY-INSIDE: /proc/mounts devpts: $(grep devpts /proc/mounts 2>&1 || echo 'NOT MOUNTED')"
echo "DEBUG-PTY-INSIDE: /proc/filesystems: $(grep pts /proc/filesystems 2>&1 || echo 'not found')"
echo "DEBUG-PTY-INSIDE: id: $(id 2>&1)"
echo "DEBUG-PTY-INSIDE: SELinux: $(cat /proc/self/attr/current 2>&1)"

# Test 1: Actually open /dev/ptmx from shell
if exec 3<>/dev/ptmx 2>/dev/null; then
    echo "DEBUG-PTY-INSIDE: open(/dev/ptmx) = SUCCESS"
    echo "DEBUG-PTY-INSIDE: /proc/self/fd/3: $(ls -la /proc/self/fd/3 2>&1)"
    echo "DEBUG-PTY-INSIDE: fdinfo/3: $(cat /proc/self/fdinfo/3 2>&1)"
    # Check if slave appeared in /dev/pts/
    echo "DEBUG-PTY-INSIDE: /dev/pts/ after open: $(ls -la /dev/pts/ 2>&1)"
    exec 3>&- 2>/dev/null
else
    echo "DEBUG-PTY-INSIDE: open(/dev/ptmx) = FAILED"
    echo "DEBUG-PTY-INSIDE: open error: $(exec 3<>/dev/ptmx 2>&1)"
fi

# Test 2: Compile and run a C program that tests openpty() and TIOCGPTPEER
if command -v gcc >/dev/null 2>&1; then
    echo "DEBUG-PTY-INSIDE: gcc available, compiling PTY test..."
    cat > /tmp/pty_test.c << 'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>

/* TIOCGPTPEER: get slave fd directly from master fd (Linux 4.13+) */
#ifndef TIOCGPTPEER
#define TIOCGPTPEER _IO('T', 0x41)
#endif

int main() {
    int master_fd, slave_fd, ret;
    char slave_name[256];

    printf("=== PTY C Test ===\n");

    /* Test 1: open /dev/ptmx */
    master_fd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (master_fd < 0) {
        printf("TEST1 open(/dev/ptmx): FAIL errno=%d (%s)\n", errno, strerror(errno));
        /* Try /dev/pts/ptmx as alternative */
        master_fd = open("/dev/pts/ptmx", O_RDWR | O_NOCTTY);
        if (master_fd < 0) {
            printf("TEST1 open(/dev/pts/ptmx): FAIL errno=%d (%s)\n", errno, strerror(errno));
            printf("=== No PTY master available, all tests skipped ===\n");
            return 1;
        }
        printf("TEST1 open(/dev/pts/ptmx): OK fd=%d\n", master_fd);
    } else {
        printf("TEST1 open(/dev/ptmx): OK fd=%d\n", master_fd);
    }

    /* Test 2: grantpt + unlockpt */
    ret = grantpt(master_fd);
    printf("TEST2 grantpt: %s errno=%d (%s)\n", ret==0?"OK":"FAIL", errno, ret?strerror(errno):"none");

    ret = unlockpt(master_fd);
    printf("TEST3 unlockpt: %s errno=%d (%s)\n", ret==0?"OK":"FAIL", errno, ret?strerror(errno):"none");

    /* Test 3: ptsname - get slave path */
    char *name = ptsname(master_fd);
    if (name) {
        printf("TEST4 ptsname: OK -> %s\n", name);
        strncpy(slave_name, name, sizeof(slave_name)-1);

        /* Test 4: open slave via path */
        slave_fd = open(slave_name, O_RDWR | O_NOCTTY);
        if (slave_fd >= 0) {
            printf("TEST5 open(slave_path): OK fd=%d\n", slave_fd);
            close(slave_fd);
        } else {
            printf("TEST5 open(slave_path=%s): FAIL errno=%d (%s)\n", slave_name, errno, strerror(errno));
        }
    } else {
        printf("TEST4 ptsname: FAIL errno=%d (%s)\n", errno, strerror(errno));
    }

    /* Test 5: TIOCGPTPEER ioctl (Linux 4.13+) */
    /* This gets the slave fd directly without needing /dev/pts/ access */
    errno = 0;
    slave_fd = ioctl(master_fd, TIOCGPTPEER, O_RDWR | O_NOCTTY);
    if (slave_fd >= 0) {
        printf("TEST6 TIOCGPTPEER: OK fd=%d  *** THIS BYPASSES /dev/pts ***\n", slave_fd);
        close(slave_fd);
    } else {
        printf("TEST6 TIOCGPTPEER: FAIL errno=%d (%s)\n", errno, strerror(errno));
    }

    /* Test 6: openpty() - the function AXS actually uses */
    /* Need pty.h */
    close(master_fd);

    printf("=== End PTY C Test ===\n");
    return 0;
}
CEOF
    gcc -o /tmp/pty_test /tmp/pty_test.c 2>&1
    if [ -f /tmp/pty_test ]; then
        echo "DEBUG-PTY-INSIDE: C test compiled, running..."
        /tmp/pty_test 2>&1 | while IFS= read -r line; do
            echo "DEBUG-PTY-INSIDE: [C] $line"
        done
        rm -f /tmp/pty_test /tmp/pty_test.c
    else
        echo "DEBUG-PTY-INSIDE: C test compile FAILED"
    fi
else
    echo "DEBUG-PTY-INSIDE: gcc not available, trying to install..."
    apk add --no-scripts gcc musl-dev 2>/dev/null
    if command -v gcc >/dev/null 2>&1; then
        echo "DEBUG-PTY-INSIDE: gcc installed, will test on next run"
    else
        echo "DEBUG-PTY-INSIDE: cannot install gcc, skipping C test"
    fi
fi

echo "DEBUG-PTY-INSIDE: === end PTY diagnostic ==="


if [ ! -f /linkerconfig/ld.config.txt ]; then
    mkdir -p /linkerconfig
    touch /linkerconfig/ld.config.txt
fi


if [ "$1" = "--installing" ]; then
    # ── Package installation (only during install/repair) ──
    required_packages="bash command-not-found tzdata wget gcc musl-dev"
    missing_packages=""

    # Check by file existence rather than apk info (which is unreliable in proot)
    [ ! -f /usr/bin/bash ] && [ ! -f /bin/bash ] && missing_packages="$missing_packages bash"
    [ ! -f /usr/bin/command-not-found ] && missing_packages="$missing_packages command-not-found"
    [ ! -f /usr/share/zoneinfo/UTC ] && missing_packages="$missing_packages tzdata"
    [ ! -f /usr/bin/wget ] && missing_packages="$missing_packages wget"
    [ ! -f /usr/bin/gcc ] && missing_packages="$missing_packages gcc"
    [ ! -f /usr/include/stdlib.h ] && missing_packages="$missing_packages musl-dev"

    PACKAGES_OK=true
    if [ -n "$missing_packages" ]; then
        echo -e "\e[34;1m[*] \e[0mInstalling packages:$missing_packages\e[0m"

        # In proot, post-install scripts always fail with error 127 (command not found).
        # Use --no-scripts to avoid spurious errors, then do manual config.
        apk update 2>/dev/null

        apk add --no-scripts $missing_packages 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mRetrying with mirror...\e[0m"
            cp /etc/apk/repositories /etc/apk/repositories.bak
            echo "https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main" > /etc/apk/repositories
            echo "https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/community" >> /etc/apk/repositories
            apk update 2>/dev/null
            apk add --no-scripts $missing_packages 2>/dev/null
            mv /etc/apk/repositories.bak /etc/apk/repositories 2>/dev/null
        fi

        # Manual post-install: ensure bash is usable
        if [ -f /usr/bin/bash ] && [ ! -e /bin/bash ]; then
            ln -sf /usr/bin/bash /bin/bash 2>/dev/null
        fi
        # Ensure /etc/shells has bash
        if [ -f /usr/bin/bash ] && ! grep -q "/bin/bash" /etc/shells 2>/dev/null; then
            echo "/bin/bash" >> /etc/shells 2>/dev/null
        fi

        # Verify by file existence
        [ ! -f /usr/bin/bash ] && [ ! -f /bin/bash ] && echo -e "\e[31;1m[!] \e[0mbash still missing\e[0m" && PACKAGES_OK=false
        [ ! -f /usr/bin/wget ] && echo -e "\e[31;1m[!] \e[0mwget still missing\e[0m" && PACKAGES_OK=false

        if [ "$PACKAGES_OK" = true ]; then
            echo -e "\e[34m[*] \e[0mUse \e[32mapk\e[0m to install new packages\e[0m"
        else
            echo -e "\e[31;1m[!] \e[0mSome packages failed to install\e[0m"
        fi
    else
        PACKAGES_OK=true
        echo -e "\e[34m[*] \e[0mAll packages already installed\e[0m"
    fi

    echo "Configuring timezone..."
    
    if [ -n "$ANDROID_TZ" ] && [ -f "/usr/share/zoneinfo/$ANDROID_TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$ANDROID_TZ" /etc/localtime
        echo "$ANDROID_TZ" > /etc/timezone
        echo "Timezone set to: $ANDROID_TZ"
    else
        echo "Failed to detect timezone"
    fi

    # .configured marker is created by JS layer (system.writeText) after proot exits.
    # Do NOT create it here — proot bind-mount mkdir causes Java mkdirs() to fail
    # because it sees the directory already exists.
    #
    # If packages failed, user can manually run: apk update && apk add bash
    if [ "$PACKAGES_OK" = true ]; then
        echo "Installation completed."
    else
        echo "Some packages failed to install (network issue?)."
        echo "Terminal will use /bin/sh. To install bash later, run:"
        echo "  apk update && apk add bash wget"
    fi
    exit 0
fi


if [ "$1" = "--setup-only" ] || [ "$#" -eq 0 ]; then
    echo "$$" > "$PREFIX/pid"
    chmod +x "$PREFIX/axs"

    if [ ! -e "$PREFIX/alpine/etc/acode_motd" ]; then
        cat <<EOF > "$PREFIX/alpine/etc/acode_motd"
Welcome to Alpine Linux in Acode!

Working with packages:

 - Search:  apk search <query>
 - Install: apk add <package>
 - Uninstall: apk del <package>
 - Upgrade: apk update && apk upgrade

EOF
    fi

    # Create acode CLI tool
    if [ ! -e "$PREFIX/alpine/usr/local/bin/acode" ]; then
        mkdir -p "$PREFIX/alpine/usr/local/bin"
        cat <<'ACODE_CLI' > "$PREFIX/alpine/usr/local/bin/acode"
#!/bin/bash
# acode - Open files/folders in Acode editor
# Uses OSC escape sequences to communicate with the Acode terminal

usage() {
    echo "Usage: acode [file/folder...]"
    echo ""
    echo "Open files or folders in Acode editor."
    echo ""
    echo "Examples:"
    echo "  acode file.txt      # Open a file"
    echo "  acode .             # Open current folder"
    echo "  acode ~/project     # Open a folder"
    echo "  acode -h, --help    # Show this help"
}

get_abs_path() {
    local path="$1"
    local abs_path=""

    if command -v realpath >/dev/null 2>&1; then
        abs_path=$(realpath -- "$path" 2>/dev/null)
    fi

    if [[ -z "$abs_path" ]]; then
        if [[ -d "$path" ]]; then
            abs_path=$(cd -- "$path" 2>/dev/null && pwd -P)
        elif [[ -e "$path" ]]; then
            local dir_name file_name
            dir_name=$(dirname -- "$path")
            file_name=$(basename -- "$path")
            abs_path="$(cd -- "$dir_name" 2>/dev/null && pwd -P)/$file_name"
        elif [[ "$path" == /* ]]; then
            abs_path="$path"
        else
            abs_path="$PWD/$path"
        fi
    fi

    echo "$abs_path"
}

open_in_acode() {
    local path=$(get_abs_path "$1")
    local type="file"
    [[ -d "$path" ]] && type="folder"
    
    # Send OSC 7777 escape sequence: \e]7777;cmd;type;path\a
    # The terminal component will intercept and handle this
    printf '\e]7777;open;%s;%s\a' "$type" "$path"
}

if [[ $# -eq 0 ]]; then
    open_in_acode "."
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -e "$arg" ]]; then
                open_in_acode "$arg"
            else
                echo "Error: '$arg' does not exist" >&2
                exit 1
            fi
            ;;
    esac
done
ACODE_CLI
        chmod +x "$PREFIX/alpine/usr/local/bin/acode"
    fi

    # Create initrc if it doesn't exist
    #initrc runs in bash so we can use bash features 
if [ ! -e "$PREFIX/alpine/initrc" ]; then
    cat <<'EOF' > "$PREFIX/alpine/initrc"
# Source rc files if they exist

if [ -f "/etc/profile" ]; then
    source "/etc/profile"
fi

# Environment setup
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin

export HOME=/home 
export TERM=xterm-256color 
SHELL=/bin/bash
export PIP_BREAK_SYSTEM_PACKAGES=1

# Default prompt with fish-style path shortening (~/p/s/components)
# To use custom prompts (Starship, Oh My Posh, etc.), just init them in ~/.bashrc:
#   eval "$(starship init bash)"
_shorten_path() {
    local path="$PWD"
    
    if [[ "$HOME" != "/" && "$path" == "$HOME" ]]; then
        echo "~"
        return
    elif [[ "$HOME" != "/" && "$path" == "$HOME/"* ]]; then
        path="~${path#$HOME}"
    fi
    
    [[ "$path" == "~" ]] && echo "~" && return
    
    local parts result=""
    IFS='/' read -ra parts <<< "$path"
    local len=${#parts[@]}
    
    for ((i=0; i<len; i++)); do
        [[ -z "${parts[i]}" ]] && continue
        if [[ $i -lt $((len-1)) ]]; then
            result+="${parts[i]:0:1}/"
        else
            result+="${parts[i]}"
        fi
    done
    
    [[ "$path" == /* ]] && echo "/$result" || echo "$result"
}

PROMPT_COMMAND='_PS1_PATH=$(_shorten_path); _PS1_EXIT=$?'

# Source user configs AFTER defaults (so user can override PROMPT_COMMAND)
if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
fi

if [ -f /etc/bash/bashrc ]; then
    source /etc/bash/bashrc
fi


# Display MOTD if available
if [ -s /etc/acode_motd ]; then
    cat /etc/acode_motd
fi

# Command-not-found handler
command_not_found_handle() {
    cmd="$1"
    pkg=""
    green="\e[1;32m"
    reset="\e[0m"

    pkg=$(apk search -x "cmd:$cmd" 2>/dev/null | awk -F'-[0-9]' '{print $1}' | head -n 1)

    if [ -n "$pkg" ]; then
        echo -e "The program '$cmd' is not installed.\nInstall it by executing:\n ${green}apk add $pkg${reset}" >&2
    else
        echo "The program '$cmd' is not installed and no package provides it." >&2
    fi

    return 127
}

EOF
fi

# Add PS1 only if not already present
if ! grep -q 'PS1=' "$PREFIX/alpine/initrc"; then
    # Smart path shortening (fish-style: ~/p/s/components)
    echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\$_PS1_PATH\[\033[0m\] \[\$([ \$_PS1_EXIT -ne 0 ] && echo \"\033[31m\")\]\$\[\033[0m\] "' >> "$PREFIX/alpine/initrc"
    # Simple prompt (uncomment below and comment above if you prefer full paths)
    # echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\w\[\033[0m\] \$ "' >> "$PREFIX/alpine/initrc"
fi

chmod +x "$PREFIX/alpine/initrc"

# --setup-only: exit before starting AXS (caller will start it outside proot)
if [ "$1" = "--setup-only" ]; then
    echo "DEBUG-ALPINE: setup-only complete, AXS will start outside proot"
    # Log available network interfaces for diagnostics
    echo "DEBUG-ALPINE: ip addr inside proot:"
    ip addr 2>/dev/null || echo "(ip command not available)"
    exit 0
fi

#actual source
#everytime a terminal is started initrc will run
if command -v bash >/dev/null 2>&1; then
    "$PREFIX/axs" --ip --allow-any-origin -c "bash --rcfile /initrc -i"
else
    # bash not installed, fall back to sh
    "$PREFIX/axs" --ip --allow-any-origin -c "sh -l"
fi

else
    exec "$@"
fi
