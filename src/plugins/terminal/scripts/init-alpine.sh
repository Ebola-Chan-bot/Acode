export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/share/bin:/usr/share/sbin:/usr/local/bin:/usr/local/sbin:/system/bin:/system/xbin:$PREFIX/local/bin
export HOME=/home
export TERM=xterm-256color

APK_MAIN_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/main"
APK_COMMUNITY_REPO="http://dl-cdn.alpinelinux.org/alpine/__ALPINE_BRANCH__/community"
APK_MIRROR_MAIN_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/main"
APK_MIRROR_COMMUNITY_REPO="http://mirrors.tuna.tsinghua.edu.cn/alpine/__ALPINE_BRANCH__/community"

# 182 policy switch: retry | failfast
AXS_EXIT_182_POLICY="${AXS_EXIT_182_POLICY:-failfast}"

should_retry_on_182() {
    local _rc="$1"
    [ "$_rc" -eq 182 ] || return 1
    [ "$AXS_EXIT_182_POLICY" = "retry" ] || return 1
    return 0
}

handle_182_policy() {
    local _tag="$1"
    local _rc="$2"
    local _retry="$3"

    if should_retry_on_182 "$_rc"; then
        return 0
    fi

    return 1
}

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
    echo "$$" > "$PREFIX/pid"
    chmod +x "$PREFIX/axs"

    # Write MOTD via temp file to avoid signal 54 truncating the target.
    # rc=182 behavior is controlled by AXS_EXIT_182_POLICY.
    if [ ! -s "$PREFIX/alpine/etc/acode_motd" ]; then
        while true; do
            cat <<EOF > "$PREFIX/alpine/etc/acode_motd.tmp"
Welcome to Alpine Linux in Acode!

Working with packages:

 - Search:  apk search <query>
 - Install: apk add <package>
 - Uninstall: apk del <package>
 - Upgrade: apk update && apk upgrade

EOF
            _motd_rc=$?
            if [ "$_motd_rc" -ne 0 ]; then
                : # cat failed; fall through to error handling
            fi
            if [ "$_motd_rc" -eq 0 ] && [ -s "$PREFIX/alpine/etc/acode_motd.tmp" ]; then
                # mv is also an external binary intercepted by proot ptrace;
                # signal 54 can kill mv (rc=182) leaving the file un-moved.
                mv -f "$PREFIX/alpine/etc/acode_motd.tmp" "$PREFIX/alpine/etc/acode_motd"
                _motd_mv_rc=$?
                if [ "$_motd_mv_rc" -ne 0 ]; then
                    rm -f "$PREFIX/alpine/etc/acode_motd.tmp"
                    if [ "$_motd_mv_rc" -eq 182 ]; then
                        if handle_182_policy 'init-alpine:motd-mv' "$_motd_mv_rc" ""; then
                            continue
                        fi
                        exit 182
                    fi
                    break
                fi
                break
            fi
            rm -f "$PREFIX/alpine/etc/acode_motd.tmp"
            if [ "$_motd_rc" -eq 182 ]; then
                if handle_182_policy 'init-alpine:motd' "$_motd_rc" ""; then
                    continue
                fi
                exit 182
            fi
            break
        done
    fi

    # Create/update initrc (always overwrite to keep in sync with app updates)
    # Cost: ~3KB heredoc write per startup, sub-millisecond — negligible.
    #initrc runs in bash so we can use bash features
    # Write to temp file first, then mv to final path. cat is an external binary
    # intercepted by proot ptrace; when concurrent terminal sessions cause signal 54,
    # cat exits with rc=182 and produces 0 bytes. The > redirect truncates the target
    # BEFORE cat runs, so writing directly to initrc would destroy the working copy.
    # Using a temp file preserves the existing initrc on failure.
    # rc=182 behavior is controlled by AXS_EXIT_182_POLICY.
    while true; do
    cat <<'EOF' > "$PREFIX/alpine/initrc.tmp"
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
    _initrc_heredoc_rc=$?

    if [ "$_initrc_heredoc_rc" -eq 0 ] && [ -s "$PREFIX/alpine/initrc.tmp" ]; then
        # mv is also an external binary intercepted by proot ptrace;
        # signal 54 can kill mv (rc=182) leaving the file un-moved.
        mv -f "$PREFIX/alpine/initrc.tmp" "$PREFIX/alpine/initrc"
        _initrc_mv_rc=$?
        if [ "$_initrc_mv_rc" -ne 0 ]; then
            rm -f "$PREFIX/alpine/initrc.tmp"
            if [ "$_initrc_mv_rc" -eq 182 ]; then
                if handle_182_policy 'init-alpine:initrc-mv' "$_initrc_mv_rc" ""; then
                    continue
                fi
                exit 182
            fi
            break
        fi
        break
    fi
    rm -f "$PREFIX/alpine/initrc.tmp"
    # Signal 54 (rc=182) policy is controlled by AXS_EXIT_182_POLICY.
    if [ "$_initrc_heredoc_rc" -eq 182 ]; then
        if handle_182_policy 'init-alpine:initrc' "$_initrc_heredoc_rc" ""; then
            continue
        fi
        exit 182
    fi
    # Other failure — give up, proceed without initrc
    break
    done

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
# Signal 54 can kill mkdir/cp inside proot (exit 182).
# rc=182 behavior is controlled by AXS_EXIT_182_POLICY.
while true; do
    mkdir -p /usr/local/bin 2>/dev/null && break
    _rc=$?
    if [ "$_rc" -eq 182 ]; then
        if handle_182_policy 'init-alpine:mkdir' "$_rc" ""; then
            continue
        fi
        exit 182
    fi
    exit 1
