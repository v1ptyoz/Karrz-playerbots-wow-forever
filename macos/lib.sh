#!/usr/bin/env bash
# Shared settings and helpers for the macOS scripts (build.sh, install.sh, wowforever.sh, install-addon.sh).
# Sourced, never run. Works with the bash 3.2 that ships with macOS (no associative arrays, no mapfile).

# --- where things live --------------------------------------------------------------------------------------------
# WOWF_HOME holds everything the scripts make: the merged source, the build, the server and the backups.
# Override it with an environment variable before the first install; later runs read it back from wowforever.env.
WOWF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # this checkout (the bots)
WOWF_HOME="${WOWF_HOME:-$HOME/WoWForever}"
WOWF_ENV="$WOWF_HOME/wowforever.env"
if [ -f "$WOWF_ENV" ]; then
    # shellcheck disable=SC1090
    . "$WOWF_ENV"
fi
WOWF_SRC="$WOWF_HOME/source"          # advocaite's forever branch with this repository copied over it
WOWF_BUILD="$WOWF_HOME/build"
WOWF_PREFIX="$WOWF_HOME/server"       # bin/ etc/ data/ logs/ certs/
WOWF_BIN="$WOWF_PREFIX/bin"
WOWF_ETC="$WOWF_PREFIX/etc"
WOWF_DATA="$WOWF_PREFIX/data"
WOWF_LOGS="$WOWF_PREFIX/logs"
WOWF_CERTS="$WOWF_PREFIX/certs"
WOWF_BACKUPS="$WOWF_HOME/backups"
WOWF_TMUX_SESSION="wowforever"

# The core the bots are built on (advocaite's TrinityCore, branch forever). macos/UPSTREAM holds the tested commit.
WOWF_UPSTREAM_URL="${WOWF_UPSTREAM_URL:-https://github.com/advocaite/TrinityCore.git}"
WOWF_UPSTREAM_BRANCH="${WOWF_UPSTREAM_BRANCH:-forever}"
if [ -z "${WOWF_UPSTREAM_COMMIT:-}" ] && [ -f "$WOWF_REPO/macos/UPSTREAM" ]; then
    WOWF_UPSTREAM_COMMIT="$(grep -v '^#' "$WOWF_REPO/macos/UPSTREAM" | head -1 | tr -d '[:space:]')"
fi

# The Forever world + hotfixes database release (same one the README names; the file names are in revision_data.h.in.cmake).
WOWF_TDB_URL="https://github.com/advocaite/TrinityCore/releases/download/forever-tdb-2026-10-14/TDB_full_forever_2026_10_14.7z"
WOWF_TDB_FILES="TDB_full_world_forever_2026_10_14.sql TDB_full_hotfixes_forever_2026_10_14.sql"

WOWF_DISCORD="https://discord.gg/Jk596N3xun"
WOWF_LOGIN_HOST="trinity.actual.battle.net"
WOWF_CLIENT_BUILD="70450"

# --- output -------------------------------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '%s OK%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '\n%s=== %s ===%s\n' "$C_B" "$*" "$C_0"; }

ask_yes() {   # ask_yes "question" [default y|n]
    local q="$1" def="${2:-y}" a hint="[Y/n]"
    [ "$def" = "n" ] && hint="[y/N]"
    if [ ! -t 0 ]; then [ "$def" = "y" ]; return; fi
    printf '%s %s ' "$q" "$hint"
    read -r a || a=""
    a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
    [ -z "$a" ] && a="$def"
    [ "$a" = "y" ] || [ "$a" = "yes" ]
}

# --- checks -------------------------------------------------------------------------------------------------------
require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "These scripts are for macOS."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$major" -lt 14 ] 2>/dev/null; then
        warn "macOS $(sw_vers -productVersion): tested on macOS 26 (Tahoe); 14 or newer is needed for the C++20 library."
    fi
}

brew_prefix() {
    if command -v brew >/dev/null 2>&1; then brew --prefix; return; fi
    for p in /opt/homebrew /usr/local; do
        [ -x "$p/bin/brew" ] && { echo "$p"; return; }
    done
    return 1
}

load_brew_env() {
    local bp
    bp="$(brew_prefix 2>/dev/null)" || return 1
    eval "$("$bp/bin/brew" shellenv)"
    # keg-only formulas the build and the scripts use
    export PATH="$bp/opt/mysql/bin:$bp/opt/openssl@3/bin:$PATH"
}

ncpu() { sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }
ram_gb() { echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 )); }

# sed -i differs between BSD (macOS) and GNU; this works with both.
sed_inplace() {   # sed_inplace <expr> <file>
    local f="$2" tmp
    tmp="$(mktemp "${f}.XXXXXX")"
    sed -E "$1" "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
}

# setkey <file> <key> <value>: replaces "key = ..." (also "key=...") or appends it when the file has no such line.
setkey() {
    local file="$1" key="$2" val="$3" ekey esc
    ekey="$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')"
    if grep -qE "^${ekey}[[:space:]]*=" "$file"; then
        esc="$(printf '%s' "$val" | sed 's/[&|\\]/\\&/g')"
        sed_inplace "s|^${ekey}[[:space:]]*=.*|${key} = ${esc}|" "$file"
    else
        printf '\n%s = %s\n' "$key" "$val" >> "$file"
    fi
}

save_env() {   # save_env KEY VALUE: remembers a setting in wowforever.env
    local key="$1" val="$2"
    mkdir -p "$WOWF_HOME"
    touch "$WOWF_ENV"; chmod 600 "$WOWF_ENV"
    if grep -q "^${key}=" "$WOWF_ENV"; then
        local tmp; tmp="$(mktemp)"
        grep -v "^${key}=" "$WOWF_ENV" > "$tmp"; cat "$tmp" > "$WOWF_ENV"; rm -f "$tmp"
    fi
    printf '%s=%q\n' "$key" "$val" >> "$WOWF_ENV"
    eval "$key=\$val"
}

# --- MySQL --------------------------------------------------------------------------------------------------------
# Admin access: Homebrew's MySQL lets the macOS user in as root over the socket without a password.
# If you gave root a password yourself, the scripts ask for it once per run (MYSQL_PWD, never written to disk).
mysql_admin() {
    if [ -z "${WOWF_ROOT_CHECKED:-}" ]; then
        WOWF_ROOT_CHECKED=1
        if ! mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
            local pw
            printf 'MySQL root password: ' >&2; stty -echo 2>/dev/null; read -r pw; stty echo 2>/dev/null; printf '\n' >&2
            export MYSQL_PWD="$pw"
            mysql -uroot -e "SELECT 1" >/dev/null 2>&1 || die "MySQL does not accept that root password."
        fi
    fi
    mysql -uroot "$@"
}
mysql_game()  { mysql -h127.0.0.1 -P3306 -utrinity -p"$WOWF_DB_PASS" "$@" 2>/dev/null; }

mysql_running() { mysqladmin -uroot ping >/dev/null 2>&1; }

ensure_mysql() {
    if mysql_running; then return 0; fi
    info "Starting MySQL (brew services start mysql)"
    brew services start mysql >/dev/null || true
    local i
    for i in $(seq 1 60); do
        mysql_running && return 0
        sleep 1
    done
    die "MySQL does not answer. Check: brew services list; tail \"$(brew --prefix)/var/mysql/\"*.err"
}

# --- processes ----------------------------------------------------------------------------------------------------
pid_of() { pgrep -x "$1" 2>/dev/null | head -1; }
world_running() { [ -n "$(pid_of worldserver)" ]; }
bnet_running()  { [ -n "$(pid_of bnetserver)" ]; }
