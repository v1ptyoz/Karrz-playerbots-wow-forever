#!/usr/bin/env bash
# Builds WoW Forever Bots on macOS: installs the build tools (Homebrew), fetches advocaite's TrinityCore "forever" core at the
# tested commit (macos/UPSTREAM), copies this repository over it, compiles worldserver, bnetserver and the map tools with the
# bot module, and installs them into ~/WoWForever/server.
#
#   macos/build.sh                 everything (first time: about 1 to 2 hours on Apple Silicon, later builds are much faster)
#   macos/build.sh --skip-deps     do not run Homebrew
#   macos/build.sh --clean         throw the old build folder away first
#   macos/build.sh --jobs 6        compile with 6 jobs (default: cores, held to about 2 GB of RAM per job)
#   macos/build.sh --tests         also build and run the unit tests (ctest)
#   macos/build.sh --type Release  build type (default RelWithDebInfo; Release needs far less disk)
#   macos/build.sh --from-source   compile even when this is a release download with a ready-made server (prebuilt/)
#
# In a release download (prebuilt/server exists) it only installs the ready-made server: no Xcode compile, no cmake,
# just the few Homebrew packages the server needs at run time (mysql, openssl, tmux, 7-Zip).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKIP_DEPS=0; CLEAN=0; JOBS=""; TESTS=0; FROM_SOURCE=0; BUILD_TYPE="RelWithDebInfo"
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-deps) SKIP_DEPS=1; shift ;;
        --clean)     CLEAN=1; shift ;;
        --jobs)      JOBS="$2"; shift 2 ;;
        --tests)     TESTS=1; shift ;;
        --type)      BUILD_TYPE="$2"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
        *)           die "Unknown option: $1 (see --help)" ;;
    esac
done

require_macos

# --- 1. tools -------------------------------------------------------------------------------------------------------
step "1/4 Build tools"
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install || true
    die "The Xcode Command Line Tools are being installed. Run this script again when that window has finished."
fi
ok "Xcode Command Line Tools: $(xcode-select -p)"

if ! brew_prefix >/dev/null 2>&1; then
    say "Homebrew (https://brew.sh) is needed for cmake, boost, openssl, mysql."
    if ask_yes "Install Homebrew now?"; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        die "Install Homebrew, then run this script again."
    fi
fi
load_brew_env || die "Homebrew was not found after the install."
ok "Homebrew: $(brew --prefix)"

PREBUILT="$WOWF_REPO/prebuilt"
USE_PREBUILT=0
if [ $FROM_SOURCE -eq 0 ] && [ -x "$PREBUILT/server/bin/worldserver" ]; then
    if [ "$(grep '^arch=' "$PREBUILT/VERSION" 2>/dev/null | cut -d= -f2)" = "$(uname -m)" ]; then
        USE_PREBUILT=1
    else
        warn "The ready-made server is for $(grep '^arch=' "$PREBUILT/VERSION" | cut -d= -f2), this Mac is $(uname -m): compiling instead."
    fi
fi

if [ $USE_PREBUILT -eq 1 ]; then
    BREW_PACKAGES="openssl@3 mysql tmux sevenzip"
else
    BREW_PACKAGES="git cmake ninja ccache boost openssl@3 mysql readline bzip2 zlib tmux sevenzip"
fi
if [ $SKIP_DEPS -eq 0 ]; then
    missing=""
    for p in $BREW_PACKAGES; do
        brew list --formula "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        info "brew install$missing"
        # shellcheck disable=SC2086
        brew install $missing
    fi
    ok "Packages: $BREW_PACKAGES"
fi
load_brew_env

# --- ready-made server (release download) ----------------------------------------------------------------------------
if [ $USE_PREBUILT -eq 1 ]; then
    step "2/2 Installing the ready-made server ($(grep '^version=' "$PREBUILT/VERSION" | cut -d= -f2))"
    xattr -dr com.apple.quarantine "$WOWF_REPO" 2>/dev/null || true   # a browser download marks every file
    mkdir -p "$WOWF_BIN" "$WOWF_PREFIX/lib" "$WOWF_ETC" "$WOWF_SRC"
    rsync -a --delete "$PREBUILT/server/bin/" "$WOWF_BIN/" --exclude 'TDB_full_*' --exclude '.tdb-unpack'
    rsync -a --delete "$PREBUILT/server/lib/" "$WOWF_PREFIX/lib/"
    # settings: the .dist files and the defaults the build would refresh are replaced, your own files never
    ( cd "$PREBUILT/server/etc" && find . -type f | while read -r f; do
        dst="$WOWF_ETC/$f"; mkdir -p "$(dirname "$dst")"
        case "$f" in
            *.dist|*/zz-0-playerbot-defaults.conf) cp "$f" "$dst" ;;
            *) [ -f "$dst" ] || cp "$f" "$dst" ;;
        esac
    done )
    # worldserver's SourceDirectory: the SQL it applies at start; vanilla files you built yourself are kept
    rsync -a --delete --filter 'P sql/custom/world/2026_10_12_5*_world_classic_vanilla_*.sql' \
        "$PREBUILT/source/" "$WOWF_SRC/"
    [ -d "$WOWF_REPO/sql/custom/world" ] && rsync -a "$WOWF_REPO/sql/custom/world/" "$WOWF_SRC/sql/custom/world/"
    for b in worldserver bnetserver mapextractor vmap4extractor vmap4assembler mmaps_generator; do
        [ -x "$WOWF_BIN/$b" ] || die "$b is missing from the download"
    done
    "$WOWF_BIN/worldserver" --version >/dev/null 2>&1 || die "The ready-made worldserver does not start on this Mac (macOS $(sw_vers -productVersion)). Try: macos/build.sh --from-source"
    save_env WOWF_BUILT_FROM "$(grep '^version=' "$PREBUILT/VERSION" | cut -d= -f2) (ready-made)"
    ok "Installed: $WOWF_BIN"
    say "Next: macos/install.sh (first time) or macos/wowforever.sh (menu)."
    exit 0
