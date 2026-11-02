#!/usr/bin/env bash
# First-time setup of WoW Forever Bots on macOS (what Install.cmd does in the Windows repack):
#   builds the server if needed, finds your WoW Forever game folder, sets up MySQL and the databases, writes the configs,
#   makes a local login certificate and trusts it, adds the hosts line, extracts the maps from your own client
#   (10 to 20 minutes, can be resumed), installs the add-on, puts a "WoW Forever Bots" icon on the Desktop,
#   starts the server and offers to create your account.
#
#   macos/install.sh
#   macos/install.sh --client "/path/to/World of Warcraft"     the game folder (holds .build.info and _classic_beta_)
#   macos/install.sh --vanilla-dump world_full_14_june_2021.sql also build the vanilla (1.12) numbers from the VMaNGOS dump
#   macos/install.sh --configs-only                             only (re)write the configs; keeps your own settings
#   macos/install.sh --no-start                                 do not start the server at the end
#
# Safe to run again: every step checks what is already there and continues where it stopped.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLIENT_ARG=""; VANILLA_DUMP=""; CONFIGS_ONLY=0; NO_START=0
while [ $# -gt 0 ]; do
    case "$1" in
        --client)       CLIENT_ARG="$2"; shift 2 ;;
        --vanilla-dump) VANILLA_DUMP="$2"; shift 2 ;;
        --configs-only) CONFIGS_ONLY=1; shift ;;
        --no-start)     NO_START=1; shift ;;
        -h|--help)      sed -n '2,13p' "$0"; exit 0 ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
done

require_macos
case "$WOWF_HOME" in *" "*) die "WOWF_HOME must not contain spaces: $WOWF_HOME" ;; esac
mkdir -p "$WOWF_HOME"
save_env WOWF_HOME "$WOWF_HOME"

# --- server programs ------------------------------------------------------------------------------------------------
if [ ! -x "$WOWF_BIN/worldserver" ] || [ ! -x "$WOWF_BIN/bnetserver" ]; then
    step "The server is not built yet"
    "$WOWF_REPO/macos/build.sh"
fi
load_brew_env || die "Homebrew not found (macos/build.sh installs it)."

# ===================================================================================================================
# configs
# ===================================================================================================================
write_configs() {
    step "Configs ($WOWF_ETC)"
    local bnet="$WOWF_ETC/bnetserver.conf" world="$WOWF_ETC/worldserver.conf" confd="$WOWF_ETC/worldserver.conf.d"
    [ -f "$bnet" ]  || cp "$WOWF_ETC/bnetserver.conf.dist" "$bnet"
    [ -f "$world" ] || cp "$WOWF_ETC/worldserver.conf.dist" "$world"
    mkdir -p "$WOWF_LOGS" "$WOWF_DATA" "$confd"

    local mysql_bin; mysql_bin="$(command -v mysql)"

    # bnetserver: local only (like the repack); the client is always told the hostname the certificate is made for.
    setkey "$bnet" LoginDatabaseInfo "\"127.0.0.1;3306;trinity;$WOWF_DB_PASS;auth\""
    setkey "$bnet" BindIP '"127.0.0.1"'
    setkey "$bnet" LoginREST.ExternalAddress "$WOWF_LOGIN_HOST"
    setkey "$bnet" LoginREST.LocalAddress "$WOWF_LOGIN_HOST"
    setkey "$bnet" CertificatesFile "\"$WOWF_CERTS/forever.cert.pem\""
    setkey "$bnet" PrivateKeyFile "\"$WOWF_CERTS/forever.key.pem\""
    setkey "$bnet" LogsDir "\"$WOWF_LOGS\""
    setkey "$bnet" Realm.CfgContentSetID 137
    setkey "$bnet" Realm.SuperDistrictID 2

    # worldserver: the Classic client requirements (advocaite's README), this machine's folders, the updater on.
    local db
    for db in Login:auth World:world Character:characters Hotfix:hotfixes; do
        setkey "$world" "${db%%:*}DatabaseInfo" "\"127.0.0.1;3306;trinity;$WOWF_DB_PASS;${db##*:}\""
    done
    setkey "$world" RealmID 70
    setkey "$world" Expansion 0
    setkey "$world" BindIP '"127.0.0.1"'
    setkey "$world" DataDir "\"$WOWF_DATA\""
    setkey "$world" LogsDir "\"$WOWF_LOGS\""
    setkey "$world" SourceDirectory "\"$WOWF_SRC\""
    setkey "$world" BuildDirectory "\"$WOWF_BUILD\""
    setkey "$world" MySQLExecutable "\"$mysql_bin\""
    setkey "$world" Network.SkipBuildAuthKeyCheck 1
    setkey "$world" Network.EnterEncryptedModeRegionGroup 8
    setkey "$world" Realm.CfgContentSetID 137
    setkey "$world" Realm.SuperDistrictID 2
    setkey "$world" Updates.EnableDatabases 15
    setkey "$world" Updates.AutoSetup 1
    setkey "$world" mmap.enablePathFinding 1          # the bots walk on the mmaps
    setkey "$world" Console.Enable 1                  # the menu sends commands to the console (tmux)
    setkey "$world" Logger.sql.sql 5,DBErrors         # about a million harmless DB warnings: file only
    setkey "$world" Ra.Enable 0
    setkey "$world" SOAP.Enabled 0
    # same gameplay settings as the repack
    setkey "$world" Classic.GuildFinder 1
    setkey "$world" Classic.Shop.Enabled 1
    setkey "$world" AccountInstancesPerHour 5
    setkey "$world" PlayerSave.Stats.MinLevel 1

    # the bots: playerbot.conf from its .dist (the build already put zz-0-playerbot-defaults.conf, zz-forever-bots.conf
    # and zz-forever-lfg.conf there). Your own changes go into a later file such as zz-9-local.conf.
    if [ ! -f "$confd/playerbot.conf" ] && [ -f "$confd/playerbot.conf.dist" ]; then
        cp "$confd/playerbot.conf.dist" "$confd/playerbot.conf"
    fi
    [ -f "$confd/playerbot.conf" ] || warn "No playerbot.conf in $confd (was the server built with the bots?)"

    # Smaller Macs: fewer world bots (the defaults are made for a 32 GB PC). Only written once; edit or delete it freely.
    local local_conf="$confd/zz-9-local.conf" gb; gb="$(ram_gb)"
    if [ ! -f "$local_conf" ]; then
        {
            echo "# Your own settings (read after the other files in this folder). Made by macos/install.sh for a ${gb} GB Mac."
            if [ "$gb" -lt 16 ]; then
                echo "Playerbot.World.MaxBots = 100"
                echo "Playerbot.World.GlobalFill = 0"
            fi
        } > "$local_conf"
    fi
    chmod 600 "$bnet" "$world"
    ok "bnetserver.conf, worldserver.conf, worldserver.conf.d/"
}

