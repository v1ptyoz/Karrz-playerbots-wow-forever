#!/usr/bin/env bash
#
# extract_client_data.sh
#
# macOS / Linux helper to extract WoW client data for TrinityCore.
# Runs mapextractor -> vmap4extractor -> vmap4assembler -> mmaps_generator
# in the correct order.
#
# Usage:
#   ./extract_client_data.sh \
#       --client-path "/path/to/World of Warcraft" \
#       --output-path "/path/to/server/bin" \
#       [--tools-path DIR] [--maps-only] [--resume] [--threads N] [--locale enUS]
#
#   --client-path  the game folder that holds .build.info (and _classic_beta_)
#   --output-path  where dbc/ maps/ vmaps/ mmaps/ Cameras/ gt/ are written (the server's DataDir)
#   --tools-path   where mapextractor, vmap4extractor, vmap4assembler and mmaps_generator are (default: --output-path)
#   --maps-only    stop after mapextractor (road workflow)
#   --resume       safe to run again after an interruption: each finished stage leaves a marker file
#                  (.extract-maps.done, .extract-vmaps.done, .extract-mmaps.done) and is skipped next time, an
#                  unfinished vmap stage is cleaned and redone, mmaps_generator skips tiles it already built, and
#                  the intermediate Buildings/ and dir_bin/ folders (about 40 GB) are removed at the end
#   --threads N    workers for vmap4extractor, vmap4assembler and mmaps_generator (default: all cores)
#   --locale X     DBC locale (enUS, deDE, frFR, ...), default enUS
#
# Works with the bash 3.2 that ships with macOS and with GNU or BSD tools.

set -euo pipefail

CLIENT_PATH=""
OUTPUT_PATH=""
TOOLS_PATH=""
MAPS_ONLY=0
RESUME=0
THREADS=0
LOCALE="enUS"

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,27p' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client-path) CLIENT_PATH="$2"; shift 2 ;;
        --output-path) OUTPUT_PATH="$2"; shift 2 ;;
        --tools-path)  TOOLS_PATH="$2"; shift 2 ;;
        --maps-only)   MAPS_ONLY=1; shift ;;
        --resume)      RESUME=1; shift ;;
        --threads)     THREADS="$2"; shift 2 ;;
        --locale)      LOCALE="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             die "Unknown argument: $1 (use --help)" ;;
    esac
done

[[ -n "$CLIENT_PATH" ]] || die "--client-path is required"
[[ -n "$OUTPUT_PATH" ]] || die "--output-path is required"

step() {
    printf '\n==============================================================\n'
    printf ' %s\n' "$*"
    printf '==============================================================\n'
}

human_size() {
    # KB -> human readable
    local kb=$1
    if   [[ $kb -ge $((1024*1024)) ]]; then awk "BEGIN{printf \"%.2f GB\", $kb/1048576}"
    elif [[ $kb -ge 1024 ]];           then awk "BEGIN{printf \"%.1f MB\", $kb/1024}"
    else                                    printf '%s KB' "$kb"
    fi
}

summary() {
    local root="$1"; shift
    local total=0
    printf '\n--- Output summary ---\n'
    for name in "$@"; do
        local p="$root/$name"
        if [[ -d "$p" ]]; then
            local count kb
            count=$(find "$p" -type f | wc -l | tr -d ' ')
            kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')   # du -sk works on macOS and Linux (du -b is GNU only)
            total=$((total + kb))
            printf '  %-12s files=%-8s size=%s\n' "$name" "$count" "$(human_size "$kb")"
        else
            printf '  %-12s MISSING\n' "$name"
        fi
    done
    printf '  %-12s %s\n' "TOTAL" "$(human_size "$total")"
}

is_done()  { [[ $RESUME -eq 1 && -f "$OUTPUT_PATH/.extract-$1.done" ]]; }
set_done() { [[ $RESUME -eq 1 ]] && date '+%Y-%m-%dT%H:%M:%S' > "$OUTPUT_PATH/.extract-$1.done"; return 0; }
clean_intermediate() { rm -rf "$OUTPUT_PATH/Buildings" "$OUTPUT_PATH/dir_bin"; }