fi

# --- 2. source ------------------------------------------------------------------------------------------------------
step "2/4 Source: advocaite/TrinityCore ($WOWF_UPSTREAM_BRANCH @ ${WOWF_UPSTREAM_COMMIT:-latest}) + this repository"
mkdir -p "$WOWF_HOME"
if [ ! -d "$WOWF_SRC/.git" ]; then
    info "Cloning the core (about 600 MB)"
    git clone --filter=blob:none --branch "$WOWF_UPSTREAM_BRANCH" "$WOWF_UPSTREAM_URL" "$WOWF_SRC"
else
    info "Fetching the core"
    git -C "$WOWF_SRC" fetch --quiet origin "$WOWF_UPSTREAM_BRANCH" || warn "fetch failed, using what is already there"
fi
target="${WOWF_UPSTREAM_COMMIT:-origin/$WOWF_UPSTREAM_BRANCH}"
git -C "$WOWF_SRC" cat-file -e "${target}^{commit}" 2>/dev/null \
    || git -C "$WOWF_SRC" fetch --quiet origin "$target" 2>/dev/null \
    || die "Commit $target is not in $WOWF_UPSTREAM_URL"
# a clean core every time, so files this repository dropped since the last build do not linger
git -C "$WOWF_SRC" checkout --quiet --force --detach "$target"
git -C "$WOWF_SRC" clean -fdxq
info "Copying this repository over it ($WOWF_REPO)"
rsync -a --exclude '.git' --exclude 'build*/' "$WOWF_REPO/" "$WOWF_SRC/"
ok "Source ready: $WOWF_SRC (core $(git -C "$WOWF_SRC" rev-parse --short HEAD))"

# --- 3. configure + compile -----------------------------------------------------------------------------------------
step "3/4 Compile"
[ $CLEAN -eq 1 ] && rm -rf "$WOWF_BUILD"
if [ -z "$JOBS" ]; then
    JOBS="$(ncpu)"
    by_ram=$(( $(ram_gb) / 2 )); [ $by_ram -lt 1 ] && by_ram=1
    [ "$JOBS" -gt "$by_ram" ] && JOBS=$by_ram
fi
BP="$(brew --prefix)"
cmake -S "$WOWF_SRC" -B "$WOWF_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$WOWF_PREFIX" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DSERVERS=1 -DTOOLS=1 -DSCRIPTS=static -DBUILD_PLAYERBOT_V2=1 -DBUILD_TESTING="$TESTS" -DWITH_WARNINGS=0 \
    -DOPENSSL_ROOT_DIR="$BP/opt/openssl@3" \
    -DMYSQL_ROOT_DIR="$BP/opt/mysql" \
    -DREADLINE_ROOT_DIR="$BP/opt/readline" \
    -DBoost_ROOT="$BP/opt/boost"
info "Compiling with $JOBS jobs (the first build takes a while; ccache makes the next ones fast)"
cmake --build "$WOWF_BUILD" -j "$JOBS"

if [ $TESTS -eq 1 ]; then
    info "Unit tests"
    ( cd "$WOWF_BUILD" && ctest --output-on-failure -j "$JOBS" )
fi

# --- 4. install -----------------------------------------------------------------------------------------------------
step "4/4 Install into $WOWF_PREFIX"
cmake --install "$WOWF_BUILD" >/dev/null
for b in worldserver bnetserver mapextractor vmap4extractor vmap4assembler mmaps_generator; do
    [ -x "$WOWF_BIN/$b" ] || die "$b was not installed into $WOWF_BIN"
done
save_env WOWF_BUILT_FROM "$(git -C "$WOWF_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ok "Built and installed: $WOWF_BIN"
say "Next: macos/install.sh (first time) or macos/wowforever.sh (menu)."
