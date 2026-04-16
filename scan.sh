#!/bin/bash
# Media Library Scanner v4
# Optimisations: first-file-only ffprobe, batch cache/results write, fixed Vol.1 regex

MUSIC_PATH="${MUSIC_PATH:-/music}"
DATA_PATH="${DATA_PATH:-/data}"
LOGS_PATH="${LOGS_PATH:-/logs}"
CACHE_FILE="$DATA_PATH/scan_cache.json"
RESULTS_FILE="$DATA_PATH/scan_results.json"
LOG_FILE="$LOGS_PATH/scan.log"
PROGRESS_FILE="$DATA_PATH/scan_progress.json"
META_FILE="$DATA_PATH/scan_meta.json"

FULL_SCAN=false; SINGLE_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in --full) FULL_SCAN=true; shift ;; --dir) SINGLE_DIR="$2"; shift 2 ;; *) shift ;; esac
done

SCAN_START=$(date +%s)
SCAN_ID=$(date -Iseconds)
DONE=0; ERRORS=0; TOTAL_FILES=0; SKIPPED=0; TO_SCAN=0

cleanup() {
    log "Skan przerwany"
    kill $(jobs -p) 2>/dev/null
    local D=$(($(date +%s)-SCAN_START))
    echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":false,\"interrupted\":true,\"finished\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
    log "Przerwany. Albumy:$DONE Czas:$(printf "%02d:%02d:%02d" $((D/3600)) $(((D%3600)/60)) $((D%60)))"
    # Save whatever was collected so far
    [ -n "$TMP_RESULTS" ] && [ -f "$TMP_RESULTS" ] && flush_results
    exit 1
}
trap cleanup SIGTERM SIGINT

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2; }

mkdir -p "$DATA_PATH" "$LOGS_PATH"

# ── INIT ──────────────────────────────────────────────────────────────────────
if [ -n "$SINGLE_DIR" ]; then
    log "Tryb: POJEDYNCZY: $SINGLE_DIR"
    DIRS_TO_SCAN=("$SINGLE_DIR"); TO_SCAN=1; SINGLE_MODE=true
