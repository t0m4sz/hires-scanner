#!/bin/bash

# =============================================================================
# Hi-Res Scanner v5
# =============================================================================

MUSIC_PATH="${MUSIC_PATH:-/music}"
DATA_PATH="${DATA_PATH:-/data}"
LOGS_PATH="${LOGS_PATH:-/logs}"
CACHE_FILE="$DATA_PATH/scan_cache.json"
RESULTS_FILE="$DATA_PATH/scan_results.json"
OVERRIDES_FILE="$DATA_PATH/overrides.json"
LOG_FILE="$LOGS_PATH/scan.log"
PROGRESS_FILE="$DATA_PATH/scan_progress.json"
META_FILE="$DATA_PATH/scan_meta.json"

FULL_SCAN=false
SINGLE_DIR=""

for arg in "$@"; do
    case "$arg" in
        --full) FULL_SCAN=true ;;
        --dir)  shift; SINGLE_DIR="$1" ;;
    esac
done
# Handle --dir value properly
if [[ "$1" == "--dir" ]]; then SINGLE_DIR="$2"; fi
if [[ "$*" =~ --dir\ (.+) ]]; then SINGLE_DIR="${BASH_REMATCH[1]}"; fi

SCAN_START=$(date +%s)
SCAN_ID=$(date -Iseconds)
DONE=0; ERRORS=0; TOTAL_FILES=0; SKIPPED=0; TO_SCAN=0

# =============================================================================
# Graceful shutdown
# =============================================================================
cleanup() {
    log "Skan przerwany przez uzytkownika"
    kill $(jobs -p) 2>/dev/null
    local D=$(($(date +%s) - SCAN_START))
    local DUR=$(printf "%02d:%02d:%02d" $((D/3600)) $(((D%3600)/60)) $((D%60)))
    echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":false,\"interrupted\":true,\"finished\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
    log "Skan zakonczony (przerwany). Albumy: $DONE, Bledy: $ERRORS, Czas: $DUR"
    exit 1
}
trap cleanup SIGTERM SIGINT

# =============================================================================
# Logging
# =============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}
log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

mkdir -p "$DATA_PATH" "$LOGS_PATH"
[ ! -f "$OVERRIDES_FILE" ] && echo '{}' > "$OVERRIDES_FILE"

# =============================================================================
# Single dir mode - scan one album
# =============================================================================
if [ -n "$SINGLE_DIR" ]; then
    log "Tryb: POJEDYNCZY ALBUM: $SINGLE_DIR"
    echo "{\"total\":1,\"done\":0,\"skipped\":0,\"errors\":0,\"running\":true,\"current\":\"$(basename "$SINGLE_DIR")\",\"started\":\"$(date -Iseconds)\",\"singleDir\":true}" > "$PROGRESS_FILE"
    DIRS_TO_SCAN=("$SINGLE_DIR")
    TO_SCAN=1
    SINGLE_MODE=true
