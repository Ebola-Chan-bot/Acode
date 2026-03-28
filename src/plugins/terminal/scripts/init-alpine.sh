# 仅调试用: first-line probe — if this line is ABSENT while proot exits 182,
# then /bin/sh itself crashed before script execution began (ptrace setup failure).
echo "[alpine:L1,pid=$$,ppid=$PPID,args=$*]" >&2
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
        apk_add_rc=$?
        if [ "$apk_add_rc" -ne 0 ]; then
            if repair_script_interpreters; then
                run_apk_step "apk add required-packages after interpreter repair" "$repo_mode" apk add --no-cache $missing_packages
                apk_add_rc=$?
            fi
        fi

        if [ "$apk_add_rc" -ne 0 ] && ! required_packages_ready; then
            # The first apk add after a fresh reinstall can transiently die before the
            # payload is fully visible inside proot, then succeed immediately on the
            # next identical invocation against the same repositories. Retry exactly
            # once here so that this short-lived install race does not surface to the
            # UI as a fatal "installation failed with exit code 1/182" crash.
            echo -e "\e[33;1m[!] \e[0mapk add failed before required packages became visible; retrying once with ${repo_mode} repositories\e[0m"
            run_apk_step "apk add required-packages retry" "$repo_mode" apk add --no-cache $missing_packages
            apk_add_rc=$?
        fi

        if [ "$apk_add_rc" -ne 0 ] && required_packages_ready; then
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

        if [ "$apk_add_rc" -ne 0 ]; then
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
    echo "[init:normal-post-pid]" >&2 # 仅调试用: 到此说明 pid 写入和 chmod 正常

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
    # Write to temp file first, then mv to final path. cat is an external binary
    # intercepted by proot ptrace; when concurrent terminal sessions cause signal 54,
    # cat exits with rc=182 and produces 0 bytes. The > redirect truncates the target
    # BEFORE cat runs, so writing directly to initrc would destroy the working copy.
    # Using a temp file preserves the existing initrc on failure.
    cat <<'EOF' > "$PREFIX/alpine/initrc.tmp"
# Source rc files if they exist

    # Pure-builtin probe: no forks, no command substitution.
    # If this line appears in scrollback, bash reached rcfile processing;
    # if only [axs:tty=y,pgrp=ok] appears, exec(bash) or bash initialization
    # failed before rcfile was read.  (Terminal 1 rc=182 crash diagnostic) 仅调试用
    printf '[initrc:L1,pid=%s,ppid=%s]\n' "$$" "$PPID" # 仅调试用

    # 仅调试用: signal 54 forensics — read /proc/self/status signal fields to see
    # if signal 54 was delivered-and-blocked (SigPnd bit 53). Also read parent
    # (axs) and grandparent (proot) signal state to trace the signal source.
    # bit 53 in 16-char hex SigPnd = 3rd char from left, mask 0x2.
    if [ -f /proc/self/status ]; then
        _sig_self=$(grep '^Sig' /proc/self/status 2>/dev/null | tr '\n' ' ')
        _sig_parent=$(grep '^Sig' /proc/$PPID/status 2>/dev/null | tr '\n' ' ')
        _gpid=$(awk '/^PPid:/{print $2}' /proc/$PPID/status 2>/dev/null)
        _sig_gparent=$(grep '^Sig' /proc/$_gpid/status 2>/dev/null | tr '\n' ' ')
        _gp_comm=$(cat /proc/$_gpid/comm 2>/dev/null)
        _p_comm=$(cat /proc/$PPID/comm 2>/dev/null)
        printf '[initrc:sig54-forensics,self=%s(%s),parent=%s(%s),grandparent=%s(%s)]\n' \
            "$$" "$_sig_self" "$PPID" "$_sig_parent" "$_gpid" "$_sig_gparent"
        printf '[initrc:ancestry,self=%s,parent=%s(%s),grandparent=%s(%s)]\n' \
            "$$" "$PPID" "$_p_comm" "$_gpid" "$_gp_comm"
        # Check if signal 54 (bit 53) is pending in self
        _sigpnd=$(awk '/^SigPnd:/{print $2}' /proc/self/status 2>/dev/null)
        if [ -n "$_sigpnd" ]; then
            # Extract 3rd hex char from left (0-indexed: position 2), check bit 1 (mask 0x2)
            _hex3=$(echo "$_sigpnd" | cut -c3)
            _val=$(printf '%d' "0x$_hex3" 2>/dev/null || echo 0)
            if [ $((_val & 2)) -ne 0 ]; then
                printf '[initrc:sig54-PENDING,sigpnd=%s]\n' "$_sigpnd"
            else
                printf '[initrc:sig54-not-pending,sigpnd=%s]\n' "$_sigpnd"
            fi
        fi
    fi # 仅调试用

    # Emit an immediate shell-entry marker before any rc sourcing. The current
    # Terminal 1 crash exits with code 182 before the client sees bootstrap output;
    # the pure-builtin [initrc:L1] above disambiguates "exec failed" from
    # "bash started but crashed during rcfile evaluation". 仅调试用
    printf '[shell:initrc-enter,pid=%s,ppid=%s,argv0=%q,flags=%q,tty=%q]\n' "$$" "$PPID" "$0" "$-" "$(tty 2>/dev/null || echo no-tty)" >&2 # 仅调试用
    # 当前复现里真实 PTY 已经出现 prompt，但同阶段的 stderr 探针一个都没有，单看 stderr
    # 已经无法判断是 initrc 根本没执行，还是 live shell 的 stderr 在 WS/PTY 链路里被吞掉。
    # 这里补一个直接写进 PTY stdout 的入口标记，下次复现只要看首屏有没有这行就能立刻分流。 仅调试用
    printf '[shell:initrc-stdout-enter,pid=%s,ppid=%s,argv0=%q,flags=%q,tty=%q]\n' "$$" "$PPID" "$0" "$-" "$(tty 2>/dev/null || echo no-tty)" # 仅调试用

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

