export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin:/system/bin:/system/xbin:$PREFIX/local/bin
export HOME=/home
export TERM=xterm-256color

APK_MAIN_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/main"
APK_COMMUNITY_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/community"
APK_MIRROR_MAIN_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/main"
APK_MIRROR_COMMUNITY_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/community"

run_apk_step() {
    local _step_label="$1"
    local _step_repo="$2"
    shift
    shift
    "$@"
    return $?
}

configure_apk_repositories() {
    local repo_mode="$1"

    if [ "$repo_mode" = "mirror" ]; then
        printf '%s\n%s\n' "$APK_MIRROR_MAIN_REPO" "$APK_MIRROR_COMMUNITY_REPO" > /etc/apk/repositories
    else
        printf '%s\n%s\n' "$APK_MAIN_REPO" "$APK_COMMUNITY_REPO" > /etc/apk/repositories
    fi
}


# ── Package check (runs every startup, file-stat only — negligible cost) ──
query_apk_installed() {
    local package_name="$1"

    [ -f /lib/apk/db/installed ] || return 2
    [ -e /lib/apk/db/lock ] && return 2
    grep -q "^P:${package_name}$" /lib/apk/db/installed
}

should_install_command_not_found() {
    query_apk_installed command-not-found

    case $? in
        0) return 1 ;;
        1) return 0 ;;
          *) [ ! -f /usr/libexec/command-not-found ] ;;
    esac
}

find_bash_path() {
    command -v bash 2>/dev/null || true
}

required_packages_ready() {
    local bash_path=""

    bash_path="$(find_bash_path)"
    [ -z "$bash_path" ] && return 1
    [ ! -f /usr/share/zoneinfo/UTC ] && return 1
    [ ! -f /usr/bin/wget ] && return 1
    should_install_command_not_found && return 1
    return 0
}

missing_packages=""
[ -z "$(find_bash_path)" ] && missing_packages="$missing_packages bash"
[ ! -f /usr/share/zoneinfo/UTC ] && missing_packages="$missing_packages tzdata"
[ ! -f /usr/bin/wget ] && missing_packages="$missing_packages wget"
should_install_command_not_found && missing_packages="$missing_packages command-not-found"

