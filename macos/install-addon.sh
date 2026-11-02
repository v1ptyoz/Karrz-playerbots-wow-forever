#!/usr/bin/env bash
# Installs (or refreshes) the ForeverBots add-on in the WoW Forever game folder. Needs no server and no password.
#   macos/install-addon.sh                                 uses the game folder install.sh found, or asks
#   macos/install-addon.sh --client "/path/to/game folder" the folder that holds .build.info and _classic_beta_
#   macos/install-addon.sh --download                      fetch the newest add-on from GitHub instead of this checkout
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLIENT="${WOWF_CLIENT:-}"; DOWNLOAD=0
ADDON_ZIP_URL="https://github.com/Karrz1/Karrz-playerbots-wow-forever/raw/HEAD/addon/ForeverBots-addon.zip"
while [ $# -gt 0 ]; do
    case "$1" in
        --client)   CLIENT="$2"; shift 2 ;;
        --download) DOWNLOAD=1; shift ;;
        -h|--help)  sed -n '2,5p' "$0"; exit 0 ;;
        *)          die "Unknown option: $1" ;;
    esac
done

if [ -z "$CLIENT" ] || [ ! -f "$CLIENT/.build.info" ]; then
    CLIENT="$(osascript -e 'POSIX path of (choose folder with prompt "Select your WoW Forever game folder (the one that contains .build.info)")' 2>/dev/null || true)"
    CLIENT="${CLIENT%/}"
fi
[ -n "$CLIENT" ] && [ -f "$CLIENT/.build.info" ] || die "Not a game folder (no .build.info): ${CLIENT:-none}"

version_of() { sed -nE 's/^##[[:space:]]*Version:[[:space:]]*(.+)$/\1/p' "$1/ForeverBots.toc" 2>/dev/null | head -1 | tr -d '\r'; }

SRC=""
TMP=""
if [ $DOWNLOAD -eq 0 ]; then
    for c in "$WOWF_REPO/src/modules/PlayerbotV2/Addon/ForeverBots" "$WOWF_REPO/addon/ForeverBots"; do
        [ -f "$c/ForeverBots.toc" ] && { SRC="$c"; break; }
    done
fi
if [ -z "$SRC" ]; then
    TMP="$(mktemp -d)"
    info "Downloading the add-on"
    curl -fsSL -o "$TMP/addon.zip" "$ADDON_ZIP_URL" || die "Download failed: $ADDON_ZIP_URL"
    ditto -x -k "$TMP/addon.zip" "$TMP/x"
    SRC="$(dirname "$(find "$TMP/x" -name ForeverBots.toc | head -1)")"
    [ -f "$SRC/ForeverBots.toc" ] || die "The download has no ForeverBots.toc"
fi

DEST="$CLIENT/_classic_beta_/Interface/AddOns/ForeverBots"
old="$(version_of "$DEST" || true)"
mkdir -p "$(dirname "$DEST")"
rsync -a --delete "$SRC/" "$DEST/"
[ -n "$TMP" ] && rm -rf "$TMP"
new="$(version_of "$DEST")"
if [ -n "$old" ] && [ "$old" != "$new" ]; then ok "ForeverBots add-on $old -> $new: $DEST"; else ok "ForeverBots add-on ${new:-?}: $DEST"; fi
if [ -d "$CLIENT/_classic_beta_/Interface/AddOns/ClassicForever_Bots" ]; then
    warn "The add-on ClassicForever_Bots (made for another server) is installed: untick it in the AddOns list, it prints a harmless error here."
fi
say "In game: on the character screen open AddOns and tick 'Load out of date AddOns' if ForeverBots is greyed out, then type /fb."
