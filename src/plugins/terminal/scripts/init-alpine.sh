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

    # Emit an immediate shell-entry marker before any rc sourcing. The current
    # Terminal 2 failure exits with code 1 before the client sees bootstrap output,
    # so this line tells us whether bash actually started executing initrc or died
    # earlier in the exec path. 仅调试用
    printf '[shell:initrc-enter,pid=%s,ppid=%s,argv0=%q,flags=%q,tty=%q]\n' "$$" "$PPID" "$0" "$-" "$(tty 2>/dev/null || echo no-tty)" >&2 # 仅调试用

    # Keep an EXIT marker paired with the initrc-enter marker so the next repro can
    # separate "bash never entered initrc" from "bash started and then exited 1
    # during rc/bootstrap work" without needing logcat or an attached debugger. 仅调试用
    trap 'shell_exit_rc=$?; printf '\''[shell:initrc-exit,pid=%s,rc=%s,last=%q,tty=%q]\n'\'' "$$" "$shell_exit_rc" "$BASH_COMMAND" "$(tty 2>/dev/null || echo no-tty)" >&2' EXIT # 仅调试用

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
    motd_tty_before=$(tty 2>/dev/null || echo no-tty) # 仅调试用
    motd_fd0_before=$(readlink /proc/$$/fd/0 2>/dev/null || echo readlink-failed) # 仅调试用
    motd_fd1_before=$(readlink /proc/$$/fd/1 2>/dev/null || echo readlink-failed) # 仅调试用
    motd_fd2_before=$(readlink /proc/$$/fd/2 2>/dev/null || echo readlink-failed) # 仅调试用
    printf '[motd:cat-env,pid=%s,ppid=%s,tty=%q,fd0=%q,fd1=%q,fd2=%q]\n' "$$" "$PPID" "$motd_tty_before" "$motd_fd0_before" "$motd_fd1_before" "$motd_fd2_before" >&2 # 仅调试用
    echo "[motd:cat-begin]" >&2 # 仅调试用
    # 当前有效复现已经证明：同一份 /etc/acode_motd 在非交互 source 与 `bash --rcfile -i -c`
    # 探针里都能正常输出，但真实终端 child 中直接 `cat` 到当前 stdio 会返回 182 且 stderr 为空。
    # 这里额外探测“cat 到普通文件”是否成功，用来把问题收敛成“读文件失败”还是“向终端 fd 写失败”。 仅调试用
    motd_cat_file_probe="/tmp/acode-motd-file-probe.$$.out" # 仅调试用
    motd_cat_file_err_probe="/tmp/acode-motd-file-probe.$$.err" # 仅调试用
    rm -f "$motd_cat_file_probe" "$motd_cat_file_err_probe" # 仅调试用
    cat /etc/acode_motd >"$motd_cat_file_probe" 2>"$motd_cat_file_err_probe" # 仅调试用
    motd_cat_file_rc=$? # 仅调试用
    echo "[motd:cat-file-rc=$motd_cat_file_rc]" >&2 # 仅调试用
    if [ -s "$motd_cat_file_probe" ]; then head -n 2 "$motd_cat_file_probe" | sed 's/^/[motd:cat-file-stdout] /' >&2; else echo '[motd:cat-file-stdout=<empty>]' >&2; fi # 仅调试用
    if [ -s "$motd_cat_file_err_probe" ]; then sed 's/^/[motd:cat-file-stderr] /' "$motd_cat_file_err_probe" >&2; else echo '[motd:cat-file-stderr=<empty>]' >&2; fi # 仅调试用
    rm -f "$motd_cat_file_probe" "$motd_cat_file_err_probe" # 仅调试用
    motd_cat_err_file="/tmp/acode-motd-cat.$$.err" # 仅调试用
    rm -f "$motd_cat_err_file" # 仅调试用
    cat /etc/acode_motd 2>"$motd_cat_err_file" # 仅调试用
    motd_cat_rc=$? # 仅调试用
    echo "[motd:cat-rc=$motd_cat_rc]" >&2 # 仅调试用
    if [ "$motd_cat_rc" -ne 0 ]; then # 仅调试用
        if [ -s "$motd_cat_err_file" ]; then sed 's/^/[motd:cat-stderr] /' "$motd_cat_err_file" >&2; else echo '[motd:cat-stderr=<empty>]' >&2; fi # 仅调试用
        ps -o pid=,ppid=,stat=,tty=,cmd= -p "$$" -p "$PPID" 2>/dev/null | sed 's/^/[motd:ps] /' >&2 # 仅调试用
        stty -a 2>/dev/null | tr '\r\n' '  ' | sed 's/^/[motd:stty] /' >&2 # 仅调试用
        printf '[motd:cat-post,tty=%q,fd0=%q,fd1=%q,fd2=%q]\n' "$(tty 2>/dev/null || echo no-tty)" "$(readlink /proc/$$/fd/0 2>/dev/null || echo readlink-failed)" "$(readlink /proc/$$/fd/1 2>/dev/null || echo readlink-failed)" "$(readlink /proc/$$/fd/2 2>/dev/null || echo readlink-failed)" >&2 # 仅调试用
    fi # 仅调试用
    rm -f "$motd_cat_err_file" # 仅调试用
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
    local wget_status_body="" # 仅调试用
    local wget_status_preview="" # 仅调试用
    local wget_status_error="" # 仅调试用
    local wget_status_rc_hex="" # 仅调试用
    local wget_root_body="" # 仅调试用
    local wget_root_preview="" # 仅调试用
    local wget_root_error="" # 仅调试用
    local wget_root_rc_hex="" # 仅调试用
    local wget_status_rc="0" # 仅调试用
    local wget_root_rc="0" # 仅调试用

    # The frontend now waits for this explicit ready marker instead of blind
    # HTTP polling. Keep the readiness check here, next to the process launch,
    # so stale UI tasks cannot race and kill a newer healthy shared AXS instance.
    for attempt in $(seq 1 100); do
        if [ "$attempt" = "1" ] || [ "$attempt" = "25" ] || [ "$attempt" = "50" ] || [ "$attempt" = "100" ]; then # 仅调试用
            axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
            printf '[init:poll,att=%s,pid=%s,cmd=%s]\n' "$attempt" "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
        fi # 仅调试用

        wget_status_body="$(wget -q -T 1 -O - "http://127.0.0.1:8767/status" 2>&1)" # 仅调试用
        wget_status_rc=$? # 仅调试用
        wget_status_error="$wget_status_body" # 仅调试用
        if [ "$wget_status_rc" -eq 0 ]; then
            wget_status_preview="$(printf '%s' "$wget_status_body" | tr '\n' ' ' | head -c 200)" # 仅调试用
            # A previous runtime capture timed out while the final logged rc was 0,
            # which should be impossible in this branch structure. Log the exact
            # branch entry so the next repro can separate true ready detection from
            # stream reordering or a stale on-device script. # 仅调试用
            printf '[init:wget-ready-branch,att=%s,rc=%s,body=%s]\n' "$attempt" "$wget_status_rc" "${wget_status_preview:-<empty>}" >&2 # 仅调试用
            echo "[init:wget-ok,att=$attempt]" >&2 # 仅调试用
            printf '[init:wget-ok-body,att=%s,body=%s]\n' "$attempt" "${wget_status_preview:-<empty>}" >&2 # 仅调试用
            echo "__ACODE_AXS_READY__"
            return 0
        fi

        # If this ever fires, the shell believed rc was the string 0 but still did
        # not enter the numeric ready branch above. That would point to hidden bytes
        # or a shell/runtime mismatch rather than a normal axs startup failure. # 仅调试用
        if [ "$wget_status_rc" = "0" ]; then
            wget_status_rc_hex="$(printf '%s' "$wget_status_rc" | od -An -tx1 | tr -d ' \n')" # 仅调试用
            printf '[init:wget-zero-string-without-ready,att=%s,rc=%s,hex=%s]\n' "$attempt" "$wget_status_rc" "${wget_status_rc_hex:-<empty>}" >&2 # 仅调试用
        fi # 仅调试用

        if [ "$attempt" = "1" ] || [ "$attempt" = "25" ] || [ "$attempt" = "50" ] || [ "$attempt" = "100" ]; then # 仅调试用
            wget_status_preview="$(printf '%s' "$wget_status_body" | tr '\n' ' ' | head -c 200)" # 仅调试用
            printf '[init:wget-status-failed,att=%s,rc=%s,err=%s]\n' "$attempt" "$wget_status_rc" "${wget_status_error:-<empty>}" >&2 # 仅调试用
            printf '[init:wget-status-body,att=%s,body=%s]\n' "$attempt" "${wget_status_preview:-<empty>}" >&2 # 仅调试用
            wget_root_body="$(wget -q -T 1 -O - "http://127.0.0.1:8767/" 2>&1)" # 仅调试用
            wget_root_rc=$? # 仅调试用
            wget_root_error="$wget_root_body" # 仅调试用
            wget_root_preview="$(printf '%s' "$wget_root_body" | tr '\n' ' ' | head -c 200)" # 仅调试用
            printf '[init:wget-root-probe,att=%s,rc=%s,err=%s]\n' "$attempt" "$wget_root_rc" "${wget_root_error:-<empty>}" >&2 # 仅调试用
            printf '[init:wget-root-body,att=%s,body=%s]\n' "$attempt" "$wget_root_preview" >&2 # 仅调试用
        fi # 仅调试用

        if ! kill -0 "$axs_pid" 2>/dev/null; then
            axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
            printf '[init:axs-dead-detail,att=%s,pid=%s,cmd=%s]\n' "$attempt" "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
            echo "[init:axs-dead,att=$attempt]" >&2 # 仅调试用
            return 1
        fi
        sleep 0.1
    done

    axs_cmd_preview=$(tr '\000' ' ' < "/proc/$axs_pid/cmdline" 2>/dev/null | head -c 120) # 仅调试用
    wget_status_preview="$(printf '%s' "$wget_status_body" | tr '\n' ' ' | head -c 200)" # 仅调试用
    wget_root_preview="$(printf '%s' "$wget_root_body" | tr '\n' ' ' | head -c 200)" # 仅调试用
    wget_status_rc_hex="$(printf '%s' "$wget_status_rc" | od -An -tx1 | tr -d ' \n')" # 仅调试用
    wget_root_rc_hex="$(printf '%s' "$wget_root_rc" | od -An -tx1 | tr -d ' \n')" # 仅调试用
    printf '[init:wget-timeout-detail,pid=%s,cmd=%s]\n' "$axs_pid" "${axs_cmd_preview:-<unreadable>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-status,rc=%s,err=%s]\n' "$wget_status_rc" "${wget_status_error:-<empty>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-status-rc-hex,hex=%s]\n' "${wget_status_rc_hex:-<empty>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-status-body,body=%s]\n' "${wget_status_preview:-<empty>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-root,rc=%s,err=%s]\n' "$wget_root_rc" "${wget_root_error:-<empty>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-root-rc-hex,hex=%s]\n' "${wget_root_rc_hex:-<empty>}" >&2 # 仅调试用
    printf '[init:wget-timeout-last-root-body,body=%s]\n' "${wget_root_preview:-<empty>}" >&2 # 仅调试用
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
cp_axs_rc=$? # 仅调试用
if [ $cp_axs_rc -ne 0 ]; then
    # Some devices report a failing cp here with an empty stderr payload. Keep
    # the shell rc plus the pre-exec file state so the next repro can tell
    # whether we lost the destination entry, hit a permission boundary, or saw
    # a toolchain-level failure before axs ever launched. 仅调试用
    echo "[init:cp-axs-failed]" >&2 # 仅调试用
    printf '[init:cp-axs-rc=%s]\n' "$cp_axs_rc" >&2 # 仅调试用
    printf '[init:cp-axs-error=%s]\n' "$cp_axs_error" >&2 # 仅调试用
    stat "$PREFIX/axs" 2>&1 >&2 # 仅调试用
    stat /usr/local/bin/axs 2>&1 >&2 # 仅调试用
    ls -l "$PREFIX/axs" 2>&1 >&2 # 仅调试用
    ls -ld /usr /usr/local /usr/local/bin 2>&1 >&2 # 仅调试用
    ls -l /usr/local/bin 2>&1 >&2 # 仅调试用
    exit 1