else
    SINGLE_MODE=false
    if [ "$FULL_SCAN" = true ] || [ ! -f "$CACHE_FILE" ] || [ ! -f "$RESULTS_FILE" ]; then
        log "Tryb: PELNY SKAN"
        echo '{"scanned":{}}' > "$CACHE_FILE"
        echo '[]' > "$RESULTS_FILE"
    else
        log "Tryb: TYLKO NOWE KATALOGI"
    fi
    [ ! -f "$RESULTS_FILE" ] && echo '[]' > "$RESULTS_FILE"

    log "Szukam katalogow z plikami audio w: $MUSIC_PATH"
    DIRS_WITH_AUDIO=()
    while IFS= read -r -d '' dir; do
        count=$(find "$dir" -maxdepth 1 \( -iname "*.flac" -o -iname "*.aac" -o -iname "*.m4a" \) 2>/dev/null | wc -l)
        [ "$count" -gt 0 ] && DIRS_WITH_AUDIO+=("$dir")
    done < <(find "$MUSIC_PATH" -type d -print0 2>/dev/null)

    log "Znaleziono ${#DIRS_WITH_AUDIO[@]} katalogow z plikami audio"

    DIRS_TO_SCAN=()
    for dir in "${DIRS_WITH_AUDIO[@]}"; do
        dir_hash=$(echo "$dir" | md5sum | cut -d' ' -f1)
        is_scanned=$(python3 -c "
import json
try:
    c=json.load(open('$CACHE_FILE'))
    print('yes' if '$dir_hash' in c.get('scanned',{}) else 'no')
except: print('no')
" 2>>"$LOG_FILE")
        if [ "$is_scanned" = "yes" ] && [ "$FULL_SCAN" = false ]; then
            SKIPPED=$((SKIPPED+1))
        else
            DIRS_TO_SCAN+=("$dir")
        fi
    done

    TO_SCAN=${#DIRS_TO_SCAN[@]}
    log "Do skanowania: $TO_SCAN katalogow (pominieto: $SKIPPED)"
fi

echo "{\"total\":$TO_SCAN,\"done\":0,\"skipped\":$SKIPPED,\"errors\":0,\"running\":true,\"current\":\"Inicjalizacja...\",\"started\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"

# =============================================================================
# get_stream_info FILE -> sr|bits|codec
# =============================================================================
get_stream_info() {
    local file="$1"
    local raw
    raw=$(ffprobe -v quiet \
        -show_entries stream=sample_rate,bits_per_raw_sample,bits_per_sample,codec_name \
        -of default=noprint_wrappers=1 \
        -select_streams a:0 "$file" 2>/dev/null)

    local sr bits_raw bits_sample codec bits
    sr=$(echo          "$raw" | grep '^sample_rate='         | head -1 | cut -d= -f2 | tr -d '[:space:]')
    bits_raw=$(echo    "$raw" | grep '^bits_per_raw_sample=' | head -1 | cut -d= -f2 | tr -d '[:space:]')
    bits_sample=$(echo "$raw" | grep '^bits_per_sample='     | head -1 | cut -d= -f2 | tr -d '[:space:]')
    codec=$(echo       "$raw" | grep '^codec_name='          | head -1 | cut -d= -f2 | tr -d '[:space:]')

    if [ -n "$bits_raw" ] && [ "$bits_raw" != "0" ]; then bits="$bits_raw"; else bits="$bits_sample"; fi
    echo "${sr:-0}|${bits:-0}|${codec:-unknown}"
}

# =============================================================================
# get_album_tags FILE -> artist|album
# album_artist first, artist as fallback
# =============================================================================
get_album_tags() {
    local file="$1"
    local artist album

    # album_artist is the canonical tag for artist grouping
    artist=$(ffprobe -v quiet \
        -show_entries format_tags=album_artist \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | head -1)

    [ -z "$artist" ] && artist=$(ffprobe -v quiet \
        -show_entries format_tags=ALBUMARTIST \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | head -1)

    [ -z "$artist" ] && artist=$(ffprobe -v quiet \
        -show_entries format_tags=artist \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | head -1)

    album=$(ffprobe -v quiet \
        -show_entries format_tags=album \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | head -1)

    echo "${artist}|${album}"
}

# =============================================================================
# analyze_spectrum FILE SR EXT -> strong|weak|cliff|cliff_unclear|native|meta_only|error
# =============================================================================
analyze_spectrum() {
    local file="$1" sr="$2" ext="$3"

    [ "$ext" = "aac" ] || [ "$ext" = "m4a" ] && echo "meta_only" && return
    [ "$sr" -lt 88200 ] 2>/dev/null && echo "native" && return

    local tmp_below tmp_above tmp_above30
    tmp_below=$(mktemp); tmp_above=$(mktemp); tmp_above30=$(mktemp)

    sox "$file" -n remix 1 sinc -22000 stat 2>"$tmp_below"  &
    local p1=$!
    sox "$file" -n remix 1 sinc  22000 stat 2>"$tmp_above"  &
    local p2=$!
    sox "$file" -n remix 1 sinc  30000 stat 2>"$tmp_above30" &
    local p3=$!
    wait $p1 $p2 $p3

    local e_below e_above e_above30
    e_below=$(awk '/RMS.*amplitude/{print $NF}'  "$tmp_below")
    e_above=$(awk '/RMS.*amplitude/{print $NF}'  "$tmp_above")
    e_above30=$(awk '/RMS.*amplitude/{print $NF}' "$tmp_above30")
    rm -f "$tmp_below" "$tmp_above" "$tmp_above30"

    [ -z "$e_below" ] || [ "$e_below" = "0" ] && echo "error" && return

    python3 -c "
try:
    b=float('${e_below}' or '0'); a=float('${e_above}' or '0'); a3=float('${e_above30}' or '0')
    if b<=0: print('error')
    elif a/b<0.001: print('cliff')
    elif a/b<0.005: print('cliff_unclear')
    elif a/b>=0.02 and a3/b>=0.005: print('strong')
    elif a/b>=0.005: print('weak')
    else: print('cliff_unclear')
except: print('error')
" 2>>"$LOG_FILE"
}

# =============================================================================
# classify_file FILE -> RAWSTATUS:sr:bits
# =============================================================================
classify_file() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    local info sr bits codec
    info=$(get_stream_info "$file")
    sr=$(echo "$info"|cut -d'|' -f1); bits=$(echo "$info"|cut -d'|' -f2); codec=$(echo "$info"|cut -d'|' -f3)
    sr=${sr:-0}; bits=${bits:-0}

    if [ "$ext" = "aac" ] || [ "$ext" = "m4a" ] || [ "$codec" = "aac" ]; then
        [ "$sr" -ge 88200 ] 2>/dev/null && echo "NATIVE_HIRES_META:$sr:$bits" && return
        [ "$bits" -gt 16  ] 2>/dev/null && echo "HIRES_44_48_META:$sr:$bits"  && return
        echo "CD_QUALITY_META:$sr:$bits"; return
    fi

    if [ "$bits" -le 16 ] 2>/dev/null; then
        { [ "$sr" -eq 44100 ] || [ "$sr" -eq 48000 ]; } 2>/dev/null && echo "CD_QUALITY:$sr:$bits" && return
    fi

    if [ "$bits" -gt 16 ] 2>/dev/null; then
        { [ "$sr" -eq 44100 ] || [ "$sr" -eq 48000 ]; } 2>/dev/null && echo "HIRES_44_48:$sr:$bits" && return
    fi

    if [ "$sr" -ge 88200 ] 2>/dev/null; then
        local sp; sp=$(analyze_spectrum "$file" "$sr" "$ext")
        case "$sp" in
            strong)        echo "NATIVE_HIRES:$sr:$bits" ;;
            weak)          echo "NATIVE_HIRES_WEAK:$sr:$bits" ;;
            cliff)         echo "UPSAMPLED:$sr:$bits" ;;
            cliff_unclear) echo "UPSAMPLED_UNCLEAR:$sr:$bits" ;;
            native)        echo "CD_QUALITY:$sr:$bits" ;;
            meta_only)     echo "NATIVE_HIRES_META:$sr:$bits" ;;
            *)             echo "UNKNOWN:$sr:$bits" ;;
        esac
        return
    fi
    echo "UNKNOWN:$sr:$bits"
}

