#!/usr/bin/env bash
# Removes WoW Forever Bots from this Mac: everything macos/install.sh and macos/build.sh put there.
#
#   macos/uninstall.sh          asks before each part
#   macos/uninstall.sh --yes    removes everything without asking (Homebrew packages too, if this project installed them)
#
#   1. stops the server (and its tmux session)
#   2. the game: removes the patched copy "... (Forever).app", puts the official settings and cache back,
#      removes the ForeverBots add-on (the original game app is never touched)
#   3. MySQL: drops the databases auth, characters, world, hotfixes, playerbot and the user trinity
#   4. the login certificate (System keychain) and the line "trinity.actual.battle.net" in /etc/hosts
#   5. the Desktop icon "WoW Forever Bots.command"
#   6. ~/WoWForever (server, maps, source, build, settings, backups; asks whether to keep the backups)
#   7. the Homebrew packages this project installed (mysql, tmux, 7-Zip, ...) and their leftovers (brew autoremove)
# Homebrew itself stays.
set -euo pipefail

# this script lives inside ~/WoWForever/app, which it deletes: run from a temporary copy
if [ -z "${WOWF_UNINSTALL_COPY:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tmp="$(mktemp -d)"
    cp -R "$here" "$tmp/macos"
    export WOWF_UNINSTALL_COPY="$tmp" WOWF_UNINSTALL_FROM="$here"
    exec /bin/bash "$tmp/macos/uninstall.sh" "$@"
fi
trap 'rm -rf "$WOWF_UNINSTALL_COPY"' EXIT
. "$WOWF_UNINSTALL_COPY/macos/lib.sh"
WOWF_REPO="$(cd "$WOWF_UNINSTALL_FROM/.." 2>/dev/null && pwd || echo "$WOWF_UNINSTALL_COPY")"

YES=0
case "${1:-}" in
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    "") ;;
    *) die "Unknown option: $1" ;;
esac
sure() { [ $YES -eq 1 ] && return 0; ask_yes "$1" "${2:-y}"; }

require_macos
load_brew_env >/dev/null 2>&1 || true

say "${C_B}WoW Forever Bots: uninstall${C_0}"
say "Removes the server, its databases, the certificate, the hosts line, the add-on, the patched game copy and $WOWF_HOME."
sure "Continue?" n || exit 0

# --- 1. server ------------------------------------------------------------------------------------------------------
step "1/7 Server"
if [ -x "$WOWF_REPO/macos/wowforever.sh" ] && { world_running || bnet_running; }; then
    "$WOWF_REPO/macos/wowforever.sh" stop || true