# ===================================================================================================================
# MySQL + databases
# ===================================================================================================================
setup_databases() {
    step "MySQL and databases"
    ensure_mysql
    if [ -z "${WOWF_DB_PASS:-}" ]; then
        save_env WOWF_DB_PASS "$(openssl rand -hex 16)"
    fi
    local p="$WOWF_DB_PASS" db h
    for h in localhost 127.0.0.1; do
        mysql_admin -e "CREATE USER IF NOT EXISTS 'trinity'@'$h' IDENTIFIED BY '$p'; ALTER USER 'trinity'@'$h' IDENTIFIED BY '$p';"
    done
    for db in auth characters world hotfixes; do
        # created empty here, so worldserver's auto-setup fills them without asking questions on its first start
        mysql_admin -e "CREATE DATABASE IF NOT EXISTS \`$db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    done
    if [ "$(mysql_admin -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='playerbot'")" = "0" ]; then
        info "Bot database (playerbot): schema and data"
        mysql_admin < "$WOWF_REPO/sql/playerbot_shared/playerbot_shared_schema.sql"
        mysql_admin playerbot < "$WOWF_REPO/sql/playerbot_shared/playerbot_shared_data.sql"
    fi
    for h in localhost 127.0.0.1; do
        for db in auth characters world hotfixes playerbot; do
            mysql_admin -e "GRANT ALL PRIVILEGES ON \`$db\`.* TO 'trinity'@'$h';"
        done
    done
    mysql_admin -e "FLUSH PRIVILEGES;"
    mysql_game -e "SELECT 1" >/dev/null || die "The database user trinity cannot log in."
    ok "MySQL user trinity; databases auth, characters, world, hotfixes, playerbot"

    # the Forever world + hotfixes release, imported by worldserver on its first start (it looks in the folder it starts in)
    local need=0 f
    for f in $WOWF_TDB_FILES; do [ -f "$WOWF_BIN/$f" ] || need=1; done
    if [ $need -eq 1 ] && [ "$(mysql_admin -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='world'")" = "0" ]; then
        info "Downloading the Forever world database (about 150 MB)"
        local z; z="$WOWF_BIN/$(basename "$WOWF_TDB_URL")"
        if [ ! -f "$z" ]; then
            curl -fL --retry 4 -o "$z.part" "$WOWF_TDB_URL" || die "Download failed: $WOWF_TDB_URL"
            mv -f "$z.part" "$z"
        fi
        local sz; sz="$(command -v 7zz || command -v 7z || true)"
        [ -n "$sz" ] || die "7-Zip is missing (brew install sevenzip)."
        local unpack="$WOWF_BIN/.tdb-unpack"
        rm -rf "$unpack"; mkdir -p "$unpack"
        ( cd "$unpack" && "$sz" x -y "$z" >/dev/null ) || die "Could not unpack $z"
        for f in $WOWF_TDB_FILES; do
            local hit; hit="$(find "$unpack" -name "$f" -type f | head -1)"
            [ -n "$hit" ] || die "$f is not in $(basename "$z")"
            mv -f "$hit" "$WOWF_BIN/$f"
        done
        rm -rf "$unpack" "$z"
        ok "World database release unpacked into $WOWF_BIN"
    fi
}

