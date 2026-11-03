#!/usr/bin/env bash
# WoW Forever Bots on macOS: the server menu (what WoW-Forever-Bots.cmd is in the Windows repack).
#
#   macos/wowforever.sh               the menu
#   macos/wowforever.sh start         start the server (bnetserver + worldserver)
#   macos/wowforever.sh stop          shut the server down (saves everything)
#   macos/wowforever.sh autorestart   start with auto-restart: worldserver and bnetserver come back if they crash
#   macos/wowforever.sh update        back up the databases, pull the newest version, rebuild, keep your characters
#   macos/wowforever.sh account       create a game account (name@local, optionally GM)
#   macos/wowforever.sh status        what runs
#   macos/wowforever.sh console       the worldserver console (leave it with Ctrl+B, then D)
#   macos/wowforever.sh logs          follow Server.log and Playerbot.log
#   macos/wowforever.sh addon         install / refresh the add-on in the game folder
#   macos/wowforever.sh backup        back up the databases now
#   macos/wowforever.sh discord       open our Discord
#   macos/wowforever.sh play          play with the macOS game client (starts the server if needed)
#   macos/wowforever.sh client scout|patch|restore|remove|status   the macOS client copy (macos/forever_client.py)
#   macos/wowforever.sh uninstall     remove everything again (macos/uninstall.sh)
#
# The servers run in a tmux session called "wowforever" (windows "world" and "bnet"), so they keep running when the
# Terminal window is closed; the Mac is kept awake while worldserver runs.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_brew_env >/dev/null 2>&1 || true
AUTORESTART_FLAG="$WOWF_HOME/.autorestart"
STOP_FLAG="$WOWF_HOME/.stopping"

need_install() {
    [ -x "$WOWF_BIN/worldserver" ] && [ -f "$WOWF_ETC/worldserver.conf" ] \
        || die "Not installed yet. Run macos/install.sh first."
}

