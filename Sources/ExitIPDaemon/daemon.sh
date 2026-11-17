#!/bin/bash
# Install one boot-started Exit IP service. No networking settings are changed here.
# install: administrator-only; uninstall/remove: stop service/clients, keep all user and machine data.
# The root-owned copy permits only the fixed uninstall command through the removal grant.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LABEL=com.example.exitipmonitor.daemon
LEGACY=com.example.exitipmonitor.tailscale-verge
DIR='/Library/Application Support/ExitIPMonitor'
EXECUTABLE="/Library/PrivilegedHelperTools/$LABEL"
MANAGER="/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
GRANT=/etc/sudoers.d/exitipmonitor-service
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/command-support.sh" ]; then
    source "$SCRIPT_DIR/command-support.sh"
elif [ -f "$SCRIPT_DIR/../ExitIPDiagnostics/command-support.sh" ]; then
    source "$SCRIPT_DIR/../ExitIPDiagnostics/command-support.sh"
else
    source "$DIR/command-support.sh"
fi
run() { bounded_command 20 "$1" "$@"; }
require_root() { [ "$(/usr/bin/id -u)" = 0 ] || { echo 'Administrator authentication is required.' >&2; return 1; }; }

# Never install executable code through a symlink or into a user-writable directory.
secure_directory() {
    local path=$1
    [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; return 1; }
    if [ -e "$path" ]; then
        [ -d "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = 0 ] || return 1
    else
        /bin/mkdir "$path" || return 1
    fi
    /usr/sbin/chown root:wheel "$path" && /bin/chmod 0755 "$path"
}

service_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$EXECUTABLE</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ExitTimeOut</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
</dict></plist>
PLIST
}

job_state() {
    local output result=0
    output=$(run /bin/launchctl print "system/$1" 2>&1) || result=$?
    [ "$result" != 0 ] || return 0
    if [ "$result" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then return 1; fi
    echo "Could not inspect system/$1: $output" >&2
    return 2
}

unload() {
    local label=$1 state=0 ticks=0
    job_state "$label" || state=$?
    [ "$state" != 1 ] || return 0
    [ "$state" = 0 ] || return 1
    run /bin/launchctl bootout "system/$label" || return 1
    while [ "$ticks" -lt 100 ]; do
        state=0; job_state "$label" || state=$?
        [ "$state" != 1 ] || return 0
        [ "$state" = 0 ] || return 1
        /bin/sleep 0.2; ticks=$((ticks + 1))
    done
    echo "Service did not unload: $label" >&2
    return 1
}

# Both operations use the same atomic PID lock. An interrupted install leaves its
# backup under Service; ordinary failures restore the previous executable and launch job.
service_lock() {
    [ ! -L "$DIR/Service" ] || return 1
    [ ! -e "$DIR/Service" ] || [ "$(/usr/bin/stat -f %u "$DIR/Service")" = 0 ] || return 1
    /usr/bin/install -d -o root -g wheel -m 0700 "$DIR/Service" || return 1
    /usr/bin/shlock -p $$ -f "$DIR/Service/install.lock" || { echo 'Another service operation is active.' >&2; return 1; }
}

wait_legacy_workers() {
    local table pid command found ticks=0
    while [ "$ticks" -lt 100 ]; do
        table=$(run /bin/ps -axo pid=,command=) || return 1
        [ -n "$table" ] || return 1
        found=0
        while read -r pid command; do
            case "$command" in
                "/bin/bash $DIR/tailscale-verge.sh monitor"*|"/bin/bash $DIR/tailscale-verge.sh http"*) found=1 ;;
            esac
        done <<< "$table"
        [ "$found" = 1 ] || return 0
        /bin/sleep 0.2; ticks=$((ticks + 1))
    done
    echo 'Legacy provider workers did not exit; service replacement stopped.' >&2
    return 1
}

restore_installation() {
    local path result=0
    unload "$LABEL" || return 1
    for path in "${installed_files[@]}"; do
        if [ -f "$stage/backup/$(basename "$path")" ]; then
            /bin/cp -p "$stage/backup/$(basename "$path")" "$path" || result=1
        else
            /bin/rm -f "$path" || result=1
        fi
    done
    [ "$result" = 0 ] || return 1
    if [ "$old_loaded" = 1 ]; then run /bin/launchctl bootstrap system "$PLIST" || return 1; fi
    if [ "$legacy_loaded" = 1 ]; then run /bin/launchctl bootstrap system "/Library/LaunchDaemons/$LEGACY.plist" || return 1; fi
    if [ "$legacy_http_loaded" = 1 ]; then run /bin/launchctl bootstrap system "/Library/LaunchDaemons/$LEGACY-http.plist" || return 1; fi
}

finish_installation() {
    local result=$1
    if [ "$result" != 0 ] && [ "$mutation_started" = 1 ]; then
        if restore_installation; then
            echo 'Service installation failed; previous files and loaded services were restored.' >&2
        else
            echo "Service installation failed; recovery files were retained in $stage. Repair installation before continuing." >&2
            /bin/rm -f "$DIR/Service/install.lock"
            return
        fi
    fi
    [ -z "$stage" ] || /bin/rm -rf "$stage"
    /bin/rm -f "$DIR/Service/install.lock"
}