# ===================================================================================================================
# login certificate + hosts line
# ===================================================================================================================
setup_certificate() {
    step "Login certificate ($WOWF_LOGIN_HOST)"
    mkdir -p "$WOWF_CERTS"; chmod 700 "$WOWF_CERTS"
    local ca="$WOWF_CERTS/forever_root_ca.crt"
    if [ ! -f "$WOWF_CERTS/forever.cert.pem" ] || [ ! -f "$WOWF_CERTS/forever.key.pem" ] || [ ! -f "$ca" ]; then
        # Our own root CA for this Mac only, limited to *.actual.battle.net. Its key is deleted after it signed the
        # server certificate, so nobody can make another certificate with it.
        local tmp; tmp="$(mktemp -d)"
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -keyout "$tmp/ca.key" -out "$ca" \
            -subj "/CN=WoW Forever Bots local CA ($(scutil --get LocalHostName 2>/dev/null || hostname -s))" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "nameConstraints=critical,permitted;DNS:actual.battle.net" 2>/dev/null
        openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$WOWF_CERTS/forever.key.pem" -out "$tmp/server.csr" \
            -subj "/CN=$WOWF_LOGIN_HOST" 2>/dev/null
        cat > "$tmp/ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$WOWF_LOGIN_HOST
EOF
        # 825 days: the longest a certificate from a user-trusted root may live on Apple systems
        openssl x509 -req -in "$tmp/server.csr" -CA "$ca" -CAkey "$tmp/ca.key" -CAcreateserial -days 825 -sha256 \
            -extfile "$tmp/ext.cnf" -out "$tmp/server.crt" 2>/dev/null
        cat "$tmp/server.crt" "$ca" > "$WOWF_CERTS/forever.cert.pem"
        rm -rf "$tmp"
        chmod 600 "$WOWF_CERTS/forever.key.pem"
        ok "Made a new certificate"
    fi
    if security verify-cert -c "$WOWF_CERTS/forever.cert.pem" -p ssl -s "$WOWF_LOGIN_HOST" >/dev/null 2>&1; then
        ok "This Mac trusts the login certificate"
    else
        info "Trusting the local CA in the System keychain (macOS asks for your password)"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca" \
            || warn "Could not trust $ca. Double-click it in Finder, then Keychain Access > Trust > Always Trust."
    fi
}

setup_hosts() {
    step "Hosts line ($WOWF_LOGIN_HOST)"
    if grep -qE "^[[:space:]]*[0-9.]+[[:space:]]+([^#]*[[:space:]])?${WOWF_LOGIN_HOST//./\\.}([[:space:]]|$)" /etc/hosts; then
        ok "/etc/hosts already has $WOWF_LOGIN_HOST"
    else
        info "Adding 127.0.0.1 $WOWF_LOGIN_HOST to /etc/hosts (macOS asks for your password)"
        printf '\n127.0.0.1 %s   # WoW Forever Bots\n' "$WOWF_LOGIN_HOST" | sudo tee -a /etc/hosts >/dev/null
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        ok "Added"
    fi
}

# ===================================================================================================================
# game folder + maps
# ===================================================================================================================
is_client_dir() { [ -f "$1/.build.info" ] && { [ -d "$1/_classic_beta_" ] || ls "$1"/WowB*.exe >/dev/null 2>&1; }; }

find_client() {
    local roots=("$HOME/Applications" "/Applications" "$HOME/Games" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Documents"
                 "$HOME/Library/Application Support/CrossOver/Bottles"
                 "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles" "$HOME/.wine/drive_c" "/Volumes")
    local r
    for r in "${roots[@]}"; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 7 -name .build.info -type f 2>/dev/null | while read -r f; do
            d="$(dirname "$f")"
            is_client_dir "$d" && echo "$d"
        done
    done | awk '!seen[$0]++'
}

