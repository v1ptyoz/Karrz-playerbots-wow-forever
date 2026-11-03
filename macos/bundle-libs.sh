#!/usr/bin/env bash
# Copies every non-system library the given programs need (Homebrew, @rpath, @loader_path, recursively) into one folder
# and points the programs and the copies at it (@executable_path/../lib/<name>), so the programs run without Homebrew.
#   macos/bundle-libs.sh <lib dir> <program>...
# Replaces dylibbundler, which waits forever for an answer when it cannot place an @rpath library.
# Never asks anything; a library it cannot find is an error.
set -euo pipefail

LIBDIR="$1"; shift
mkdir -p "$LIBDIR"
LIBDIR="$(cd "$LIBDIR" && pwd)"
BP="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
REF="@executable_path/../lib"
MAP="$(mktemp)"          # lines: <copied name>\t<original path>
trap 'rm -f "$MAP"' EXIT

is_system() { case "$1" in /usr/lib/*|/System/*) return 0 ;; *) return 1 ;; esac; }

# rpaths of a Mach-O file, with @loader_path/@executable_path resolved against its original location
rpaths_of() {   # <file> <original dir> <executable dir>
    otool -l "$1" | awk '/cmd LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | while read -r p; do
        p="${p//@loader_path/$2}"; p="${p//@executable_path/$3}"; echo "$p"
    done
}

resolve() {     # <dependency as written> <file> <original dir of file> <executable dir>
    local dep="$1" f="$2" odir="$3" edir="$4" name cand
    case "$dep" in
        @rpath/*)
            name="${dep#@rpath/}"
            for cand in $(rpaths_of "$f" "$odir" "$edir") "$BP/lib" "$odir" ; do
                [ -f "$cand/$name" ] && { echo "$cand/$name"; return 0; }
            done
            cand="$(find "$BP/opt/" -maxdepth 3 -path "*/lib/$name" 2>/dev/null | head -1)"
            [ -n "$cand" ] && { echo "$cand"; return 0; } ;;
        @loader_path/*)   cand="$odir/${dep#@loader_path/}"; [ -f "$cand" ] && { echo "$cand"; return 0; } ;;
        @executable_path/*) cand="$edir/${dep#@executable_path/}"; [ -f "$cand" ] && { echo "$cand"; return 0; } ;;
        /*) [ -f "$dep" ] && { echo "$dep"; return 0; } ;;
    esac
    return 1
}

# fix one file: copy each dependency into LIBDIR (once) and rewrite the reference; recurse into new copies
process() {     # <file> <original path of file> <executable dir>
    local f="$1" orig="$2" edir="$3" odir self dep real name
    odir="$(cd "$(dirname "$orig")" && pwd -P)"
    self="$(otool -D "$f" 2>/dev/null | sed -n 2p || true)"
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        [ -n "$dep" ] || continue
        [ "$dep" = "$self" ] && continue
        is_system "$dep" && continue
        case "$dep" in "$REF"/*) continue ;; esac
        real="$(resolve "$dep" "$f" "$odir" "$edir")" || { echo "bundle-libs: cannot find $dep (needed by $orig)" >&2; exit 1; }
        is_system "$real" && continue
        name="$(basename "$real")"
        install_name_tool -change "$dep" "$REF/$name" "$f"
        if ! grep -q "^$name	" "$MAP"; then
            printf '%s\t%s\n' "$name" "$real" >> "$MAP"
            cp -L "$real" "$LIBDIR/$name"; chmod u+w "$LIBDIR/$name"
            install_name_tool -id "$REF/$name" "$LIBDIR/$name"
            echo "  + $name  ($real)"
            process "$LIBDIR/$name" "$(cd "$(dirname "$real")" && pwd -P)/$(basename "$real")" "$edir"
        fi
    done
}

for b in "$@"; do
    echo "$(basename "$b")"
    chmod u+w "$b"
    process "$b" "$b" "$(cd "$(dirname "$b")" && pwd -P)"
done
echo "$(wc -l < "$MAP" | tr -d ' ') libraries in $LIBDIR"