tmux_has() { tmux has-session -t "$WOWF_TMUX_SESSION" 2>/dev/null; }
tmux_window() { tmux list-windows -t "$WOWF_TMUX_SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; }
world_console() {   # world_console "command": types a command into the worldserver console
    tmux_window world || return 1
    tmux send-keys -t "$WOWF_TMUX_SESSION:world" -l -- "$1"
    tmux send-keys -t "$WOWF_TMUX_SESSION:world" Enter
}

# A program in a loop: exit code 2 (".server restart") always comes back; any other code other than 0 comes back while
# auto-restart is on. A stop from this menu (the stop flag) never comes back.
loop_cmd() {   # loop_cmd <name> <program and args...>
    local name="$1"; shift
    cat <<EOF
sleep 1   # lets tmux pipe-pane attach first, so the console log has everything
cd "$WOWF_BIN" || exit 1
ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true
while true; do
    caffeinate -i $* ; code=\$?
    [ -f "$STOP_FLAG" ] && break
    if [ \$code -eq 2 ] || { [ \$code -ne 0 ] && [ -f "$AUTORESTART_FLAG" ]; }; then
        echo "\$(date '+%F %T') $name stopped (exit \$code), restarting in 5 seconds" | tee -a "$WOWF_LOGS/restarts.log"
        sleep 5; continue
    fi
    break
done
echo; echo "$name stopped (exit \$code). This window closes in 30 seconds."; sleep 30
EOF
}

wait_world_ready() {   # waits until worldserver logged "ready..." after the given log size
    local log="$WOWF_LOGS/Server.log" from="${1:-0}" i
    for i in $(seq 1 1800); do
        if [ -f "$log" ] && tail -c +"$((from + 1))" "$log" 2>/dev/null | grep -q '(worldserver-daemon) ready'; then return 0; fi
        world_running || return 1
        if [ $((i % 30)) -eq 0 ]; then
            local last; last="$(tail -n 1 "$log" 2>/dev/null | cut -c1-110)"
            say "  still starting ($((i / 60)) min): ${last}"
        fi
        sleep 1
    done
    return 1
}

cmd_start() {
    need_install
    ensure_mysql
    rm -f "$STOP_FLAG"
    if world_running && bnet_running; then ok "The server is already running."; return 0; fi
    [ -f "$WOWF_DATA/.extract-mmaps.done" ] || [ -d "$WOWF_DATA/mmaps" ] \
        || warn "No bot pathing (mmaps) in $WOWF_DATA: the bots cannot walk. Run macos/install.sh to extract it."
    mkdir -p "$WOWF_LOGS"
    local log_size=0
    [ -f "$WOWF_LOGS/Server.log" ] && log_size=$(wc -c < "$WOWF_LOGS/Server.log" | tr -d ' ')
    local wrun="$WOWF_HOME/.run-worldserver.sh" brun="$WOWF_HOME/.run-bnetserver.sh"
    mkdir -p "$WOWF_ETC/worldserver.conf.d" "$WOWF_ETC/bnetserver.conf.d"
    # --config-dir: a ready-made server was built elsewhere, so its built-in default folder is not this Mac's
    loop_cmd worldserver "./worldserver -c \"$WOWF_ETC/worldserver.conf\" --config-dir \"$WOWF_ETC/worldserver.conf.d\"" > "$wrun"
    loop_cmd bnetserver "./bnetserver -c \"$WOWF_ETC/bnetserver.conf\" --config-dir \"$WOWF_ETC/bnetserver.conf.d\"" > "$brun"
    if ! tmux_has; then
        tmux new-session -d -s "$WOWF_TMUX_SESSION" -n world -x 200 -y 50 "bash \"$wrun\""
        tmux set-option -t "$WOWF_TMUX_SESSION" history-limit 20000 >/dev/null
    elif ! world_running; then
        tmux_window world && tmux kill-window -t "$WOWF_TMUX_SESSION:world"
        tmux new-window -d -t "$WOWF_TMUX_SESSION" -n world "bash \"$wrun\""
    fi
    if ! bnet_running; then
        tmux_window bnet && tmux kill-window -t "$WOWF_TMUX_SESSION:bnet"
        tmux new-window -d -t "$WOWF_TMUX_SESSION" -n bnet "bash \"$brun\""
    fi
    # everything the programs print (also what happens before their own logs open: missing libraries, config errors)
    local w
    for w in world bnet; do
        tmux pipe-pane -o -t "$WOWF_TMUX_SESSION:$w" "cat >> '$WOWF_LOGS/$w-console.log'" 2>/dev/null || true
    done
    info "Starting worldserver (the first start imports the world database and makes the bot roster: that can take long)"
    sleep 2
    if wait_world_ready "$log_size"; then
        ok "Server ready. Log in with <name>@local, realm Trinity."
        [ -f "$AUTORESTART_FLAG" ] && say "Auto-restart is on."
    else
        if ! world_running; then
            warn "worldserver stopped. Last lines of Server.log:"; tail -n 25 "$WOWF_LOGS/Server.log" 2>/dev/null || true
            warn "Last lines of its console ($WOWF_LOGS/world-console.log):"; tail -n 25 "$WOWF_LOGS/world-console.log" 2>/dev/null || true
            return 1
        fi
        warn "worldserver is still starting; look with: macos/wowforever.sh console"
    fi
    bnet_running || warn "bnetserver is not running: see $WOWF_LOGS/Bnet.log (often the hosts line or the certificate)."
}

cmd_autorestart() {
    touch "$AUTORESTART_FLAG"
    ok "Auto-restart on: the servers come back by themselves if they crash (Stop turns it off again)."
    cmd_start
}

cmd_stop() {
    rm -f "$AUTORESTART_FLAG"
    touch "$STOP_FLAG"
    if world_running; then
        info "Shutting worldserver down (saves all characters)"
        world_console "server shutdown 1" || kill -TERM "$(pid_of worldserver)" 2>/dev/null || true
        local i
        for i in $(seq 1 180); do world_running || break; sleep 1; done
        if world_running; then warn "worldserver did not stop in 3 minutes; stopping it hard"; kill -TERM "$(pid_of worldserver)" 2>/dev/null || true; sleep 5; fi
    fi
    if bnet_running; then kill -TERM "$(pid_of bnetserver)" 2>/dev/null || true; sleep 1; fi
    tmux_has && tmux kill-session -t "$WOWF_TMUX_SESSION" 2>/dev/null || true
    ok "Server stopped."
}

cmd_status() {
    if world_running; then ok "worldserver runs (pid $(pid_of worldserver))"; else say "worldserver: stopped"; fi
    if bnet_running;  then ok "bnetserver runs (pid $(pid_of bnetserver))";   else say "bnetserver: stopped"; fi
    if mysql_running; then ok "MySQL runs"; else say "MySQL: stopped"; fi
    [ -f "$AUTORESTART_FLAG" ] && say "Auto-restart: on" || say "Auto-restart: off"
    say "Installed: ${WOWF_INSTALLED:-no}   built from: ${WOWF_BUILT_FROM:-?}   game folder: ${WOWF_CLIENT:-?}"
}

cmd_backup() {
    ensure_mysql
    mysql_admin -e "SELECT 1" >/dev/null   # asks for the root password if you set one
    local dir db
    dir="$WOWF_BACKUPS/$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$dir"
    info "Backing up auth, characters and playerbot into $dir"
    for db in auth characters playerbot; do
        mysqldump -uroot --single-transaction --routines --triggers --events --hex-blob --no-tablespaces "$db" \
            | gzip > "$dir/$db.sql.gz" || die "Backup of $db failed"
    done
    ok "Backup: $dir"
}

# Release download: fetch the newest release of the repository it came from (prebuilt/VERSION, repo=...).
update_release() {
    local repo cur api tag url tmp asset
    repo="$(grep '^repo=' "$WOWF_REPO/prebuilt/VERSION" | cut -d= -f2)"
    cur="$(grep '^version=' "$WOWF_REPO/prebuilt/VERSION" | cut -d= -f2)"
    [ -n "$repo" ] || die "No repo= line in $WOWF_REPO/prebuilt/VERSION."
    api="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")" || die "Cannot reach GitHub ($repo)."
    tag="$(printf '%s' "$api" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
    url="$(printf '%s' "$api" | sed -nE "s#^[[:space:]]*\"browser_download_url\":[[:space:]]*\"([^\"]*macOS-$(uname -m)-[^\"]*\\.tar\\.gz)\".*#\\1#p" | head -1)"
    [ -n "$tag" ] && [ -n "$url" ] || die "The newest release of $repo has no macOS $(uname -m) download."
    if [ "$tag" = "$cur" ]; then ok "You have the newest version ($cur)."; return 1; fi
    info "Downloading $tag (you have $cur)"
    tmp="$(mktemp -d)"; asset="$tmp/$(basename "$url")"
    curl -fL --retry 4 -o "$asset" "$url" || die "Download failed: $url"
    if curl -fsSL -o "$asset.sha256" "$url.sha256"; then
        ( cd "$tmp" && shasum -a 256 -c "$(basename "$asset").sha256" >/dev/null ) || die "The download is damaged (checksum)."
    fi
    tar -xzf "$asset" -C "$tmp"
    [ -x "$tmp/WoWForeverBots/prebuilt/server/bin/worldserver" ] || die "The download has no server in it."
    rsync -a --delete --filter 'P sql/custom/world/2026_10_12_5*_world_classic_vanilla_*.sql' \
        "$tmp/WoWForeverBots/" "$WOWF_REPO/"
    rm -rf "$tmp"
    ok "Version $tag unpacked into $WOWF_REPO"
}