done
while true; do
    cp -f "$PREFIX/axs" /usr/local/bin/axs 2>/dev/null && break
    _rc=$?
    if [ "$_rc" -eq 182 ]; then
        if handle_182_policy 'init-alpine:cp-axs' "$_rc" ""; then
            continue
        fi
        exit 182
    fi
    exit 1
done
# After a fresh reinstall, proot can expose / as read-only while still leaving
# the copied axs binary executable with its original mode bits. In that case the
# chmod syscall fails, but treating that as fatal is wrong because axs was staged
# successfully and can still be launched. Only abort when the final file is not
# executable; otherwise continue.
# Signal 54 (exit 182) behavior is controlled by AXS_EXIT_182_POLICY.
while true; do
    chmod 755 /usr/local/bin/axs 2>/dev/null && break
    _rc=$?
    if [ "$_rc" -eq 182 ]; then
        if handle_182_policy 'init-alpine:chmod' "$_rc" ""; then
            continue
        fi
        exit 182
    fi
    # Non-182 chmod failure: tolerate if the file is already executable
    if [ -x /usr/local/bin/axs ]; then
        break
    fi
    exit 1
done

# Signal 54 (SIGRTMIN+20) can kill bash inside proot during startup, causing
# AXS to exit 182 (128+54) before emitting __ACODE_AXS_READY__.
# rc=182 behavior is controlled by AXS_EXIT_182_POLICY.
_axs_retry=0
_axs_hung_warned=0
_ready_pipe="/tmp/.axs-ready-$$"
while true; do
    _axs_retry=$((_axs_retry + 1))

    # Create FIFO for this attempt (remove stale one from previous retry)
    # mkfifo is also an external binary intercepted by proot ptrace;
    # signal 54 can kill it (rc=182) leaving no FIFO, which breaks the
    # ready-notification mechanism entirely.
    rm -f "$_ready_pipe"
    while true; do
        mkfifo "$_ready_pipe" && break
        _mkfifo_rc=$?
        if [ "$_mkfifo_rc" -eq 182 ]; then
            if handle_182_policy 'init-alpine:mkfifo' "$_mkfifo_rc" ""; then
                continue
            fi
            exit 182
        fi
        break
    done
    export AXS_READY_PIPE="$_ready_pipe"

    "/usr/local/bin/axs" -c 'bash --rcfile /initrc -i' &
    axs_pid=$!
    wait_for_axs_ready "$axs_pid" "$_ready_pipe"
    axs_ready_rc=$?
    rm -f "$_ready_pipe"

    if [ "$axs_ready_rc" -eq 0 ]; then
        # AXS is ready — wait for it to finish normally
        wait "$axs_pid"
        break
    fi

    # AXS failed to become ready within 15s.
    # If AXS died (signal 54 / exit 182), follow policy.
    # If AXS is still alive but never wrote READY to the FIFO, it is hung.
    # In the hung case, do NOT kill AXS — instead warn the user and keep
    # waiting indefinitely. The user can uninstall/reinstall the terminal
    # if needed; but if they do nothing, the wait continues in case AXS
    # eventually recovers (e.g. slow DNS resolution during first boot).
    if ! kill -0 "$axs_pid" 2>/dev/null; then
        # AXS died — collect exit code and decide whether to retry
        wait "$axs_pid"
        _axs_wait_rc=$?

        if [ "$_axs_wait_rc" -eq 182 ]; then
            if handle_182_policy 'init-alpine:axs-died' "$_axs_wait_rc" "$_axs_retry"; then
                continue
            fi
            exit 182
        fi
        # Other fatal error — propagate
        break
    fi

    # AXS is alive but unresponsive — warn user and wait indefinitely
    # Only show warning once; subsequent 182 retries that timeout again stay silent
    if [ "$_axs_hung_warned" -eq 0 ]; then
        _axs_hung_warned=1
        echo -e "\e[33;1m[!]\e[0m AXS 服务启动超时，可能需要在设置中卸载并重新安装终端。\e[0m"
        echo -e "\e[33;1m[!]\e[0m AXS server startup timed out. You may need to uninstall and reinstall the terminal from Settings.\e[0m"
    fi
    wait "$axs_pid"
    _axs_wait_rc=$?
    # AXS eventually exited while user was waiting. If signal 54 (exit 182),
    # follow policy.
    if [ "$_axs_wait_rc" -eq 182 ]; then
        if handle_182_policy 'init-alpine:axs-hung-exited' "$_axs_wait_rc" "$_axs_retry"; then
            continue
        fi
        exit 182
    fi
    break
done

else
    exec "$@"
fi