install_service() (
    require_root || return 1
    local binary="$SCRIPT_DIR/../MacOS/ExitIPMonitorDaemon" app stage="" owner=${SUDO_USER:-} path state
    local mutation_started=0 old_loaded=0 legacy_loaded=0 legacy_http_loaded=0
    local installed_files=("$EXECUTABLE" "$PLIST" "$MANAGER" "$DIR/command-support.sh" "$DIR/cleanup-installation.sh" "$DIR/installed-app" "$GRANT")
    [ -x "$binary" ] || { echo 'Install from a built ExitIPMonitor.app bundle.' >&2; return 1; }
    app=$(cd "$SCRIPT_DIR/../.." && pwd -P) || return 1
    run /usr/bin/codesign --verify --deep --strict "$app" || return 1
    run /usr/bin/codesign --verify --strict "$binary" || return 1
    secure_directory /Library/PrivilegedHelperTools && secure_directory /Library/LaunchDaemons &&
        secure_directory /etc/sudoers.d && secure_directory "$DIR" && secure_directory /Library/Logs/ExitIPMonitor || return 1
    service_lock || return 1
    trap 'finish_installation $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for path in "${installed_files[@]}"; do
        [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; return 1; }
        [ ! -e "$path" ] || { [ -f "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = 0 ]; } || return 1
    done
    stage=$(/usr/bin/mktemp -d "$DIR/Service/install.XXXXXXXX") || return 1
    /bin/mkdir "$stage/backup" || return 1
    for path in "${installed_files[@]}"; do
        [ ! -f "$path" ] || /bin/cp -p "$path" "$stage/backup/$(basename "$path")" || return 1
    done
    /usr/bin/install -o root -g wheel -m 0755 "$binary" "$stage/new" || return 1
    service_plist > "$stage/service.plist" || return 1
    /usr/bin/plutil -lint "$stage/service.plist" || return 1
    for path in "$LABEL" "$LEGACY" "$LEGACY-http"; do
        state=0; job_state "$path" || state=$?
        [ "$state" != 2 ] || return 1
        if [ "$state" = 0 ]; then
            case "$path" in "$LABEL") old_loaded=1 ;; "$LEGACY") legacy_loaded=1 ;; *) legacy_http_loaded=1 ;; esac
        fi
    done
    if [ -f "/Library/LaunchDaemons/$LEGACY.plist" ]; then /usr/bin/touch "$DIR/legacy-provider-enabled" || return 1; fi
    mutation_started=1
    unload "$LEGACY-http" && unload "$LEGACY" && unload "$LABEL" || return 1
    wait_legacy_workers || return 1
    /bin/mv -f "$stage/new" "$EXECUTABLE" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/service.plist" "$PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0755 "${BASH_SOURCE[0]}" "$MANAGER" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/command-support.sh" "$DIR/command-support.sh" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/cleanup-installation.sh" "$DIR/cleanup-installation.sh" || return 1
    printf '%s\n' "$app" > "$DIR/installed-app" || return 1
    /bin/chmod 0600 "$DIR/installed-app" || return 1
    run "$EXECUTABLE" --install-right || return 1
    run /bin/launchctl enable "system/$LABEL" || return 1
    run /bin/launchctl bootstrap system "$PLIST" && run "$EXECUTABLE" --check-service || return 1
    # A narrowly scoped, root-owned uninstaller preserves passwordless Homebrew removal.
    if [ -z "$owner" ] || [ "$owner" = root ]; then owner=$(/usr/bin/stat -f %Su /dev/console); fi
    if [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$owner" != root ] && [ "$owner" != loginwindow ]; then
        printf '%s ALL=(root) NOPASSWD: %s uninstall\n' "$owner" "$MANAGER" > "$stage/grant" || return 1
        /usr/sbin/visudo -cf "$stage/grant" && /usr/bin/install -o root -g wheel -m 0440 "$stage/grant" "$GRANT" || return 1
    fi
    mutation_started=0
    /bin/rm -f "/Library/LaunchDaemons/$LEGACY.plist" "/Library/LaunchDaemons/$LEGACY-http.plist" "/etc/sudoers.d/exitipmonitor-tailscale-verge" "$DIR/tailscale-verge.sh" || return 1
    echo 'Service installed. Open Exit IP to import shared settings once. The service starts at every boot.'
)

uninstall_service() (
    require_root || return 1
    local app
    service_lock || return 1
    trap '/bin/rm -f "$DIR/Service/install.lock"' EXIT
    if [ -f "$DIR/installed-app" ]; then
        IFS= read -r app < "$DIR/installed-app"
        case "$app" in /*/ExitIPMonitor.app) ;; *) return 1 ;; esac
        source "$DIR/cleanup-installation.sh"
        cleanup_app=$app cleanup_uid=0 cleanup_translocations="" cleanup_matches=()
        cleanup_stop_app || return 1
    fi
    unload "$LABEL" && unload "$LEGACY-http" && unload "$LEGACY" || return 1
    wait_legacy_workers || return 1
    if [ -n "${app:-}" ]; then
        cleanup_find_processes || return 1
        [ "${#cleanup_matches[@]}" = 0 ] || { echo 'App restarted during removal. Quit it and retry.' >&2; return 1; }
    fi
    /bin/rm -f "$PLIST" "$EXECUTABLE" "/Library/LaunchDaemons/$LEGACY.plist" "/Library/LaunchDaemons/$LEGACY-http.plist" || return 1
    /bin/rm -f "$DIR/TailscaleVerge/provider.yaml" "$DIR/TailscaleVerge/state" "$DIR/tailscale-verge.sh" || return 1
    /bin/rm -f "$GRANT" "/etc/sudoers.d/exitipmonitor-tailscale-verge" "$MANAGER" || return 1
    echo 'Service removed. Shared settings, credentials, profiles and logs were retained.'
)

main() {
    [ "$#" = 1 ] || return 2
    case "$1" in
        install) install_service ;;
        remove|uninstall) uninstall_service ;;
        status) /bin/launchctl print "system/$LABEL" ;;
        *) echo 'Usage: daemon.sh install | status | uninstall' >&2; return 2 ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
