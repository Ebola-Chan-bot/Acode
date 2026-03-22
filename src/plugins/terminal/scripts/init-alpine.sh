export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin:/system/bin:/system/xbin:$PREFIX/local/bin
export HOME=/home
export TERM=xterm-256color

APK_MAIN_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/main"
APK_COMMUNITY_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/community"
APK_MIRROR_MAIN_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/main"
APK_MIRROR_COMMUNITY_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/community"

extract_shebang_interpreter() {
    local shebang_line="$1"
    local shebang_body=""

    case "$shebang_line" in
        '#!'*) shebang_body=${shebang_line#\#!} ;;
        *) return 1 ;;
    esac

    set -- $shebang_body
    [ $# -eq 0 ] && return 1
    printf '%s\n' "$1"
}

materialize_symlink_binary() {
    local link_path="$1"
    local link_dir=""
    local link_target=""
    local source_path=""
    local temp_path=""

    [ -L "$link_path" ] || return 1

    link_target="$(readlink "$link_path" 2>/dev/null || true)"
    [ -n "$link_target" ] || return 1

    if [[ "$link_target" == /* ]]; then
        source_path="$link_target"
    else
        link_dir="$(dirname -- "$link_path")"
        source_path="$link_dir/$link_target"
    fi

    [ -f "$source_path" ] || return 1
    [ -x "$source_path" ] || return 1

    temp_path="${link_path}.acode-real.$$"
    cp "$source_path" "$temp_path" || return 1
    chmod 755 "$temp_path" || return 1
    mv -f "$temp_path" "$link_path" || return 1
    return 0
}

repair_script_interpreters() {
    local interpreter_list=""
    local interpreter_path=""

    [ -f /lib/apk/db/scripts.tar ] || return 1

    interpreter_list="$({
        tar -tf /lib/apk/db/scripts.tar 2>/dev/null | while IFS= read -r script_entry; do
            local first_line=""
            local interpreter=""

            [ -z "$script_entry" ] && continue
            first_line="$(tar -xOf /lib/apk/db/scripts.tar "$script_entry" 2>/dev/null | sed -n '1p')"
            interpreter="$(extract_shebang_interpreter "$first_line" 2>/dev/null || true)"
            [ -n "$interpreter" ] && printf '%s\n' "$interpreter"
        done
    } | sort -u)"

    [ -n "$interpreter_list" ] || return 1

    for interpreter_path in $interpreter_list; do
        materialize_symlink_binary "$interpreter_path" && return 0
    done

    return 1
}

run_apk_step() {
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
        if [ $? -ne 0 ]; then
            if repair_script_interpreters; then
                run_apk_step "apk add required-packages after interpreter repair" "$repo_mode" apk add --no-cache $missing_packages
            fi
        fi

        if [ $? -ne 0 ] && ! required_packages_ready; then
            # The first apk add after a fresh reinstall can transiently die before the
            # payload is fully visible inside proot, then succeed immediately on the
            # next identical invocation against the same repositories. Retry exactly
            # once here so that this short-lived install race does not surface to the
            # UI as a fatal "installation failed with exit code 1/182" crash.
            echo -e "\e[33;1m[!] \e[0mapk add failed before required packages became visible; retrying once with ${repo_mode} repositories\e[0m"
            run_apk_step "apk add required-packages retry" "$repo_mode" apk add --no-cache $missing_packages
        fi

        if [ $? -ne 0 ] && required_packages_ready; then
            # Under proot, apk may unpack the required payload successfully and then
            # fail only while finalizing its database/trigger scripts because kernel
            # shebang execution is unreliable in this environment after reinstall.
            # The terminal only depends on the installed binaries/files, so once the
            # required package payload is verifiably present we must continue instead
            # of retrying another concurrent install against the same rootfs.
            echo -e "\e[33;1m[!] \e[0mapk reported a finalization error after package payload was installed; continuing with the verified runtime files\e[0m"
            install_succeeded="true"
            break
        fi

        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk add failed with ${repo_mode} repositories\e[0m"
            continue
        fi

        install_succeeded="true"
        break
    done

    if [ "$install_succeeded" != "true" ]; then
        echo -e "\e[31;1m[!] \e[0mapk package installation failed with both official and mirror repositories\e[0m"
        exit 1
    fi

    bash_path="$(find_bash_path)"

    # Post-install fixup: ensure /bin/bash exists if bash resolves elsewhere.
    if [ -n "$bash_path" ] && [ ! -e /bin/bash ]; then
        ln -sf "$bash_path" /bin/bash 2>/dev/null
    fi

    # Ensure /etc/shells has bash
    if [ -n "$bash_path" ] && ! grep -q "/bin/bash" /etc/shells 2>/dev/null; then
        echo "/bin/bash" >> /etc/shells 2>/dev/null
    fi

    # Verify
    [ -z "$bash_path" ] && echo -e "\e[31;1m[!] \e[0mbash still missing\e[0m"
    [ ! -f /usr/bin/wget ] && echo -e "\e[31;1m[!] \e[0mwget still missing\e[0m"

    if ! required_packages_ready; then
        echo -e "\e[31;1m[!] \e[0mRequired packages are still missing after installation\e[0m"
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
    echo "[init:normal,pid=$$]" >&2 # 仅调试用
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
    echo "[rc:bashrc=y]" >&2 # 仅调试用
    source "$HOME/.bashrc"
fi

if [ -f /etc/bash/bashrc ]; then
    echo "[rc:etc=y]" >&2 # 仅调试用
    source /etc/bash/bashrc
fi

# Display MOTD (only source that reliably runs in proot bash)
if [ -s /etc/acode_motd ]; then
    echo "[motd:s=y,sz=$(stat -c%s /etc/acode_motd 2>/dev/null || echo err)]" >&2 # 仅调试用
    motd_preview=$(head -c 48 /etc/acode_motd 2>/dev/null | tr '\r\n' '  ') # 仅调试用
    printf '[motd:preview=%q]\n' "$motd_preview" >&2 # 仅调试用
    echo "[motd:cat-begin]" >&2 # 仅调试用
    cat /etc/acode_motd
    echo "[motd:cat-rc=$?]" >&2 # 仅调试用
else
    echo "[motd:s=n,e=$([ -f /etc/acode_motd ] && echo 'empty' || echo 'missing')]" >&2 # 仅调试用
fi

# Work around proot shebang execution failures for Bash's missing-command hook.
# Bash normally auto-executes /usr/libexec/command-not-found when a command is
# missing, but direct shebang execution can fail in proot with
# "bad interpreter: Bad address". Run the original script explicitly through
# /bin/sh so the script keeps working without relying on the broken shebang path.
command_not_found_handle() {
    if [ -f /usr/libexec/command-not-found ]; then
        /bin/sh /usr/libexec/command-not-found "$@"
        return $?
    fi

    printf '%s: command not found\n' "$1" >&2
    return 127
}

# acode CLI: defined as a bash function instead of a standalone script.
# In proot, a script with #!/bin/bash triggers execve("/bin/bash"), which the
# kernel handles in kernel-space. proot relies on ptrace to intercept execve and
# translate paths, but the kernel's shebang-triggered second execve can bypass
# proot's path translation (especially with --link2symlink or Android's ptrace
# restrictions), causing "bad interpreter: No such file or directory".
# A bash function runs in the current process — no execve, no shebang, no issue.
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

EOF

# Add PS1 only if not already present
if ! grep -q 'PS1=' "$PREFIX/alpine/initrc"; then
    # Smart path shortening (fish-style: ~/p/s/components)
    echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\$_PS1_PATH\[\033[0m\] \[\$([ "${_PS1_EXIT:-0}" -ne 0 ] && echo \"\033[31m\")\]\$\[\033[0m\] "' >> "$PREFIX/alpine/initrc"
    # Simple prompt (uncomment below and comment above if you prefer full paths)
    # echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\w\[\033[0m\] \$ "' >> "$PREFIX/alpine/initrc"
fi

chmod +x "$PREFIX/alpine/initrc"

wait_for_axs_ready() {
    local axs_pid="$1"
    local attempt=""
    local axs_cmd_preview="" # 仅调试用

    # The frontend now waits for this explicit ready marker instead of blind
    # HTTP polling. Keep the readiness check here, next to the process launch,
    # so stale UI tasks cannot race and kill a newer healthy shared AXS instance.
    for attempt in $(seq 1 100); do
        if [ "$attempt" = "1" ] || [ "$attempt" = "25" ] || [ "$attempt" = "50" ] || [ "$attempt" = "100" ]; then # 仅调试用
            axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
            printf '[init:poll,att=%s,pid=%s,cmd=%s]\n' "$attempt" "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
        fi # 仅调试用

        if wget -q -T 1 -O /dev/null "http://127.0.0.1:8767/status"; then
            echo "[init:wget-ok,att=$attempt]" >&2 # 仅调试用
            echo "__ACODE_AXS_READY__"
            return 0
        fi

        if ! kill -0 "$axs_pid" 2>/dev/null; then
            axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
            printf '[init:axs-dead-detail,att=%s,pid=%s,cmd=%s]\n' "$attempt" "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
            echo "[init:axs-dead,att=$attempt]" >&2 # 仅调试用
            return 1
        fi
        sleep 0.1
    done

    axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
    printf '[init:wget-timeout-detail,pid=%s,cmd=%s]\n' "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
    echo "[init:wget-timeout,att=100]" >&2 # 仅调试用
    return 1
}

#actual source
#everytime a terminal is started initrc will run
# A refreshed Alpine rootfs can legitimately miss /usr/local/bin until the first
# app-managed startup recreates it. The previous copy sequence silently fell
# through on that missing directory and only surfaced later as a misleading
# "AXS exited before becoming ready" error even though axs was never launched.
# Create the target directory explicitly and fail immediately if staging the
# binary inside the rootfs does not succeed.
echo "[init:cp-axs]" >&2 # 仅调试用
mkdir_local_bin_error="$(mkdir -p /usr/local/bin 2>&1)" # 仅调试用
if [ $? -ne 0 ]; then
    echo "[init:mkdir-local-bin-failed]" >&2 # 仅调试用
    printf '[init:mkdir-local-bin-error=%s]\n' "$mkdir_local_bin_error" >&2 # 仅调试用
    ls -ld /usr /usr/local /usr/local/bin 2>&1 >&2 # 仅调试用
    exit 1
fi
cp_axs_error="$(cp -f "$PREFIX/axs" /usr/local/bin/axs 2>&1)" # 仅调试用
if [ $? -ne 0 ]; then
    echo "[init:cp-axs-failed]" >&2 # 仅调试用
    printf '[init:cp-axs-error=%s]\n' "$cp_axs_error" >&2 # 仅调试用
    ls -l "$PREFIX/axs" 2>&1 >&2 # 仅调试用
    ls -ld /usr /usr/local /usr/local/bin 2>&1 >&2 # 仅调试用
    ls -l /usr/local/bin 2>&1 >&2 # 仅调试用
    exit 1
fi
ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
chmod_axs_error="$(chmod 755 /usr/local/bin/axs 2>&1)" # 仅调试用
if [ $? -ne 0 ]; then
    echo "[init:chmod-axs-failed]" >&2 # 仅调试用
    printf '[init:chmod-axs-error=%s]\n' "$chmod_axs_error" >&2 # 仅调试用
    stat /usr/local/bin/axs 2>&1 >&2 # 仅调试用
    mount 2>&1 | grep ' on /usr\| on / ' >&2 # 仅调试用
    ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
    exit 1
fi
ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
echo "[init:exec-axs]" >&2 # 仅调试用
"/usr/local/bin/axs" -c "bash --rcfile /initrc -i" &
axs_pid=$!
echo "[init:axs-pid=$axs_pid]" >&2 # 仅调试用
wait_for_axs_ready "$axs_pid"
axs_ready_rc=$? # 仅调试用
echo "[init:ready-rc=$axs_ready_rc]" >&2 # 仅调试用
axs_wait_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
printf '[init:wait-begin,pid=%s,cmd=%s]\n' "$axs_pid" "${axs_wait_cmd_preview:-<unreadable>}" >&2 # 仅调试用
wait "$axs_pid"
echo "[init:wait-rc=$?]" >&2 # 仅调试用

else
    exec "$@"
fi