map_status() {
    case "$1" in
        NATIVE_HIRES)      echo "NATIVE HIRES|Silny sygnal, lagodny zanik" ;;
        NATIVE_HIRES_WEAK) echo "NATIVE HIRES?|Sygnal slaby lub nieregularny" ;;
        NATIVE_HIRES_META) echo "NATIVE HIRES (meta)|Tylko metadane, brak analizy spektrum" ;;
        UPSAMPLED)         echo "UPSAMPLED|Ostry klif na 22kHz" ;;
        UPSAMPLED_UNCLEAR) echo "UPSAMPLED?|Sygnal niejednoznaczny, zalecana weryfikacja" ;;
        HIRES_44_48)       echo "HI-RES 44/48|24bit, natywna czestotliwosc" ;;
        HIRES_44_48_META)  echo "HI-RES 44/48 (meta)|Tylko metadane" ;;
        CD_QUALITY)        echo "CD QUALITY|16bit, natywna jakosc" ;;
        CD_QUALITY_META)   echo "CD QUALITY (meta)|Tylko metadane" ;;
        ERROR)             echo "ERROR|Blad podczas analizy" ;;
        *)                 echo "UNKNOWN|Nie udalo sie okreslic statusu" ;;
    esac
}

map_label() {
    case "$1" in
        NATIVE_HIRES)      echo "NATIVE HIRES" ;;
        NATIVE_HIRES_WEAK) echo "NATIVE HIRES?" ;;
        NATIVE_HIRES_META) echo "NATIVE HIRES (meta)" ;;
        UPSAMPLED)         echo "UPSAMPLED" ;;
        UPSAMPLED_UNCLEAR) echo "UPSAMPLED?" ;;
        HIRES_44_48)       echo "HI-RES 44/48" ;;
        HIRES_44_48_META)  echo "HI-RES 44/48 (meta)" ;;
        CD_QUALITY)        echo "CD QUALITY" ;;
        CD_QUALITY_META)   echo "CD QUALITY (meta)" ;;
        ERROR)             echo "ERROR" ;;
        *)                 echo "UNKNOWN" ;;
    esac
}