fi
ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
chmod_axs_error="$(chmod 755 /usr/local/bin/axs 2>&1)" # 仅调试用
if [ $? -ne 0 ]; then
    # After a fresh reinstall, proot can expose / as read-only while still leaving
    # the copied axs binary executable with its original mode bits. In that case the
    # chmod syscall fails, but treating that as fatal is wrong because axs was staged
    # successfully and can still be launched. Only abort when the final file is not
    # executable; otherwise keep the readonly-rootfs evidence and continue. 仅调试用
    if [ ! -x /usr/local/bin/axs ]; then
        echo "[init:chmod-axs-failed]" >&2 # 仅调试用
        printf '[init:chmod-axs-error=%s]\n' "$chmod_axs_error" >&2 # 仅调试用
        stat /usr/local/bin/axs 2>&1 >&2 # 仅调试用
        mount 2>&1 | grep ' on /usr\| on / ' >&2 # 仅调试用
        ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
        exit 1
    fi
    echo "[init:chmod-axs-skipped-ro-rootfs]" >&2 # 仅调试用
    printf '[init:chmod-axs-error=%s]\n' "$chmod_axs_error" >&2 # 仅调试用
    stat /usr/local/bin/axs 2>&1 >&2 # 仅调试用
    mount 2>&1 | grep ' on /usr\| on / ' >&2 # 仅调试用
    ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