cmd_update() {
    need_install
    local was_running=0
    world_running && was_running=1
    if [ -d "$WOWF_REPO/prebuilt" ]; then
        # check first, stop the server only when there is something new
        local tmpcheck; tmpcheck="$(curl -fsSL "https://api.github.com/repos/$(grep '^repo=' "$WOWF_REPO/prebuilt/VERSION" | cut -d= -f2)/releases/latest" 2>/dev/null \
            | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
        if [ -n "$tmpcheck" ] && [ "$tmpcheck" = "$(grep '^version=' "$WOWF_REPO/prebuilt/VERSION" | cut -d= -f2)" ]; then
            ok "You have the newest version ($tmpcheck)."; return 0
        fi
        [ $was_running -eq 1 ] && cmd_stop
        cmd_backup
        update_release || { [ $was_running -eq 1 ] && cmd_start; return 0; }
    else
        [ $was_running -eq 1 ] && cmd_stop
        cmd_backup
        if [ -d "$WOWF_REPO/.git" ]; then
            info "Pulling the newest version ($WOWF_REPO)"
            git -C "$WOWF_REPO" pull --ff-only || die "git pull failed (local changes?). Nothing was changed; your backup is in $WOWF_BACKUPS."
        else
            warn "$WOWF_REPO is not a git checkout; building what is there."
        fi
    fi
    "$WOWF_REPO/macos/build.sh" --skip-deps
    "$WOWF_REPO/macos/install.sh" --configs-only
    "$WOWF_REPO/macos/install-addon.sh" --client "${WOWF_CLIENT:-}" || warn "Add-on not refreshed."
    ok "Updated. New SQL is applied by worldserver on its next start."
    if [ $was_running -eq 1 ]; then cmd_start; fi
}

