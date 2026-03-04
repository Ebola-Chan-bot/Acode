export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin:/system/bin:/system/xbin:$PREFIX/local/bin
export HOME=/home
export TERM=xterm-256color

if [ ! -f /linkerconfig/ld.config.txt ]; then
    mkdir -p /linkerconfig
    touch /linkerconfig/ld.config.txt
fi


if [ "$1" = "--installing" ]; then
    # ── Package installation (only during install/repair) ──
    required_packages="bash command-not-found tzdata wget"
    missing_packages=""

    # Check by file existence rather than apk info (which is unreliable in proot)
    [ ! -f /usr/bin/bash ] && [ ! -f /bin/bash ] && missing_packages="$missing_packages bash"
    [ ! -f /usr/bin/command-not-found ] && missing_packages="$missing_packages command-not-found"
    [ ! -f /usr/share/zoneinfo/UTC ] && missing_packages="$missing_packages tzdata"
    [ ! -f /usr/bin/wget ] && missing_packages="$missing_packages wget"

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

    # Create /etc/profile.d/acode.sh — sourced by ALL login shells (ash + bash)
    # This ensures MOTD and a sane PS1 even when bash is not installed.
    mkdir -p "$PREFIX/alpine/etc/profile.d"
    cat <<'PROFILE' > "$PREFIX/alpine/etc/profile.d/acode.sh"
# Acode terminal profile (works in ash and bash)
export HOME=/home
export TERM=xterm-256color
export PIP_BREAK_SYSTEM_PACKAGES=1

# MOTD is displayed by initrc (bash) or here for ash-only fallback
if [ -z "$BASH_VERSION" ] && [ -s /etc/acode_motd ]; then
    cat /etc/acode_motd
fi

# Simple PS1 compatible with ash (no \[...\] readline markers)
# ash supports \u \h \w \$ natively
PS1='\u@localhost:\w\$ '
export PS1
PROFILE
    chmod +x "$PREFIX/alpine/etc/profile.d/acode.sh"

    # Create/update initrc (always overwrite to keep in sync with app updates)
    #initrc runs in bash so we can use bash features 
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

# Display MOTD (only source that reliably runs in proot bash)
if [ -s /etc/acode_motd ]; then
    cat /etc/acode_motd
fi

# acode CLI function (defined here to avoid proot shebang issues)
_acode_get_abs_path() {
    local path="$1" abs_path=""
    if command -v realpath >/dev/null 2>&1; then
        abs_path=$(realpath -- "$path" 2>/dev/null)
    fi
    if [[ -z "$abs_path" ]]; then
        if [[ -d "$path" ]]; then
            abs_path=$(cd -- "$path" 2>/dev/null && pwd -P)
        elif [[ -e "$path" ]]; then
            abs_path="$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P)/$(basename -- "$path")"
        elif [[ "$path" == /* ]]; then
            abs_path="$path"
        else
            abs_path="$PWD/$path"
        fi
    fi
    echo "$abs_path"
}
_acode_open() {
    local path=$(_acode_get_abs_path "$1")
    local type="file"
    [[ -d "$path" ]] && type="folder"
    printf '\e]7777;open;%s;%s\a' "$type" "$path"
}
acode() {
    if [[ $# -eq 0 ]]; then
        _acode_open "."
        return 0
    fi
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                echo "Usage: acode [file/folder...]"
                echo ""
                echo "Open files or folders in Acode editor."
                echo ""
                echo "Examples:"
                echo "  acode file.txt      # Open a file"
                echo "  acode .             # Open current folder"
                echo "  acode ~/project     # Open a folder"
                echo "  acode -h, --help    # Show this help"
                return 0
                ;;
            *)
                if [[ -e "$arg" ]]; then
                    _acode_open "$arg"
                else
                    echo "Error: '$arg' does not exist" >&2
                    return 1
                fi
                ;;
        esac
    done
}

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

# Add PS1 only if not already present
if ! grep -q 'PS1=' "$PREFIX/alpine/initrc"; then
    # Smart path shortening (fish-style: ~/p/s/components)
    echo 'PS1="\[\e[1;32m\]\u\[\e[0m\]@localhost \[\e[1;34m\]\$_PS1_PATH\[\e[0m\] \$ "' >> "$PREFIX/alpine/initrc"
fi

chmod +x "$PREFIX/alpine/initrc"

# --setup-only: exit before starting AXS (caller will start it outside proot)
if [ "$1" = "--setup-only" ]; then
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