fi
ls -l /usr/local/bin/axs 2>&1 >&2 # 仅调试用
# 这里在启动 axs 前强制打开后端 terminal tracing，是因为当前“三个终端只有 prompt、没有 MOTD”现象仅靠前端日志已经无法继续区分：到底是 /etc/acode_motd 根本没生成，还是 PTY 已经产出首屏但 WS replay 只回放到了尾部。axs 代码里的 PTY first output / WS replay handshake 日志默认被关闭，不显式打开就永远拿不到下一步诊断所需证据。 仅调试用
export AXS_TERMINAL_LOG=1 # 仅调试用
export RUST_LOG=warn # 仅调试用
# Exit 182 currently lands before initrc emits any marker, which means the failure
# happens earlier than MOTD generation and is likely in bash exec or loader startup
# under proot. Probe a minimal non-interactive bash first so the next repro can tell
# whether bash itself is already broken or only the interactive rcfile/PTy path fails. 仅调试用
echo "[init:bash-probe-begin]" >&2 # 仅调试用
printf '[init:bash-probe-path=%s]\n' "$(command -v bash 2>/dev/null || echo missing)" >&2 # 仅调试用
ls -l /bin/bash 2>&1 | sed 's/^/[init:bash-probe-ls] /' >&2 # 仅调试用
bash_probe_out_file="/tmp/acode-bash-probe.out" # 仅调试用
bash_probe_err_file="/tmp/acode-bash-probe.err" # 仅调试用
rm -f "$bash_probe_out_file" "$bash_probe_err_file" # 仅调试用
bash --noprofile --norc -c 'printf "[init:bash-probe-ok,pid=%s,ppid=%s,argv0=%q]\n" "$$" "$PPID" "$0"' >"$bash_probe_out_file" 2>"$bash_probe_err_file" # 仅调试用
bash_probe_rc=$? # 仅调试用
printf '[init:bash-probe-rc=%s]\n' "$bash_probe_rc" >&2 # 仅调试用
if [ -s "$bash_probe_out_file" ]; then sed 's/^/[init:bash-probe-stdout] /' "$bash_probe_out_file" >&2; else echo '[init:bash-probe-stdout=<empty>]' >&2; fi # 仅调试用
if [ -s "$bash_probe_err_file" ]; then sed 's/^/[init:bash-probe-stderr] /' "$bash_probe_err_file" >&2; else echo '[init:bash-probe-stderr=<empty>]' >&2; fi # 仅调试用
# 现在已经证明 bash 本体和纯交互模式都能起来，但 `--rcfile /initrc -i` 仍然 182 且
# 连 `shell:initrc-enter` 都没有。下一步先把 `/initrc` 当普通文件验证，避免继续把
# “文件不可读/不可解析”和“只有 rcfile 机制异常”混在一起。 仅调试用
ls -l /initrc 2>&1 | sed 's/^/[init:initrc-ls] /' >&2 # 仅调试用
stat /initrc 2>&1 | sed 's/^/[init:initrc-stat] /' >&2 # 仅调试用
head -n 6 /initrc 2>&1 | sed 's/^/[init:initrc-head] /' >&2 # 仅调试用
od -An -tx1 -N 32 /initrc 2>&1 | tr '\n' ' ' | sed 's/^/[init:initrc-hex] /' >&2 # 仅调试用
printf '\n' >&2 # 仅调试用
initrc_source_out_file="/tmp/acode-initrc-source.out" # 仅调试用
initrc_source_err_file="/tmp/acode-initrc-source.err" # 仅调试用
rm -f "$initrc_source_out_file" "$initrc_source_err_file" # 仅调试用
bash --noprofile --norc -c '. /initrc; printf "[init:initrc-source-ok,pid=%s,ppid=%s,argv0=%q,flags=%q]\n" "$$" "$PPID" "$0" "$-"' >"$initrc_source_out_file" 2>"$initrc_source_err_file" # 仅调试用
initrc_source_rc=$? # 仅调试用
printf '[init:initrc-source-rc=%s]\n' "$initrc_source_rc" >&2 # 仅调试用
if [ -s "$initrc_source_out_file" ]; then sed 's/^/[init:initrc-source-stdout] /' "$initrc_source_out_file" >&2; else echo '[init:initrc-source-stdout=<empty>]' >&2; fi # 仅调试用
if [ -s "$initrc_source_err_file" ]; then sed 's/^/[init:initrc-source-stderr] /' "$initrc_source_err_file" >&2; else echo '[init:initrc-source-stderr=<empty>]' >&2; fi # 仅调试用
# 22:46 的有效复现里最小 bash probe 已经成功，但真正的 `bash --rcfile /initrc -i`
# 仍然以 182 立即退出且没有 `shell:initrc-enter`。继续把“纯交互 bash 失败”与
# “只有带 rcfile 的交互 bash 才失败”拆开，否则还会把根因卡在过宽的交互启动区间。 仅调试用
bash_interactive_out_file="/tmp/acode-bash-interactive.out" # 仅调试用
bash_interactive_err_file="/tmp/acode-bash-interactive.err" # 仅调试用
rm -f "$bash_interactive_out_file" "$bash_interactive_err_file" # 仅调试用
bash --noprofile --norc -i -c 'printf "[init:bash-interactive-ok,pid=%s,ppid=%s,argv0=%q,flags=%q]\n" "$$" "$PPID" "$0" "$-"' >"$bash_interactive_out_file" 2>"$bash_interactive_err_file" # 仅调试用
bash_interactive_rc=$? # 仅调试用
printf '[init:bash-interactive-rc=%s]\n' "$bash_interactive_rc" >&2 # 仅调试用
if [ -s "$bash_interactive_out_file" ]; then sed 's/^/[init:bash-interactive-stdout] /' "$bash_interactive_out_file" >&2; else echo '[init:bash-interactive-stdout=<empty>]' >&2; fi # 仅调试用
if [ -s "$bash_interactive_err_file" ]; then sed 's/^/[init:bash-interactive-stderr] /' "$bash_interactive_err_file" >&2; else echo '[init:bash-interactive-stderr=<empty>]' >&2; fi # 仅调试用
bash_rcfile_out_file="/tmp/acode-bash-rcfile.out" # 仅调试用
bash_rcfile_err_file="/tmp/acode-bash-rcfile.err" # 仅调试用
rm -f "$bash_rcfile_out_file" "$bash_rcfile_err_file" # 仅调试用
bash --noprofile --rcfile /initrc -i -c 'printf "[init:bash-rcfile-ok,pid=%s,ppid=%s,argv0=%q,flags=%q]\n" "$$" "$PPID" "$0" "$-"' >"$bash_rcfile_out_file" 2>"$bash_rcfile_err_file" # 仅调试用
bash_rcfile_rc=$? # 仅调试用
printf '[init:bash-rcfile-rc=%s]\n' "$bash_rcfile_rc" >&2 # 仅调试用
if [ -s "$bash_rcfile_out_file" ]; then sed 's/^/[init:bash-rcfile-stdout] /' "$bash_rcfile_out_file" >&2; else echo '[init:bash-rcfile-stdout=<empty>]' >&2; fi # 仅调试用
if [ -s "$bash_rcfile_err_file" ]; then sed 's/^/[init:bash-rcfile-stderr] /' "$bash_rcfile_err_file" >&2; else echo '[init:bash-rcfile-stderr=<empty>]' >&2; fi # 仅调试用
if command -v ldd >/dev/null 2>&1; then # 仅调试用
    bash_ldd_out_file="/tmp/acode-bash-ldd.out" # 仅调试用
    bash_ldd_err_file="/tmp/acode-bash-ldd.err" # 仅调试用
    rm -f "$bash_ldd_out_file" "$bash_ldd_err_file" # 仅调试用
    ldd /bin/bash >"$bash_ldd_out_file" 2>"$bash_ldd_err_file" # 仅调试用
    bash_ldd_rc=$? # 仅调试用
    printf '[init:bash-ldd-rc=%s]\n' "$bash_ldd_rc" >&2 # 仅调试用
    if [ -s "$bash_ldd_out_file" ]; then sed 's/^/[init:bash-ldd-stdout] /' "$bash_ldd_out_file" >&2; else echo '[init:bash-ldd-stdout=<empty>]' >&2; fi # 仅调试用
    if [ -s "$bash_ldd_err_file" ]; then sed 's/^/[init:bash-ldd-stderr] /' "$bash_ldd_err_file" >&2; else echo '[init:bash-ldd-stderr=<empty>]' >&2; fi # 仅调试用
else
    echo '[init:bash-ldd-missing]' >&2 # 仅调试用
fi
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