# map ids that have game files: maps/<id>*.tilelist and vmaps/<id>/
map_ids() {
    {
        for f in "$OUTPUT_PATH"/maps/*.tilelist; do
            [[ -e "$f" ]] || continue
            b="$(basename "$f")"; id="${b:0:4}"
            if [[ "$id" =~ ^[0-9]{4}$ ]]; then echo $((10#$id)); fi
        done
        for d in "$OUTPUT_PATH"/vmaps/*/; do
            [[ -d "$d" ]] || continue
            b="$(basename "$d")"
            if [[ "$b" =~ ^[0-9]+$ ]]; then echo $((10#$b)); fi
        done
    } | sort -n -u
}
mmap_count() { find "$OUTPUT_PATH/mmaps" -maxdepth 1 -name '*.mmap' 2>/dev/null | wc -l | tr -d ' '; }

# --- Validate output path + extractor binaries -----------------------------
[[ -d "$OUTPUT_PATH" ]] || die "OutputPath does not exist: $OUTPUT_PATH"
OUTPUT_PATH="$(cd "$OUTPUT_PATH" && pwd)"
[[ -n "$TOOLS_PATH" ]] || TOOLS_PATH="$OUTPUT_PATH"
[[ -d "$TOOLS_PATH" ]] || die "ToolsPath does not exist: $TOOLS_PATH"
TOOLS_PATH="$(cd "$TOOLS_PATH" && pwd)"

required=(mapextractor)
if [[ $MAPS_ONLY -eq 0 ]]; then
    required+=(vmap4extractor vmap4assembler mmaps_generator)
fi
for bin in "${required[@]}"; do
    if [[ ! -x "$TOOLS_PATH/$bin" ]]; then
        die "Required binary not found or not executable: $TOOLS_PATH/$bin
Build the server first (macOS: macos/build.sh)."
    fi
done

# --- Validate client install -----------------------------------------------
[[ -d "$CLIENT_PATH" ]] || die "ClientPath does not exist: $CLIENT_PATH"
CLIENT_PATH="$(cd "$CLIENT_PATH" && pwd)"
if [[ ! -f "$CLIENT_PATH/.build.info" && ! -d "$CLIENT_PATH/Data" ]]; then
    die "ClientPath '$CLIENT_PATH' has no .build.info or Data/ - not a valid WoW install root.
Point at the folder that holds .build.info (not at _classic_beta_ or Data/)."
fi

printf 'Client : %s\n' "$CLIENT_PATH"
printf 'Output : %s\n' "$OUTPUT_PATH"
printf 'Tools  : %s\n' "$TOOLS_PATH"
printf 'Locale : %s\n' "$LOCALE"
if [[ $THREADS -le 0 ]]; then printf 'Threads: (all cores)\n'; else printf 'Threads: %s\n' "$THREADS"; fi
mode='FULL'; [[ $MAPS_ONLY -eq 1 ]] && mode='MAPS-ONLY (road workflow)'
[[ $RESUME -eq 1 ]] && mode="$mode (resumable)"
printf 'Mode   : %s\n' "$mode"

START=$(date +%s)
minutes() { echo $(( ($(date +%s) - START) / 60 )); }

cd "$OUTPUT_PATH"

# --- Step 1: mapextractor --------------------------------------------------
step "Step 1/4: mapextractor (maps + dbc + Cameras + gt)"
if is_done maps; then
    echo "Already done (resuming)."
else
    e_flag=15
    [[ $MAPS_ONLY -eq 1 ]] && e_flag=3
    "$TOOLS_PATH/mapextractor" -i "$CLIENT_PATH" -o "$OUTPUT_PATH" -e "$e_flag" -f 1 -l "$LOCALE" \
        || die "mapextractor failed (exit $?). Check the output above; usual culprits: CASC init failure, wrong client path."
    set_done maps
fi

if [[ $MAPS_ONLY -eq 1 ]]; then
    step "Maps-only mode: skipping vmap4/mmaps generation."
    summary "$OUTPUT_PATH" dbc maps Cameras gt
    printf '\nDONE (maps-only).\n'
    exit 0
fi

# --- Step 2+3: vmap4extractor + vmap4assembler ------------------------------
if is_done vmaps; then
    step "Step 2-3/4: vmaps"
    echo "Already done (resuming)."
else
    step "Step 2/4: vmap4extractor (CASC -> Buildings/)"
    [[ $RESUME -eq 1 ]] && clean_intermediate   # a half-finished earlier run
    vmap_args=(-d "$CLIENT_PATH")
    [[ $THREADS -gt 0 ]] && vmap_args+=(--threads "$THREADS")
    "$TOOLS_PATH/vmap4extractor" "${vmap_args[@]}" \
        || die "vmap4extractor failed (exit $?). Delete Buildings/ and dir_bin/ if they have leftovers from a prior run."

    step "Step 3/4: vmap4assembler (Buildings/ -> vmaps/)"
    mkdir -p vmaps
    asm_args=(Buildings vmaps)
    [[ $THREADS -gt 0 ]] && asm_args+=(--threads "$THREADS")
    "$TOOLS_PATH/vmap4assembler" "${asm_args[@]}" \
        || die "vmap4assembler failed (exit $?)."
    set_done vmaps
fi

# --- Step 4: mmaps_generator -----------------------------------------------
step "Step 4/4: mmaps_generator (dbc+maps+vmaps -> mmaps/)"
if is_done mmaps; then
    echo "Already done (resuming)."
else
    mkdir -p mmaps
    expect=$(map_ids | wc -l | tr -d ' ')
    mmap_args=(--input "$OUTPUT_PATH" --output "$OUTPUT_PATH" --silent)
    [[ $THREADS -gt 0 ]] && mmap_args+=(--threads "$THREADS")
    # run it in the background so the progress can be shown: one line per minute with the number of maps finished so far
    "$TOOLS_PATH/mmaps_generator" "${mmap_args[@]}" &
    gen=$!
    trap 'kill $gen 2>/dev/null || true' INT TERM
    while kill -0 "$gen" 2>/dev/null; do
        for _ in $(seq 1 60); do kill -0 "$gen" 2>/dev/null || break; sleep 1; done
        kill -0 "$gen" 2>/dev/null && printf 'Pathfinding data: %s of about %s maps done, still working (%s minutes so far)...\n' \
            "$(mmap_count)" "$expect" "$(minutes)"
    done
    set +e; wait "$gen"; gen_code=$?; set -e
    trap - INT TERM
    [[ $gen_code -eq 0 ]] || die "mmaps_generator failed (exit $gen_code). Check that dbc/, maps/ and vmaps/0000/*.vmtree exist in $OUTPUT_PATH."

    # Safety net: a map that has game files but still no navmesh (the generator skips "junk"/dev maps by default) is built on
    # its own, because naming a map id builds it whatever the skip options say. Without one the server logs
    # "Could not load MMAP ... result: 2".
    missing=""
    for id in $(map_ids); do
        [[ -f "$(printf 'mmaps/%04d.mmap' "$id")" ]] || missing="$missing $id"
    done
    for id in $missing; do
        echo "Building the navigation mesh of map $id on its own..."
        one=(--input "$OUTPUT_PATH" --output "$OUTPUT_PATH" --silent "$id")
        [[ $THREADS -gt 0 ]] && one+=(--threads "$THREADS")
        "$TOOLS_PATH/mmaps_generator" "${one[@]}" || true
    done
    still=""
    for id in $missing; do
        [[ -f "$(printf 'mmaps/%04d.mmap' "$id")" ]] || still="$still $id"
    done
    have=$(mmap_count)
    echo "Navigation meshes: $have maps built; all steps took $(minutes) minutes."
    [[ -n "$still" ]] && echo "WARNING: no navigation mesh could be built for map(s):$still. Usually these maps have no ground to walk on." >&2
    [[ $have -ge 1 ]] || die "No navigation meshes were produced (mmaps/ is empty)."
    set_done mmaps
fi
[[ $RESUME -eq 1 ]] && clean_intermediate

summary "$OUTPUT_PATH" dbc maps Cameras gt vmaps mmaps Buildings
printf '\nDONE (full extraction).\n'
if [[ -d "$OUTPUT_PATH/Buildings" ]]; then
    printf "Tip: 'Buildings/' is intermediate and can be deleted to reclaim ~40 GB:\n"
    printf '    rm -rf "%s/Buildings" "%s/dir_bin"\n' "$OUTPUT_PATH" "$OUTPUT_PATH"
fi