else
    SINGLE_MODE=false
    if [ "$FULL_SCAN" = true ] || [ ! -f "$CACHE_FILE" ] || [ ! -f "$RESULTS_FILE" ]; then
        log "Tryb: PELNY SKAN"; echo '{"scanned":{}}' > "$CACHE_FILE"; echo '[]' > "$RESULTS_FILE"
    else
        log "Tryb: TYLKO NOWE"
    fi
    [ ! -f "$RESULTS_FILE" ] && echo '[]' > "$RESULTS_FILE"

    log "Szukam katalogow audio w: $MUSIC_PATH"
    DIRS_WITH_AUDIO=()
    while IFS= read -r -d '' dir; do
        # Use find with -quit style: just check if any audio file exists (faster than wc -l)
        f=$(find "$dir" -maxdepth 1 \( -iname "*.flac" -o -iname "*.aac" -o -iname "*.m4a" -o -iname "*.mp3" \) -print -quit 2>/dev/null)
        [ -n "$f" ] && DIRS_WITH_AUDIO+=("$dir")
    done < <(find "$MUSIC_PATH" -type d -print0 2>/dev/null)
    log "Znaleziono ${#DIRS_WITH_AUDIO[@]} katalogow"

    # ── BULK CACHE CHECK (single python3 call) ────────────────────────────────
    HASHES=()
    for d in "${DIRS_WITH_AUDIO[@]}"; do HASHES+=("$(echo "$d"|md5sum|cut -d' ' -f1)"); done

    export _CF="$CACHE_FILE" _FULL="$FULL_SCAN"
    UNCACHED_IDXS=$(printf '%s\n' "${HASHES[@]}" | python3 -c "
import json,os,sys
cf=os.environ.get('_CF','/data/scan_cache.json')
full=os.environ.get('_FULL','false')=='true'
try:
    with open(cf) as f: cache=json.load(f)
except: cache={'scanned':{}}
scanned=cache.get('scanned',{})
for i,h in enumerate(sys.stdin.read().strip().split('\n')):
    if h and (full or h not in scanned): print(i)
" 2>>"$LOG_FILE")

    DIRS_TO_SCAN=()
    if [ -n "$UNCACHED_IDXS" ]; then
        while IFS= read -r idx; do
            DIRS_TO_SCAN+=("${DIRS_WITH_AUDIO[$idx]}")
        done <<< "$UNCACHED_IDXS"
    fi
    SKIPPED=$(( ${#DIRS_WITH_AUDIO[@]} - ${#DIRS_TO_SCAN[@]} ))
    TO_SCAN=${#DIRS_TO_SCAN[@]}
    log "Do skanowania: $TO_SCAN (pominieto: $SKIPPED)"
fi

echo "{\"total\":$TO_SCAN,\"done\":0,\"skipped\":$SKIPPED,\"errors\":0,\"running\":true,\"current\":\"Inicjalizacja...\",\"started\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"

# =============================================================================
# PRE-BUILD DISC MAP
# disc_map[path]     = disc number from tag (or "")
# vol_subdir_map[p]  = "yes" if any immediate subdir of p has name matching Vol.2+
# =============================================================================
declare -A disc_map
declare -A vol_subdir_map

log "Buduje mape disc/vol..."
DIRS_FOR_MAP=("${DIRS_WITH_AUDIO[@]}")
[ "$SINGLE_MODE" = true ] && DIRS_FOR_MAP=("${DIRS_TO_SCAN[@]}")

for d in "${DIRS_FOR_MAP[@]}"; do
    f=$(find "$d" -maxdepth 1 \( -iname "*.flac" -o -iname "*.aac" -o -iname "*.m4a" \) -print -quit 2>/dev/null)
    if [ -n "$f" ]; then
        raw=$(ffprobe -v quiet -show_entries format_tags=disc \
            -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
        disc_map["$d"]="${raw:-}"
    fi
    # FIX: use [ ._-]* instead of [\.\s_-]* so "Vol. 2" (with space) also matches
    dbase=$(basename "$d")
    if echo "$dbase" | grep -iqE "^(vol|volume|disc|disk|cd|part)[ ._-]*[2-9]"; then
        vol_subdir_map["$(dirname "$d")"]="yes"
    fi
done

# =============================================================================
# PURE-BASH HELPERS
# =============================================================================
sr_to_khz() {
    awk -v s="$1" 'BEGIN{k=s/1000; if(k==int(k)) printf "%dkHz\n",k; else printf "%.1fkHz\n",k}'
}

classify_file_bash() {
    local sr="$1" bits="$2" codec="$3" ext="$4"
    case "$ext" in
        mp3) echo "MP3"; return ;;
        aac|m4a) [ "$sr" -gt 0 ] && echo "AAC/$(sr_to_khz "$sr")" || echo "AAC"; return ;;
    esac
    case "$codec" in
        mp3|mp2) echo "MP3"; return ;;
        aac) [ "$sr" -gt 0 ] && echo "AAC/$(sr_to_khz "$sr")" || echo "AAC"; return ;;
    esac
    if [ "$sr" -gt 0 ] 2>/dev/null && [ "$bits" -gt 0 ] 2>/dev/null; then
        echo "${bits}bit/$(sr_to_khz "$sr")"
    else
        echo "Unknown"
    fi
}

get_quality_bash() {
    local sr="$1" bits="$2" fmt="$3"
    case "$fmt" in MP3|Unknown|AAC*) echo "Other"; return ;; esac
    if   [ "$sr" -gt 48000 ] 2>/dev/null; then echo "HiRes"
    elif [ "$bits" -gt 16  ] 2>/dev/null && { [ "$sr" -eq 44100 ] || [ "$sr" -eq 48000 ]; } 2>/dev/null; then echo "HiRes 44/48"
    elif [ "$bits" -le 16  ] 2>/dev/null && { [ "$sr" -eq 44100 ] || [ "$sr" -eq 48000 ]; } 2>/dev/null; then echo "CD Quality"
    else echo "Other"; fi
}

# =============================================================================
# BATCH RESULT / CACHE BUFFERS
# Instead of writing JSON per-album, accumulate and flush at end
# =============================================================================
TMP_RESULTS=$(mktemp)      # newline-delimited JSON objects
TMP_CACHE_HASHES=$(mktemp) # hash TAB timestamp, one per line
TMP_CACHE_PATHS=$(mktemp)  # dir path, one per line (parallel with hashes)

flush_results() {
    # Merge TMP_RESULTS into RESULTS_FILE and update cache – single python3 call
    export _RF="$RESULTS_FILE" _CF="$CACHE_FILE" _TR="$TMP_RESULTS" _TC="$TMP_CACHE_HASHES"
    python3 << 'PYEOF' 2>>"$LOG_FILE"
import json, os
rf=os.environ.get('_RF','/data/scan_results.json')
cf=os.environ.get('_CF','/data/scan_cache.json')
tr=os.environ.get('_TR','')
tc=os.environ.get('_TC','')

# Load existing results
try:
    with open(rf) as f: results=json.load(f)
except: results=[]

# Load new entries from temp file
new_entries = []
if tr:
    try:
        with open(tr) as f:
            for line in f:
                line=line.strip()
                if line:
                    new_entries.append(json.loads(line))
    except Exception as e:
        import sys; print(f"Error reading tmp results: {e}", file=sys.stderr)

# Merge: remove existing entries for same paths, append new
new_paths = {e['path'] for e in new_entries}
results = [r for r in results if r.get('path') not in new_paths]
results.extend(new_entries)
with open(rf,'w') as f: json.dump(results, f, ensure_ascii=False, indent=2)

# Update cache
try:
    with open(cf) as f: cache=json.load(f)
except: cache={'scanned':{}}
if tc:
    try:
        with open(tc) as f:
            for line in f:
                line=line.strip()
                if '\t' in line:
                    h,ts = line.split('\t',1)
                    cache.setdefault('scanned',{})[h]=ts
    except: pass
with open(cf,'w') as f: json.dump(cache,f)
PYEOF
}

# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
for dir in "${DIRS_TO_SCAN[@]}"; do
    DONE=$((DONE+1))
    if [ $((DONE % 5)) -eq 0 ] || [ "$DONE" -eq 1 ] || [ "$DONE" -eq "$TO_SCAN" ]; then
        cur=$(basename "$dir"|sed 's/"/\\"/g')
        echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":true,\"current\":\"$cur\",\"started\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
    fi
    log "[$DONE/$TO_SCAN] $dir"

    mapfile -t audio_files < <(find "$dir" -maxdepth 1 \
        \( -iname "*.flac" -o -iname "*.aac" -o -iname "*.m4a" -o -iname "*.mp3" \) 2>/dev/null | sort)
    [ ${#audio_files[@]} -eq 0 ] && continue
    TOTAL_FILES=$((TOTAL_FILES+${#audio_files[@]}))

    # ── ONE ffprobe FOR FIRST FILE: get stream info + all tags ────────────────
    first="${audio_files[0]}"
    fraw=$(ffprobe -v quiet \
        -show_entries stream=sample_rate,bits_per_raw_sample,bits_per_sample,codec_name:format_tags=album_artist,artist,album,disc \
        -of default=noprint_wrappers=1 "$first" 2>/dev/null)

    _sr=$(echo "$fraw"|grep '^sample_rate='         |head -1|cut -d= -f2|tr -d '[:space:]')
    _br=$(echo "$fraw"|grep '^bits_per_raw_sample=' |head -1|cut -d= -f2|tr -d '[:space:]')
    _bs=$(echo "$fraw"|grep '^bits_per_sample='     |head -1|cut -d= -f2|tr -d '[:space:]')
    _co=$(echo "$fraw"|grep '^codec_name='          |head -1|cut -d= -f2|tr -d '[:space:]')
    _aa=$(echo "$fraw"|grep -i 'album_artist='      |head -1|cut -d= -f2-)
    [ -z "$_aa" ] && _aa=$(echo "$fraw"|grep -i 'albumartist='|head -1|cut -d= -f2-)
    _art=$(echo "$fraw"|grep -i '^TAG:artist=\|^artist='|head -1|cut -d= -f2-)
    _alb=$(echo "$fraw"|grep -i '^TAG:album=\|^album='  |head -1|cut -d= -f2-)
    _disc=$(echo "$fraw"|grep -i '^TAG:disc=\|^disc='   |head -1|cut -d= -f2-|grep -oE '[0-9]+')
    [ -n "$_br" ] && [ "$_br" != "0" ] && _bits="$_br" || _bits="$_bs"

    artist="${_aa:-${_art}}"
    album="${_alb}"
    disc="${_disc}"
    artist=$(echo "$artist"|sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    album=$(echo  "$album" |sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    dir_base=$(basename "$dir")

    # ── DISC / VOL NAMING ────────────────────────────────────────────────────
    if [ -n "$disc" ] && [ "$disc" -gt 1 ] 2>/dev/null; then
        album="${album} (Vol. ${disc})"
    else
        need_vol1=false

        # Check 1: any immediate subdir is in disc_map with disc>1?
        while IFS= read -r -d '' sub; do
            sd="${disc_map[$sub]:-}"
            [ -n "$sd" ] && [ "$sd" -gt 1 ] 2>/dev/null && need_vol1=true && break
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

        # Check 2: vol_subdir_map says this dir has a Vol.2+ subdir by name?
        if [ "$need_vol1" = false ] && [ "${vol_subdir_map[$dir]:-}" = "yes" ]; then
            need_vol1=true
        fi

        # Check 3: this dir's name looks like Vol.1 – check siblings via vol_subdir_map
        # FIX: [ ._-]* correctly matches both "Vol.1" and "Vol. 1" (with space)
        if [ "$need_vol1" = false ] && echo "$dir_base" | grep -iqE "^(vol|volume|disc|disk|cd|part)[ ._-]*1($|[^0-9])"; then
            pdir=$(dirname "$dir")
            if [ "${vol_subdir_map[$pdir]:-}" = "yes" ]; then
                need_vol1=true
            else
                # Fallback: directly scan siblings in disc_map
                while IFS= read -r -d '' sib; do
                    [ "$sib" = "$dir" ] && continue
                    sd="${disc_map[$sib]:-}"
                    [ -n "$sd" ] && [ "$sd" -gt 1 ] 2>/dev/null && need_vol1=true && break
                done < <(find "$pdir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
            fi
        fi

        [ "$need_vol1" = true ] && album="${album} (Vol. 1)"
    fi

    [ -z "$artist" ] && artist=$(basename "$(dirname "$dir")")
    [ -z "$album"  ] && album=$(echo "$dir_base"|sed 's/^\[[0-9]\{4\}\][[:space:]]*[-]*[[:space:]]*//')

    rel="${dir#$MUSIC_PATH}"
    win_path="Z:\\Muzyka\\Tidal$(echo "$rel"|sed 's|/|\\|g')"

    # ── FORMAT CLASSIFICATION: probe each file individually for accuracy
    declare -A fmt_counts

    for f in "${audio_files[@]}"; do
        raw=$(ffprobe -v quiet \
            -show_entries stream=sample_rate,bits_per_raw_sample,bits_per_sample,codec_name \
            -of default=noprint_wrappers=1 -select_streams a:0 "$f" 2>/dev/null)
        sr=$(echo "$raw"|grep '^sample_rate='        |head -1|cut -d= -f2|tr -d '[:space:]')
        br=$(echo "$raw"|grep '^bits_per_raw_sample='|head -1|cut -d= -f2|tr -d '[:space:]')
        bs=$(echo "$raw"|grep '^bits_per_sample='    |head -1|cut -d= -f2|tr -d '[:space:]')
        co=$(echo "$raw"|grep '^codec_name='         |head -1|cut -d= -f2|tr -d '[:space:]')
        [ -n "$br" ] && [ "$br" != "0" ] && bits="$br" || bits="$bs"
        ext="${f##*.}"; ext=$(echo "$ext"|tr '[:upper:]' '[:lower:]')
        fmt=$(classify_file_bash "${sr:-0}" "${bits:-0}" "${co:-unknown}" "$ext")

        if [ -n "${fmt_counts[$fmt]+_}" ]; then fmt_counts[$fmt]=$((${fmt_counts[$fmt]}+1))
        else fmt_counts[$fmt]=1; fi
    done

    uf=${#fmt_counts[@]}
    album_fmt=""; album_quality=""; tooltip=""
    if [ "$uf" -eq 0 ]; then
        album_fmt="Unknown"; album_quality="Other"
    elif [ "$uf" -eq 1 ]; then
        album_fmt="${!fmt_counts[@]}"
        album_quality=$(get_quality_bash "${_sr:-0}" "${_bits:-0}" "$album_fmt")
    else
        album_fmt="MIXED"; album_quality="Mixed"
        parts=()
        for f in "${!fmt_counts[@]}"; do parts+=("${fmt_counts[$f]}x $f"); done
        tooltip=$(IFS="|"; echo "${parts[*]}")
    fi

    # ── BUFFER RESULTS (write to temp file, flush at end) ─────────────────────
    # Escape values for JSON using printf
    esc() { printf '%s' "$1" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')"; }

    python3 -c "
import json, os, sys
e = json.dumps({
    'artist':    os.environ.get('_A','').strip(),
    'album':     os.environ.get('_B','').strip(),
    'path':      os.environ.get('_P',''),
    'winPath':   os.environ.get('_W',''),
    'format':    os.environ.get('_FMT','Unknown'),
    'quality':   os.environ.get('_Q','Other'),
    'tooltip':   os.environ.get('_T',''),
    'fileCount': int(os.environ.get('_FC','0')),
    'scannedAt': os.environ.get('_D',''),
    'scanId':    os.environ.get('_SI',''),
}, ensure_ascii=False)
print(e)
" _A="$artist" _B="$album" _P="$dir" _W="$win_path" \
  _FMT="$album_fmt" _Q="$album_quality" _T="$tooltip" \
  _FC="${#audio_files[@]}" _D="$(date -Iseconds)" _SI="$SCAN_ID" >> "$TMP_RESULTS" 2>>"$LOG_FILE"

    # Buffer cache hash for batch write
    if [ "$SINGLE_MODE" = false ]; then
        dh=$(echo "$dir"|md5sum|cut -d' ' -f1)
        echo "${dh}	$(date -Iseconds)" >> "$TMP_CACHE_HASHES"
    fi

    unset fmt_counts
    declare -A fmt_counts

    # Flush every 100 albums to avoid huge temp files and allow partial results
    if [ $((DONE % 100)) -eq 0 ]; then
        flush_results
        > "$TMP_RESULTS"
        > "$TMP_CACHE_HASHES"
    fi
done

# Final flush
flush_results
rm -f "$TMP_RESULTS" "$TMP_CACHE_HASHES" "$TMP_CACHE_PATHS"

# ── FINALIZE ──────────────────────────────────────────────────────────────────
SCAN_END=$(date +%s); D=$((SCAN_END-SCAN_START))
DUR=$(printf "%02d:%02d:%02d" $((D/3600)) $(((D%3600)/60)) $((D%60)))

if [ "$SINGLE_MODE" = false ]; then
    export _RF="$RESULTS_FILE" _MF="$META_FILE" _DONE="$DONE" _ERR="$ERRORS" _DUR="$DUR" _FULL="$FULL_SCAN" _SI="$SCAN_ID"
    python3 << 'PYEOF' 2>>"$LOG_FILE"
import json, os
from datetime import datetime
rf=os.environ.get('_RF','/data/scan_results.json'); mf=os.environ.get('_MF','/data/scan_meta.json')
try:
    with open(rf) as f: results=json.load(f)
    ta=len(results); tf=sum(r.get('fileCount',0) for r in results)
except: ta=0; tf=0
meta={
    'lastScan': datetime.now().isoformat(), 'totalScanned': int(os.environ.get('_DONE','0')),
    'totalAlbums': ta, 'totalFiles': tf, 'errors': int(os.environ.get('_ERR','0')),
    'duration': os.environ.get('_DUR','00:00:00'),
    'mode': 'full' if os.environ.get('_FULL')=='true' else 'incremental',
    'lastScanId': os.environ.get('_SI',''),
}
with open(mf,'w') as f: json.dump(meta,f)
PYEOF
fi

echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":false,\"singleDir\":$([ "$SINGLE_MODE" = true ] && echo true || echo false),\"finished\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
log "Zakonczono. Albumy:$DONE Pliki:$TOTAL_FILES Bledy:$ERRORS Czas:$DUR"