# =============================================================================
# Main loop
# =============================================================================
for dir in "${DIRS_TO_SCAN[@]}"; do
    DONE=$((DONE+1))

    cur=$(basename "$dir" | sed 's/"/\\"/g')
    echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":true,\"current\":\"$cur\",\"started\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
    log "[$DONE/$TO_SCAN] Skanowanie: $dir"

    mapfile -t audio_files < <(find "$dir" -maxdepth 1 \
        \( -iname "*.flac" -o -iname "*.aac" -o -iname "*.m4a" \) 2>/dev/null | sort)
    [ ${#audio_files[@]} -eq 0 ] && continue
    TOTAL_FILES=$((TOTAL_FILES + ${#audio_files[@]}))

    first="${audio_files[0]}"
    tags=$(get_album_tags "$first")
    artist=$(echo "$tags"|cut -d'|' -f1)
    album=$(echo  "$tags"|cut -d'|' -f2)

    dir_base=$(basename "$dir")
    is_vol=false
    echo "$dir_base" | grep -iqE "^(vol|volume|disc|disk|cd|part)[\.\s_-]*[0-9]" && is_vol=true

    if [ "$is_vol" = true ]; then
        pdir=$(dirname "$dir")
        [ -z "$artist" ] && artist=$(basename "$(dirname "$pdir")")
        if [ -z "$album" ]; then
            palb=$(basename "$pdir" | sed 's/^\[[0-9]\{4\}\][[:space:]]*[-]*[[:space:]]*//')
            album="${palb} (${dir_base})"
        else
            album="${album} (${dir_base})"
        fi
    else
        [ -z "$artist" ] && artist=$(basename "$(dirname "$dir")")
        [ -z "$album"  ] && album=$(echo "$dir_base" | sed 's/^\[[0-9]\{4\}\][[:space:]]*[-]*[[:space:]]*//')
    fi

    rel="${dir#$MUSIC_PATH}"
    win_path="Z:\\Muzyka\\Tidal$(echo "$rel" | sed 's|/|\\|g')"

    declare -A status_counts
    for f in "${audio_files[@]}"; do
        result=$(classify_file "$f" 2>>"$LOG_FILE")
        if [ -z "$result" ]; then
            log_error "Pusta odpowiedz dla: $f"; ERRORS=$((ERRORS+1)); continue
        fi
        raw="${result%%:*}"
        if [ -n "${status_counts[$raw]+_}" ]; then
            status_counts[$raw]=$((${status_counts[$raw]}+1))
        else
            status_counts[$raw]=1
        fi
    done

    uc=${#status_counts[@]}
    album_status=""; album_confidence=""; tooltip=""
    if [ "$uc" -eq 0 ]; then
        album_status="ERROR"; album_confidence="Blad podczas analizy"
    elif [ "$uc" -eq 1 ]; then
        raw_key="${!status_counts[@]}"
        mapped=$(map_status "$raw_key")
        album_status=$(echo    "$mapped"|cut -d'|' -f1)
        album_confidence=$(echo "$mapped"|cut -d'|' -f2)
    else
        album_status="MIXED"
        parts=()
        for s in "${!status_counts[@]}"; do parts+=("${status_counts[$s]}x $(map_label "$s")"); done
        tooltip=$(IFS="|"; echo "${parts[*]}")
    fi

    # Update cache (skip in single mode)
    if [ "$SINGLE_MODE" = false ]; then
        dir_hash=$(echo "$dir" | md5sum | cut -d' ' -f1)
        python3 -c "
import json
try:
    with open('$CACHE_FILE') as f: cache=json.load(f)
except: cache={'scanned':{}}
cache.setdefault('scanned',{})['$dir_hash']='$(date -Iseconds)'
with open('$CACHE_FILE','w') as f: json.dump(cache,f)
" 2>>"$LOG_FILE"
    fi

    # Save result - apply overrides UNLESS this is single-dir rescan (override cleared)
    export _A="$artist" _B="$album" _P="$dir" _W="$win_path"
    export _S="$album_status" _C="$album_confidence" _T="$tooltip"
    export _F="${#audio_files[@]}" _D="$(date -Iseconds)" _SI="$SCAN_ID"
    export _RF="$RESULTS_FILE" _OF="$OVERRIDES_FILE" _SINGLE="$SINGLE_MODE"

    python3 << 'PYEOF' 2>>"$LOG_FILE"
import json, os
from datetime import datetime

path  = os.environ.get('_P','')
rf    = os.environ.get('_RF','/data/scan_results.json')
ovf   = os.environ.get('_OF','/data/overrides.json')
is_single = os.environ.get('_SINGLE','false') == 'true'

e = {
    'artist':     os.environ.get('_A','').strip(),
    'album':      os.environ.get('_B','').strip(),
    'path':       path,
    'winPath':    os.environ.get('_W',''),
    'status':     os.environ.get('_S','UNKNOWN'),
    'confidence': os.environ.get('_C',''),
    'tooltip':    os.environ.get('_T',''),
    'fileCount':  int(os.environ.get('_F','0')),
    'scannedAt':  os.environ.get('_D',''),
    'scanId':     os.environ.get('_SI',''),
    'manual':     False,
}

# Load overrides
try:
    with open(ovf) as f: overrides = json.load(f)
except: overrides = {}

if is_single:
    # Single-dir rescan: remove override so scan result is used
    if path in overrides:
        del overrides[path]
        with open(ovf,'w') as f: json.dump(overrides, f, ensure_ascii=False, indent=2)
else:
    # Normal scan: apply override if exists
    if path in overrides:
        ov = overrides[path]
        e['status']     = ov.get('status', e['status'])
        e['confidence'] = ov.get('confidence', 'Recznie ustawiony')
        e['manual']     = True

try:
    with open(rf) as f: results = json.load(f)
except: results = []

results = [r for r in results if r.get('path') != path]
results.append(e)
with open(rf,'w') as f: json.dump(results, f, ensure_ascii=False, indent=2)
PYEOF

    unset status_counts
    declare -A status_counts
done

# =============================================================================
# Finalize
# =============================================================================
SCAN_END=$(date +%s)
D=$((SCAN_END - SCAN_START))
DUR=$(printf "%02d:%02d:%02d" $((D/3600)) $(((D%3600)/60)) $((D%60)))

if [ "$SINGLE_MODE" = false ]; then
    export _RF="$RESULTS_FILE" _MF="$META_FILE"
    export _DONE="$DONE" _ERR="$ERRORS" _DUR="$DUR" _FULL="$FULL_SCAN" _SI="$SCAN_ID"
    python3 << 'PYEOF' 2>>"$LOG_FILE"
import json, os
from datetime import datetime
rf=os.environ.get('_RF','/data/scan_results.json'); mf=os.environ.get('_MF','/data/scan_meta.json')
try:
    with open(rf) as f: results=json.load(f)
    ta=len(results); tf=sum(r.get('fileCount',0) for r in results)
except: ta=0; tf=0
meta={
    'lastScan':datetime.now().isoformat(),
    'totalScanned':int(os.environ.get('_DONE','0')),
    'totalAlbums':ta, 'totalFiles':tf,
    'errors':int(os.environ.get('_ERR','0')),
    'duration':os.environ.get('_DUR','00:00:00'),
    'mode':'full' if os.environ.get('_FULL')=='true' else 'incremental',
    'lastScanId': os.environ.get('_SI',''),
}
with open(mf,'w') as f: json.dump(meta,f)
PYEOF
fi

echo "{\"total\":$TO_SCAN,\"done\":$DONE,\"skipped\":$SKIPPED,\"errors\":$ERRORS,\"running\":false,\"singleDir\":$( [ "$SINGLE_MODE" = true ] && echo true || echo false ),\"finished\":\"$(date -Iseconds)\"}" > "$PROGRESS_FILE"
log "Skan zakonczony. Albumy: $DONE, Pliki: $TOTAL_FILES, Bledy: $ERRORS, Czas: $DUR"