if [ -n "$missing_packages" ]; then
    echo -e "\e[34;1m[*] \e[0mInstalling packages:$missing_packages\e[0m"

    install_succeeded="false"
    for repo_mode in official mirror; do
        configure_apk_repositories "$repo_mode"

        # In proot, persisting APKINDEX may fail with Operation not permitted;
        # install directly without local index cache writes.
        run_apk_step "apk add required-packages" "$repo_mode" apk add --no-cache $missing_packages
        apk_add_rc=$?

        if [ "$apk_add_rc" -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk add failed with ${repo_mode} repositories\e[0m"
            # ── 仅调试用：本轮焦点 = proot 内置 EPERM 定位诊断（proot-diag: ... 行由 proot 源码注入）──
            echo "DIAG ENV: PROOT_NO_SECCOMP='${PROOT_NO_SECCOMP:-unset}' PROOT_VERBOSE='${PROOT_VERBOSE:-unset}'" # 仅调试用
            echo "DIAG rc=$apk_add_rc repo_mode=$repo_mode" # 仅调试用
            # ── 仅调试用：再跑一次 apk add 以触发 proot-diag 打印 EPERM 来源 ──
            echo "DIAG apk -v add retry (watch for proot-diag lines above/below):" # 仅调试用
            apk -v add --no-cache $missing_packages 2>&1 | tail -n 40 # 仅调试用
            echo "DIAG end" # 仅调试用
            continue
        fi

        install_succeeded="true"
        break
    done

    if [ "$install_succeeded" != "true" ]; then
        echo -e "\e[31;1m[!] \e[0mapk package installation failed with both official and mirror repositories\e[0m"
        exit 1
    fi
fi


if [ -d /linkerconfig ] && [ -w /linkerconfig ] && [ ! -f /linkerconfig/ld.config.txt ]; then
    touch /linkerconfig/ld.config.txt
fi


if [ "$1" = "--installing" ]; then
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
    echo "Installation completed."
    exit 0
fi


if [ "$#" -eq 0 ]; then
    echo "$$" > "$PREFIX/pid"
    chmod +x "$PREFIX/axs"

    if [ ! -s "$PREFIX/alpine/etc/acode_motd" ]; then
        cat <<EOF > "$PREFIX/alpine/etc/acode_motd"
Welcome to Alpine Linux in Acode!

Working with packages:

 - Search:  apk search <query>
 - Install: apk add <package>
 - Uninstall: apk del <package>
 - Upgrade: apk update && apk upgrade

EOF
    fi

    # Create/update initrc (always overwrite to keep in sync with app updates)
    # Cost: ~3KB heredoc write per startup, sub-millisecond — negligible.
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

_PS1_PATH="$(_shorten_path)"
_PS1_EXIT=0

_update_prompt_state() {
    local last_exit=$?
    _PS1_PATH="$(_shorten_path)"
    _PS1_EXIT=$last_exit
}

PROMPT_COMMAND='_update_prompt_state'

# Source user configs AFTER defaults (so user can override PROMPT_COMMAND)
if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
fi

if [ -f /etc/bash/bashrc ]; then
    source /etc/bash/bashrc
fi

# Display MOTD
if [ -s /etc/acode_motd ]; then
    cat /etc/acode_motd
fi

command_not_found_handle() {
    if [ -f /usr/libexec/command-not-found ]; then
        /usr/libexec/command-not-found "$@"
        return $?
    fi

    printf '%s: command not found\n' "$1" >&2
    return 127
}

EOF

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

# Add PS1 only if not already present
if ! grep -q 'PS1=' "$PREFIX/alpine/initrc"; then
    # Smart path shortening (fish-style: ~/p/s/components)
    echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\$_PS1_PATH\[\033[0m\] \[\$([ "${_PS1_EXIT:-0}" -ne 0 ] && echo \"\033[31m\")\]\$\[\033[0m\] "' >> "$PREFIX/alpine/initrc"
    # Simple prompt (uncomment below and comment above if you prefer full paths)
    # echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\w\[\033[0m\] \$ "' >> "$PREFIX/alpine/initrc"
fi
chmod +x "$PREFIX/alpine/initrc"

# Wait for AXS to signal readiness via a named pipe (FIFO).
# AXS writes "READY\n" to AXS_READY_PIPE after successful TCP bind.
# The shell's `read -t` blocks until that write arrives or times out.
# This replaces the old wget polling loop: zero HTTP requests, instant
# notification, and no hang when wget can't reach AXS inside proot.
wait_for_axs_ready() {
    local axs_pid="$1"
    local ready_pipe="$2"
    local ready_line=""


    # read -t 15: block up to 15 seconds for AXS to write "READY" to the FIFO.
    # If AXS dies before opening the pipe, the shell's read gets EOF immediately
    # (no other writers). If AXS hangs, the 15s timeout fires.
    read -t 15 ready_line < "$ready_pipe"
    _read_rc=$?

    if [ "$_read_rc" -eq 0 ] && [ "$ready_line" = "READY" ]; then
        echo "__ACODE_AXS_READY__"
        return 0
    fi

    return 1
}

# Stage axs binary inside the rootfs so it can be found by path within proot.
# A refreshed Alpine rootfs can legitimately miss /usr/local/bin until the first
# app-managed startup recreates it.
mkdir -p /usr/local/bin || exit 1
cp -f "$PREFIX/axs" /usr/local/bin/axs || exit 1
# After a fresh reinstall, proot can expose / as read-only while still leaving
# the copied axs binary executable with its original mode bits. In that case the
# chmod syscall fails, but treating that as fatal is wrong because axs was staged
# successfully and can still be launched. Only abort when the final file is not
# executable; otherwise continue.
chmod 755 /usr/local/bin/axs 2>/dev/null || {
    [ -x /usr/local/bin/axs ] || exit 1
}

_ready_pipe="/tmp/.axs-ready-$$"
rm -f "$_ready_pipe"
mkfifo "$_ready_pipe" || exit 1
export AXS_READY_PIPE="$_ready_pipe"
export RUST_LOG=error

"/usr/local/bin/axs" -c 'bash --rcfile /initrc -i' &
axs_pid=$!
wait_for_axs_ready "$axs_pid" "$_ready_pipe"
axs_ready_rc=$?
rm -f "$_ready_pipe"

if [ "$axs_ready_rc" -eq 0 ]; then
    # AXS is ready — wait for it to finish normally
    wait "$axs_pid"
else
    # AXS failed to become ready within 15s.
    if ! kill -0 "$axs_pid" 2>/dev/null; then
        # AXS died — propagate exit code
        wait "$axs_pid"
    else
        # AXS is alive but unresponsive — warn user and wait indefinitely.
        # The user can uninstall/reinstall the terminal if needed; but if they
        # do nothing, the wait continues in case AXS eventually recovers
        # (e.g. slow DNS resolution during first boot).
        echo -e "\e[33;1m[!]\e[0m AXS server startup timed out. You may need to uninstall and reinstall the terminal from Settings.\e[0m"
        wait "$axs_pid"
    fi
fi

else
    exec "$@"
fi