choose_client() {
    step "WoW Forever game folder (build $WOWF_CLIENT_BUILD)"
    local c="${CLIENT_ARG:-${WOWF_CLIENT:-}}"
    if [ -n "$c" ] && is_client_dir "$c"; then
        save_env WOWF_CLIENT "$(cd "$c" && pwd)"; ok "$WOWF_CLIENT"; return
    fi
    info "Looking for the game folder (the one with .build.info and _classic_beta_)..."
    local found first
    found="$(find_client)"
    # the folder of the right build first
    first="$(printf '%s\n' "$found" | while read -r d; do [ -n "$d" ] && grep -q "$WOWF_CLIENT_BUILD" "$d/.build.info" 2>/dev/null && echo "$d"; done | head -1)"
    [ -z "$first" ] && first="$(printf '%s\n' "$found" | head -1)"
    if [ -n "$first" ] && ask_yes "Use $first ?"; then
        c="$first"
    else
        c="$(osascript -e 'POSIX path of (choose folder with prompt "Select your WoW Forever game folder (the one that contains .build.info)")' 2>/dev/null || true)"
        c="${c%/}"
    fi
    [ -n "$c" ] || die "No game folder chosen. Run again with --client \"/path/to/the/folder\"."
    is_client_dir "$c" || die "$c has no .build.info and _classic_beta_ folder."
    grep -q "$WOWF_CLIENT_BUILD" "$c/.build.info" 2>/dev/null || warn "$c does not look like build $WOWF_CLIENT_BUILD."
    save_env WOWF_CLIENT "$(cd "$c" && pwd)"
    ok "$WOWF_CLIENT"
}

extract_maps() {
    step "Maps, vmaps and bot pathing (mmaps) from your own client"
    if [ -f "$WOWF_DATA/.extract-mmaps.done" ]; then ok "Already extracted ($WOWF_DATA)"; return; fi
    local free_gb; free_gb=$(( $(df -k "$WOWF_DATA" | awk 'NR==2{print $4}') / 1048576 ))
    [ "$free_gb" -ge 45 ] || warn "Only $free_gb GB free; the extraction needs about 45 GB while it works (about 2 GB stay)."
    say "This takes about 10 to 20 minutes on Apple Silicon. If it stops, run install.sh again: it continues."
    "$WOWF_REPO/tools/extract_client_data.sh" --client-path "$WOWF_CLIENT" --output-path "$WOWF_DATA" \
        --tools-path "$WOWF_BIN" --resume
}

# ===================================================================================================================
# optional: vanilla (1.12) numbers
# ===================================================================================================================
build_vanilla() {
    [ -n "$VANILLA_DUMP" ] || return 0
    step "Vanilla (1.12) numbers from $VANILLA_DUMP"
    [ -f "$VANILLA_DUMP" ] || die "Not found: $VANILLA_DUMP"
    local py
    if command -v uv >/dev/null 2>&1; then py="uv run --no-project python"; else py="python3"; fi
    # written into this checkout (sql/custom/world, ignored by git), so every later build copies them along
    $py "$WOWF_REPO/tools/classic_spell_values/build_vanilla_data.py" --dump "$VANILLA_DUMP"
    rsync -a "$WOWF_REPO/sql/custom/world/" "$WOWF_SRC/sql/custom/world/"
    ok "Vanilla SQL files written; worldserver applies them on its next start"
}

# ===================================================================================================================
# desktop icon
# ===================================================================================================================
make_shortcut() {
    local f="$HOME/Desktop/WoW Forever Bots.command"
    cat > "$f" <<EOF
#!/bin/bash
# WoW Forever Bots menu (made by macos/install.sh)
exec "$WOWF_REPO/macos/wowforever.sh"
EOF
    chmod +x "$f"
    ok "Desktop icon: $f (double-click opens the menu in Terminal)"
}

# ===================================================================================================================
setup_databases
setup_certificate
write_configs
[ $CONFIGS_ONLY -eq 1 ] && { ok "Configs written."; exit 0; }
setup_hosts
choose_client
build_vanilla
extract_maps
step "Add-on"
"$WOWF_REPO/macos/install-addon.sh" --client "$WOWF_CLIENT" || warn "The add-on was not installed (macos/install-addon.sh)."
make_shortcut
save_env WOWF_INSTALLED "$(date '+%Y-%m-%d')"

step "Done"
if [ $NO_START -eq 0 ]; then
    "$WOWF_REPO/macos/wowforever.sh" start
    if ask_yes "Create your game account now?"; then
        "$WOWF_REPO/macos/wowforever.sh" account
    fi
fi
say ""
say "${C_B}From now on:${C_0} double-click 'WoW Forever Bots' on the Desktop (or run macos/wowforever.sh)."
say "Start the game from advocaite's ForeverLauncher, log in with <name>@local, realm Trinity, then type /fb in game."
