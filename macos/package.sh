#!/usr/bin/env bash
# Packs a built server (macos/build.sh) into a download that runs without Xcode, cmake or a compile:
#   dist/WoW-Forever-Bots-macOS-arm64-<version>.tar.gz (+ .sha256)
#
#   WoWForeverBots/                 this repository (scripts, add-on, docs, bot SQL)
#   WoWForeverBots/prebuilt/server  bin/ (worldserver, bnetserver, map tools), lib/ (their Homebrew libraries), etc/
#   WoWForeverBots/prebuilt/source  sql/ of the core with this repository over it (worldserver's SourceDirectory)
#   WoWForeverBots/prebuilt/VERSION what it was built from
#
#   macos/package.sh [--version v0.1.14-mac1] [--out dist] [--repo owner/name]
# Used by .github/workflows/macos-release.yml; works the same on your own Mac after macos/build.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSION=""; OUT="$WOWF_REPO/dist"; RELEASE_REPO="${WOWF_RELEASE_REPO:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        --repo)    RELEASE_REPO="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *)         die "Unknown option: $1" ;;
    esac
done
require_macos
load_brew_env || die "Homebrew is needed."
[ -x "$WOWF_BIN/worldserver" ] || die "Nothing built in $WOWF_BIN (run macos/build.sh first)."
[ -n "$VERSION" ] || VERSION="$(git -C "$WOWF_REPO" describe --tags --always 2>/dev/null || echo dev)"
if [ -z "$RELEASE_REPO" ]; then
    RELEASE_REPO="$(git -C "$WOWF_REPO" remote get-url origin 2>/dev/null | sed -E 's#(\.git)?$##; s#^.*github\.com[:/]##')"
fi
ARCH="$(uname -m)"
NAME="WoW-Forever-Bots-macOS-$ARCH-$VERSION"
STAGE="$(mktemp -d)/WoWForeverBots"
PRE="$STAGE/prebuilt"
mkdir -p "$PRE/server/bin" "$PRE/server/lib" "$PRE/source" "$OUT"

step "1/5 Repository files"
git -C "$WOWF_REPO" archive --format=tar HEAD | tar -x -C "$STAGE"
# the core's SQL (with ours over it) ships once, under prebuilt/source; keep only the bot database files at the top
find "$STAGE/sql" -mindepth 1 -maxdepth 1 ! -name playerbot_shared -exec rm -rf {} +
rm -rf "$STAGE/.github" "$STAGE/dist"

step "2/5 Programs and settings"
TOOLS="worldserver bnetserver mapextractor vmap4extractor vmap4assembler mmaps_generator"
for b in $TOOLS; do cp "$WOWF_BIN/$b" "$PRE/server/bin/"; done
for b in mmap_probe walk_link_check mmap_world_dump road_extractor; do
    [ -x "$WOWF_BIN/$b" ] && cp "$WOWF_BIN/$b" "$PRE/server/bin/"
done
mkdir -p "$PRE/server/etc"
( cd "$WOWF_ETC" && find . \( -name '*.dist' -o -path './worldserver.conf.d/*' -o -path './bnetserver.conf.d/*' \) -type f \
    ! -name 'playerbot.conf' ! -name 'zz-9-local.conf' -print0 | while IFS= read -r -d '' f; do
        mkdir -p "$PRE/server/etc/$(dirname "$f")"; cp "$f" "$PRE/server/etc/$f"
    done )

step "3/5 Libraries (so no Homebrew build packages are needed)"
brew list --formula dylibbundler >/dev/null 2>&1 || brew install dylibbundler
args=()
for b in "$PRE"/server/bin/*; do args+=(-x "$b"); done
dylibbundler -cd -of -b "${args[@]}" -d "$PRE/server/lib" -p "@executable_path/../lib/" -s "$(brew --prefix)/lib" </dev/null >/dev/null
# install_name_tool breaks the signatures: sign everything again (ad-hoc), Apple Silicon refuses unsigned code
for f in "$PRE"/server/lib/* "$PRE"/server/bin/*; do codesign --force --sign - "$f" >/dev/null 2>&1 || die "codesign $f"; done
bad="$(for f in "$PRE"/server/bin/* "$PRE"/server/lib/*; do otool -L "$f" | tail -n +2 | awk '{print $1}'; done \
       | grep -E '^/(opt/homebrew|usr/local)/' | sort -u || true)"
[ -z "$bad" ] || die "Still linked to Homebrew: $bad"
"$PRE/server/bin/worldserver" --version >/dev/null 2>&1 || "$PRE/server/bin/worldserver" --help >/dev/null 2>&1 \
    || die "The packed worldserver does not start."
ok "$(ls "$PRE/server/lib" | wc -l | tr -d ' ') libraries bundled"

step "4/5 SQL (worldserver's SourceDirectory)"
rsync -a --exclude 'old/' "$WOWF_SRC/sql/" "$PRE/source/sql/"
cat > "$PRE/VERSION" <<EOF
version=$VERSION
repo=$RELEASE_REPO
arch=$ARCH
bots_commit=$(git -C "$WOWF_REPO" rev-parse HEAD 2>/dev/null || echo unknown)
core_commit=$(git -C "$WOWF_SRC" rev-parse HEAD 2>/dev/null || echo unknown)
macos_built_on=$(sw_vers -productVersion)
built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

step "5/5 Archive"
tar -C "$(dirname "$STAGE")" -czf "$OUT/$NAME.tar.gz" WoWForeverBots
( cd "$OUT" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
rm -rf "$(dirname "$STAGE")"
ok "$OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