# Display MOTD
# Use shell builtins (read+printf) instead of cat to output MOTD.
# In proot, external binaries like cat need execve which proot intercepts via ptrace.
# When a second terminal instance runs concurrently, cat writing to the PTY fd fails
# with rc=182 (empty stderr). Shell builtins run in-process without execve, bypassing
# the proot ptrace issue entirely.
if [ -s /etc/acode_motd ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
    done < /etc/acode_motd
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
_initrc_heredoc_rc=$? # 仅调试用
_initrc_post_heredoc_size=$(wc -c < "$PREFIX/alpine/initrc.tmp" 2>/dev/null) # 仅调试用
_initrc_post_heredoc_line1=$(head -n 1 "$PREFIX/alpine/initrc.tmp" 2>/dev/null) # 仅调试用
# 仅调试用: 日志显示第二次启动时 initrc 文件从 8673 字节缩水为 152 字节(仅 PS1 行),
# 说明 heredoc 的 cat 没有产出任何内容。>重定向先截断文件, 然后 cat 以空输出退出,
# 导致 grep 找不到 PS1= 从而追加, 最终 initrc 只剩 PS1。以下探针区分三种故障模式:
# 1) cat 崩溃(rc>128) 2) cat 被终止但未崩溃(rc!=0) 3) heredoc temp 文件创建失败。
printf '[init:initrc-heredoc-done,rc=%s,size=%s,line1=%s]\n' "$_initrc_heredoc_rc" "$_initrc_post_heredoc_size" "$_initrc_post_heredoc_line1" >&2 # 仅调试用

# Atomically replace initrc only if heredoc succeeded (rc=0 AND non-empty).
# On failure (signal 54 / rc=182), the existing initrc is preserved intact.
if [ "$_initrc_heredoc_rc" -eq 0 ] && [ -s "$PREFIX/alpine/initrc.tmp" ]; then
    mv -f "$PREFIX/alpine/initrc.tmp" "$PREFIX/alpine/initrc"
else
    printf '[init:initrc-heredoc-FAILED,rc=%s,keeping-old]\n' "$_initrc_heredoc_rc" >&2 # 仅调试用
    rm -f "$PREFIX/alpine/initrc.tmp"
fi

# Add PS1 only if not already present
if ! grep -q 'PS1=' "$PREFIX/alpine/initrc"; then
    printf '[init:initrc-ps1-needed,size-before=%s]\n' "$_initrc_post_heredoc_size" >&2 # 仅调试用
    # Smart path shortening (fish-style: ~/p/s/components)
    echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\$_PS1_PATH\[\033[0m\] \[\$([ "${_PS1_EXIT:-0}" -ne 0 ] && echo \"\033[31m\")\]\$\[\033[0m\] "' >> "$PREFIX/alpine/initrc"
    # Simple prompt (uncomment below and comment above if you prefer full paths)
    # echo 'PS1="\[\033[1;32m\]\u\[\033[0m\]@localhost \[\033[1;34m\]\w\[\033[0m\] \$ "' >> "$PREFIX/alpine/initrc"
else
    printf '[init:initrc-ps1-exists,size=%s]\n' "$_initrc_post_heredoc_size" >&2 # 仅调试用
fi

_initrc_final_size=$(wc -c < "$PREFIX/alpine/initrc" 2>/dev/null) # 仅调试用
printf '[init:initrc-final,size=%s]\n' "$_initrc_final_size" >&2 # 仅调试用
chmod +x "$PREFIX/alpine/initrc"
echo "[init:normal-post-initrc]" >&2 # 仅调试用: 到此仅说明流程没有中断; heredoc 是否真正写入需查看上方 initrc-heredoc-done 探针

wait_for_axs_ready() {
    local axs_pid="$1"
    # 仅调试用: musl libc strftime 不支持 %N (纳秒)，date +%s%3N 可能输出非法值
    # 导致 $(( )) 算术表达式静默失败，从而使循环体中所有依赖 elapsed_ms 的探针全部丢失。
    # 改用 date +%s (仅秒)，放弃毫秒精度；同时保留原始格式输出用于确认假设。
    local ready_poll_date_raw # 仅调试用
    ready_poll_date_raw=$(date '+%s%3N') # 仅调试用
    local ready_poll_date_s # 仅调试用
    ready_poll_date_s=$(date +%s) # 仅调试用
    printf '[init:date-format-test,raw=%s,sonly=%s]\n' "$ready_poll_date_raw" "$ready_poll_date_s" >&2 # 仅调试用
    local ready_poll_started_at # 仅调试用
    ready_poll_started_at=$(date +%s) # 仅调试用

    # The frontend now waits for this explicit ready marker instead of blind
    # HTTP polling. Keep the readiness check here, next to the process launch,
    # so stale UI tasks cannot race and kill a newer healthy shared AXS instance.
    for attempt in $(seq 1 100); do
        # 仅调试用: 循环体入口金丝雀 — 前轮中 ready-poll,attempt= 日志全部缺失，
        # 需确认循环体是否真正执行以及是否在 date/算术行崩溃。
        [ "$attempt" -le 3 ] && printf '[init:loop-canary,i=%s,pid=%s]\n' "$attempt" "$axs_pid" >&2 # 仅调试用
        local wget_rc=0 # 仅调试用
        local now_s # 仅调试用
        now_s=$(date +%s) # 仅调试用
        local elapsed_s # 仅调试用
        elapsed_s=$((now_s - ready_poll_started_at)) # 仅调试用
        local should_log_attempt="n" # 仅调试用
        case "$attempt" in 1|2|3|10|25|50|75|100) should_log_attempt="y" ;; esac # 仅调试用
        wget -q -T 1 -O - "http://127.0.0.1:8767/status" >/dev/null 2>&1 || wget_rc=$?
        # 仅调试用: 前 3 次无条件输出 wget 返回值，确认是否每次都是 182 (signal 54)
        [ "$attempt" -le 3 ] && printf '[init:wget-detail,i=%s,rc=%s]\n' "$attempt" "$wget_rc" >&2 # 仅调试用
        if [ "$wget_rc" -eq 0 ]; then
            printf '[init:ready-poll,attempt=%s,wget=0,alive=y,elapsed_s=%s]\n' "$attempt" "$elapsed_s" >&2 # 仅调试用
            echo "__ACODE_AXS_READY__"
            return 0
        fi

        local kill_rc=0 # 仅调试用
        kill -0 "$axs_pid" 2>/dev/null || kill_rc=$? # 仅调试用
        if [ "$kill_rc" -ne 0 ]; then
            # 仅调试用: proot kill -0 returned non-zero — check /proc to verify
            # whether the process is truly dead or proot is lying.
            local proc_exists="n" # 仅调试用
            [ -d "/proc/$axs_pid" ] && proc_exists="y" # 仅调试用
            printf '[init:ready-poll,attempt=%s,wget=%s,kill0=%s,proc=%s,elapsed_s=%s,BAIL]\n' "$attempt" "$wget_rc" "$kill_rc" "$proc_exists" "$elapsed_s" >&2 # 仅调试用
            return 1
        fi
        [ "$should_log_attempt" = "y" ] && printf '[init:ready-poll,attempt=%s,wget=%s,alive=y,elapsed_s=%s]\n' "$attempt" "$wget_rc" "$elapsed_s" >&2 # 仅调试用
        sleep 0.1
    done

    local final_ready_out_file="/tmp/acode-ready-final.out.$$" # 仅调试用
    local final_ready_err_file="/tmp/acode-ready-final.err.$$" # 仅调试用
    rm -f "$final_ready_out_file" "$final_ready_err_file" # 仅调试用
    local final_ready_wget_rc=0 # 仅调试用
    wget -S -T 1 -O "$final_ready_out_file" "http://127.0.0.1:8767/status" 2>"$final_ready_err_file" || final_ready_wget_rc=$? # 仅调试用
    local final_now_s # 仅调试用
    final_now_s=$(date +%s) # 仅调试用
    local final_elapsed_s # 仅调试用
    final_elapsed_s=$((final_now_s - ready_poll_started_at)) # 仅调试用
    printf '[init:ready-poll,exhausted=100,elapsed_s=%s,final_wget=%s]\n' "$final_elapsed_s" "$final_ready_wget_rc" >&2 # 仅调试用
    if [ -s "$final_ready_out_file" ]; then sed 's/^/[init:ready-final-stdout] /' "$final_ready_out_file" >&2; else echo '[init:ready-final-stdout=<empty>]' >&2; fi # 仅调试用
    if [ -s "$final_ready_err_file" ]; then sed 's/^/[init:ready-final-stderr] /' "$final_ready_err_file" >&2; else echo '[init:ready-final-stderr=<empty>]' >&2; fi # 仅调试用
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
# 仅调试用: proot-rc=1 时 [init:normal] 后无任何中间探针直接退出, 以下三个 || exit 1
# 是嫌疑人。逐个添加探针定位具体哪一步失败。
echo "[init:pre-mkdir,target=/usr/local/bin,prefix=$PREFIX]" >&2 # 仅调试用
ls -ld / /usr /usr/local 2>&1 | sed 's/^/[init:mkdir-path] /' >&2 # 仅调试用
mkdir_err_file="/tmp/acode-init-mkdir.err.$$" # 仅调试用
rm -f "$mkdir_err_file" # 仅调试用
mkdir -p /usr/local/bin 2>"$mkdir_err_file" || { # 仅调试用
    mkdir_rc=$? # 仅调试用
    if [ -s "$mkdir_err_file" ]; then sed 's/^/[init:mkdir-stderr] /' "$mkdir_err_file" >&2; else echo "[init:mkdir-stderr=<empty>]" >&2; fi # 仅调试用
    stat / /usr /usr/local 2>&1 | sed 's/^/[init:mkdir-stat] /' >&2 # 仅调试用
    echo "[init:mkdir-FAIL,rc=$mkdir_rc]" >&2 # 仅调试用
    rm -f "$mkdir_err_file" # 仅调试用
    exit 1 # 仅调试用
} # 仅调试用
if [ -s "$mkdir_err_file" ]; then sed 's/^/[init:mkdir-stderr] /' "$mkdir_err_file" >&2; fi # 仅调试用
rm -f "$mkdir_err_file" # 仅调试用
ls -ld /usr/local/bin 2>&1 | sed 's/^/[init:mkdir-ok] /' >&2 # 仅调试用
echo "[init:pre-cp,src=$PREFIX/axs]" >&2 # 仅调试用
ls -l "$PREFIX/axs" 2>&1 | sed 's/^/[init:axs-ls] /' >&2 # 仅调试用
ls -l /usr/local/bin/axs 2>&1 | sed 's/^/[init:dst-ls-before] /' >&2 # 仅调试用: cp目标在cp前的状态
_cp_attempt=0 # 仅调试用: cp有时被signal 54杀，加重试和诊断
_cp_ok=0 # 仅调试用
while [ $_cp_attempt -lt 3 ]; do # 仅调试用
    _cp_attempt=$((_cp_attempt + 1)) # 仅调试用
    _cp_t0=$(date +%s%N 2>/dev/null || date +%s) # 仅调试用
    cp -f "$PREFIX/axs" /usr/local/bin/axs 2>/tmp/cp-err.txt # 仅调试用: 分离stderr以保留错误信息
    _cp_rc=$? # 仅调试用
    _cp_t1=$(date +%s%N 2>/dev/null || date +%s) # 仅调试用
    if [ -s /tmp/cp-err.txt ]; then sed 's/^/[init:cp-stderr] /' /tmp/cp-err.txt >&2; fi # 仅调试用
    if [ $_cp_rc -eq 0 ]; then # 仅调试用
        echo "[init:cp-ok,attempt=$_cp_attempt,t0=$_cp_t0,t1=$_cp_t1]" >&2 # 仅调试用
        _cp_ok=1 # 仅调试用
        break # 仅调试用
    fi # 仅调试用
    echo "[init:cp-retry,attempt=$_cp_attempt,rc=$_cp_rc,t0=$_cp_t0,t1=$_cp_t1]" >&2 # 仅调试用
    ls -l /usr/local/bin/axs "$PREFIX/axs" 2>&1 | sed 's/^/[init:cp-retry-ls] /' >&2 # 仅调试用
    sleep 0.2 # 仅调试用: 短暂等待让proot稳定
done # 仅调试用
if [ $_cp_ok -ne 1 ]; then echo "[init:cp-FAIL,rc=$_cp_rc,attempts=$_cp_attempt]" >&2; exit 1; fi
# After a fresh reinstall, proot can expose / as read-only while still leaving
# the copied axs binary executable with its original mode bits. In that case the
# chmod syscall fails, but treating that as fatal is wrong because axs was staged
# successfully and can still be launched. Only abort when the final file is not
# executable; otherwise continue.
if ! chmod 755 /usr/local/bin/axs 2>/dev/null; then
    if [ ! -x /usr/local/bin/axs ]; then
        echo "[init:chmod-FAIL,not-executable]" >&2 # 仅调试用
        exit 1
    fi
fi
echo "[init:axs-staged-ok]" >&2 # 仅调试用: axs 已成功部署到 /usr/local/bin
# Enable axs PTY tracing: Terminal 1 crashes with exit 182 in ~6ms, and axs-side
# logs (PTY first output, WS replay, pty reader exit) are essential to distinguish
# whether the PTY link broke vs bash never started. 仅调试用
export AXS_TERMINAL_LOG=1 # 仅调试用
export RUST_LOG=warn # 仅调试用
# Exit 182 currently lands before initrc emits any marker, which means the failure
# happens earlier than MOTD generation and is likely in bash exec or loader startup
# under proot. All non-PTY bash probes below succeed (including --rcfile /initrc -i),
# confirming bash/initrc are NOT broken — the issue is specific to PTY-based spawn
# through axs. The pure-builtin [initrc:L1] probe added to initrc will disambiguate
# "exec(bash) failed" from "bash crashed during initialization before rcfile". 仅调试用
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
# 仅调试用: wrapper 脚本方案已验证不可行 — proot ptrace 拦截 execve 时
# 对 /tmp 内脚本产生 EFAULT (Bad address, os error 14)，导致所有 PTY 创建失败。
# 直接使用 bash，依赖 pre_exec 中的 [axs:tty=y,pgrp=ok] 探针 +
# initrc 首行 [initrc:L1] 探针来定位崩溃阶段。
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