cmd_account() {
    need_install
    world_running && tmux_window world || die "Start the server first (menu 1)."
    local name pass pass2 gm=0 count id
    printf 'Account name (letters and digits, your login becomes name@local): '
    read -r name
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    case "$name" in ""|*[!A-Za-z0-9_.-]*) die "Use letters, digits, '.', '-' or '_' only." ;; esac
    printf 'Password (at most 16 characters, no spaces): '; stty -echo; read -r pass; stty echo; printf '\n'
    printf 'Password again: '; stty -echo; read -r pass2; stty echo; printf '\n'
    [ "$pass" = "$pass2" ] || die "The passwords differ."
    case "$pass" in ""|*" "*) die "Empty or with a space." ;; esac
    [ ${#pass} -le 16 ] || die "At most 16 characters."
    local email; email="$(printf '%s@local' "$name" | tr '[:lower:]' '[:upper:]')"
    count="$(mysql_game -N auth -e "SELECT COUNT(*) FROM battlenet_accounts" || echo 1)"
    if [ "$(mysql_game -N auth -e "SELECT COUNT(*) FROM battlenet_accounts WHERE email='$email'")" != "0" ]; then
        die "$name@local exists already."
    fi
    if [ "$count" = "0" ]; then
        gm=1; say "This is the first account, so it becomes a game master."
    elif ask_yes "Make it a game master (needed for the .bot commands and the add-on window)?" y; then
        gm=1
    fi
    world_console "bnetaccount create $name@local $pass"
    local i
    for i in $(seq 1 20); do
        id="$(mysql_game -N auth -e "SELECT id FROM battlenet_accounts WHERE email='$email'")"
        [ -n "$id" ] && break
        sleep 1
    done
    [ -n "${id:-}" ] || die "The account was not created; look at the console (macos/wowforever.sh console)."
    if [ $gm -eq 1 ]; then
        world_console "account set gmlevel ${id}#1 3 -1"
        sleep 2
    fi
    ok "Account $name@local created$([ $gm -eq 1 ] && echo ' (game master)'). Log in with $name@local, realm Trinity."
}

cmd_console() {
    tmux_has || die "The server is not running."
    say "Leave the console with Ctrl+B, then D (the server keeps running)."
    sleep 1
    tmux attach -t "$WOWF_TMUX_SESSION:world"
}

cmd_logs() {
    say "Ctrl+C stops watching (the server keeps running)."
    touch "$WOWF_LOGS/Server.log"
    tail -n 40 -F "$WOWF_LOGS/Server.log" "$WOWF_LOGS/Playerbot.log" 2>/dev/null
}

# The macOS game client: macos/forever_client.py patches a copy of the app (the original is never changed) and swaps
# in Forever's own Config.wtf and Cache while you play.
client_tool() {
    local py=/usr/bin/python3
    command -v python3 >/dev/null 2>&1 && py="$(command -v python3)"
    "$py" -I "$WOWF_REPO/macos/forever_client.py" "$@" ${WOWF_CLIENT:+--client "$WOWF_CLIENT"}
}

cmd_play() {
    need_install
    if ! world_running || ! bnet_running; then cmd_start; fi
    client_tool play \
        || die "The game did not start. 'macos/wowforever.sh client scout' writes a report (~/WoWForever/client-scout.json) to send us."
}

cmd_menu() {
    while true; do
        printf '\n%s WoW Forever Bots (macOS) %s\n' "$C_B" "$C_0"
        if world_running; then printf '  server: %srunning%s' "$C_G" "$C_0"; else printf '  server: stopped'; fi
        [ -f "$AUTORESTART_FLAG" ] && printf ' (auto-restart)'
        printf '\n\n'
        say "  1  Start server"
        say "  2  Shut down server"
        say "  3  Auto-restart (restarts it if it crashes)"
        say "  4  Update (installs the newest version, keeps your characters)"
        say "  5  Create account"
        say "  6  Join our Discord"
        say "  7  Console          8  Logs          9  Status"
        say "  A  Install / refresh the add-on      B  Back up the databases"
        say "  P  Play with the macOS game client (the original app stays unchanged)"
        say "  Q  Quit (the server keeps running)"
        printf '\nChoice: '
        local c; read -r c || exit 0
        case "$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')" in
            1) ( cmd_start ) || true ;;
            2) ( cmd_stop ) || true ;;
            3) ( cmd_autorestart ) || true ;;
            4) ( cmd_update ) || true ;;
            5) ( cmd_account ) || true ;;
            6) open "$WOWF_DISCORD" ;;
            7) ( cmd_console ) || true ;;
            8) ( cmd_logs ) || true ;;
            9) cmd_status ;;
            A) ( "$WOWF_REPO/macos/install-addon.sh" ) || true ;;
            B) ( cmd_backup ) || true ;;
            P) ( cmd_play ) || true ;;
            Q|"") exit 0 ;;
            *) say "?" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)        cmd_menu ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    autorestart) cmd_autorestart ;;
    update)      cmd_update ;;
    account)     cmd_account ;;
    status)      cmd_status ;;
    console)     cmd_console ;;
    logs)        cmd_logs ;;
    addon)       shift; "$WOWF_REPO/macos/install-addon.sh" "$@" ;;
    backup)      cmd_backup ;;
    discord)     open "$WOWF_DISCORD" ;;
    play)        cmd_play ;;
    client)      shift; client_tool "${1:-status}" "${@:2}" ;;
    uninstall)   shift; exec "$WOWF_REPO/macos/uninstall.sh" "$@" ;;
    -h|--help)   sed -n '2,22p' "$0" ;;
    *)           die "Unknown command: $1 (see --help)" ;;
esac