fi
for p in worldserver bnetserver; do
    pid="$(pid_of "$p" 2>/dev/null || true)"; [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
done
command -v tmux >/dev/null 2>&1 && tmux kill-session -t "$WOWF_TMUX_SESSION" 2>/dev/null || true
ok "Stopped"

# --- 2. game client -------------------------------------------------------------------------------------------------
step "2/7 Game client"
if [ -n "${WOWF_CLIENT:-}" ] && [ -d "$WOWF_CLIENT" ]; then
    if [ -f "$WOWF_UNINSTALL_COPY/macos/forever_client.py" ]; then
        WOWF_HOME="$WOWF_HOME" python3 -I "$WOWF_UNINSTALL_COPY/macos/forever_client.py" remove --client "$WOWF_CLIENT" \
            || warn "Could not remove the patched copy (quit the game and run this again)."
    fi
    fl="$(client_flavor "$WOWF_CLIENT" || true)"
    if [ -n "$fl" ] && [ -d "$WOWF_CLIENT/$fl/Interface/AddOns/ForeverBots" ]; then
        rm -rf "$WOWF_CLIENT/$fl/Interface/AddOns/ForeverBots"; ok "Add-on removed"
    fi
else
    say "No game folder recorded: nothing to do"
fi

# --- 3. MySQL -------------------------------------------------------------------------------------------------------
step "3/7 Databases"
if command -v mysql >/dev/null 2>&1; then
    if sure "Delete the databases auth, characters, world, hotfixes, playerbot (all characters and accounts)?" y; then
        ensure_mysql
        mysql_admin -e "DROP DATABASE IF EXISTS auth; DROP DATABASE IF EXISTS characters; DROP DATABASE IF EXISTS world;
            DROP DATABASE IF EXISTS hotfixes; DROP DATABASE IF EXISTS playerbot;
            DROP USER IF EXISTS 'trinity'@'localhost'; DROP USER IF EXISTS 'trinity'@'127.0.0.1';"
        ok "Databases and the user trinity removed"
    fi
else
    say "MySQL is not installed: nothing to do"
fi

# --- 4. certificate + hosts -----------------------------------------------------------------------------------------
step "4/7 Certificate and hosts (macOS asks for your password)"
kc=/Library/Keychains/System.keychain
n=0
while security find-certificate -c "WoW Forever Bots local CA" "$kc" >/dev/null 2>&1; do
    sudo security delete-certificate -c "WoW Forever Bots local CA" "$kc" >/dev/null || break
    n=$((n + 1)); [ $n -gt 20 ] && break
done
ok "Certificates removed: $n"
if grep -qE "[[:space:]]${WOWF_LOGIN_HOST//./\\.}([[:space:]]|$)" /etc/hosts; then
    sudo cp /etc/hosts "/etc/hosts.wowforever-backup"
    grep -vE "^[[:space:]]*[0-9.]+[[:space:]]+${WOWF_LOGIN_HOST//./\\.}([[:space:]]|$)" /etc/hosts > "$WOWF_UNINSTALL_COPY/hosts" || true
    sudo cp "$WOWF_UNINSTALL_COPY/hosts" /etc/hosts
    sudo dscacheutil -flushcache 2>/dev/null || true; sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "/etc/hosts: $WOWF_LOGIN_HOST removed (old file: /etc/hosts.wowforever-backup)"
else
    say "/etc/hosts has no $WOWF_LOGIN_HOST line"
fi

# --- 5. Desktop icon ------------------------------------------------------------------------------------------------
step "5/7 Desktop icon"
rm -f "$HOME/Desktop/WoW Forever Bots.command"; ok "Removed"

# --- 6. ~/WoWForever ------------------------------------------------------------------------------------------------
step "6/7 $WOWF_HOME"
BREW_ADDED="${WOWF_BREW_ADDED:-}"   # read before the settings file goes
if [ -d "$WOWF_HOME" ]; then
    if [ -d "$WOWF_BACKUPS" ] && [ -n "$(ls -A "$WOWF_BACKUPS" 2>/dev/null)" ] && [ $YES -eq 0 ] \
       && ask_yes "Keep the database backups (moved to ~/WoWForever-backups)?" n; then
        rm -rf "$HOME/WoWForever-backups"; mv "$WOWF_BACKUPS" "$HOME/WoWForever-backups"
        ok "Backups kept: ~/WoWForever-backups"
    fi
    rm -rf "$WOWF_HOME"
    ok "Removed $WOWF_HOME"
fi

# --- 7. Homebrew packages -------------------------------------------------------------------------------------------
step "7/7 Homebrew packages"
if command -v brew >/dev/null 2>&1; then
    if [ -n "$BREW_ADDED" ]; then
        pk="$BREW_ADDED"; say "Installed by this project: $pk"; def=y
    else
        pk="openssl@3 mysql tmux sevenzip"
        say "Not recorded which packages this project installed. Usual ones: $pk"
        say "(other programs may use them too; openssl@3 is kept, it is needed by much of Homebrew)"
        pk="mysql tmux sevenzip"; def=n
    fi
    if sure "Uninstall: $pk?" $def; then
        case " $pk " in *" mysql "*)
            brew services stop mysql >/dev/null 2>&1 || true ;;
        esac
        # shellcheck disable=SC2086
        for p in $pk; do brew list --formula "$p" >/dev/null 2>&1 && brew uninstall --ignore-dependencies "$p" || true; done
        brew autoremove || true
        case " $pk " in *" mysql "*)
            d="$(brew --prefix)/var/mysql"
            if [ -d "$d" ] && sure "Also delete MySQL's data folder $d (all MySQL databases on this Mac)?" n; then
                rm -rf "$d"; ok "Removed $d"
            fi ;;
        esac
        ok "Packages removed"
    fi
fi

say ""
ok "WoW Forever Bots is removed. The downloaded archive (if you still have it) can go to the Trash."
