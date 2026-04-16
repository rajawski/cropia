#!/bin/bash
# =============================================================================
#  cropia  v1.1.0
#  Lossless-aware batch image crop CLI
#
#  Usage: cropia [OPTIONS] INPUT_DIR OUTPUT_DIR
#  Run with --help for full documentation.
# =============================================================================

VERSION="1.1.0"
SCRIPT_NAME="$(basename "$0")"

# ── Defaults ──────────────────────────────────────────────────────────────────
INPUT_DIR=""
OUTPUT_DIR=""
RATIO="3:2"
GRAVITY="bottom"
FORMAT=""          # empty = preserve input format
SUFFIX=""
OVERWRITE=false
SKIP=false
DRY_RUN=false
VERBOSE=false
RECURSIVE=false
PATTERN=""         # empty = all supported image types
MIN_MP=0
MAX_MP=0
PREVIEW=false
LOG_FILE=""
CONFIG_FILE=""

# ── Runtime counters ──────────────────────────────────────────────────────────
COUNT_FOUND=0
COUNT_PROCESSED=0
COUNT_SKIPPED=0
COUNT_FAILED=0
BYTES_SAVED=0
declare -a LOG_ENTRIES=()

# ── ANSI colors (gracefully degrade in non-TTY contexts) ──────────────────────
if [[ -t 1 ]]; then
  CR='\033[0;31m'   # red
  CG='\033[0;32m'   # green
  CY='\033[1;33m'   # yellow
  CB='\033[0;34m'   # blue
  CW='\033[1m'      # bold
  CD='\033[2m'      # dim
  CZ='\033[0m'      # reset
else
  CR=''; CG=''; CY=''; CB=''; CW=''; CD=''; CZ=''
fi

# =============================================================================
#  UTILITIES
# =============================================================================

info()    { echo -e "${CB}i${CZ}  $*"; }
ok()      { echo -e "${CG}+${CZ}  $*"; }
warn()    { echo -e "${CY}!${CZ}  $*"; }
err()     { echo -e "${CR}x${CZ}  $*" >&2; }
verbose() { $VERBOSE && echo -e "    ${CD}$*${CZ}"; }
die()     { err "$*"; exit 1; }
hr()      { echo -e "${CD}────────────────────────────────────────────${CZ}"; }

lc() {
  # Lowercase a string - compatible with bash 3.2 (macOS default)
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

human_bytes() {
  local b=$1
  if   (( b >= 1073741824 )); then awk "BEGIN { printf \"%.1f GB\", $b/1073741824 }"
  elif (( b >= 1048576 ))    ; then awk "BEGIN { printf \"%.1f MB\", $b/1048576 }"
  elif (( b >= 1024 ))       ; then awk "BEGIN { printf \"%.1f KB\", $b/1024 }"
  else echo "${b} bytes"
  fi
}

# =============================================================================
#  USAGE
# =============================================================================

usage() {
  cat <<EOF

${CW}cropia${CZ} v${VERSION}  -  Lossless-aware batch image cropper

${CW}USAGE${CZ}
  $SCRIPT_NAME [OPTIONS] INPUT_DIR OUTPUT_DIR

  Positional arguments default to ./input and ./cropped if omitted.

${CW}CROP${CZ}
  --ratio A:B         Aspect ratio (default: 3:2)
                      Any integer pair works. Common values:
                        3:2   Standard photo       16:9  Widescreen
                        4:5   Portrait/Instagram   1:1   Square
                        4:3   Classic print        5:4   Large format

  --gravity ANCHOR    Where to anchor the crop (default: bottom)
                        center
                        top | bottom | left | right
                        top-left | top-right | bottom-left | bottom-right

${CW}OUTPUT${CZ}
  --format FORMAT     Output format: jpg, png, webp, tiff
                      Default: preserve input format.
                      Note: only jpg->jpg is lossless (jpegtran). All other
                      format paths use ImageMagick and will re-encode.

  --suffix TEXT       Append TEXT before the file extension.
                      Example: --suffix _web  =>  photo_web.jpg

  --overwrite         Replace existing output files
  --skip              Skip silently if output file already exists
                      (--overwrite and --skip are mutually exclusive)

${CW}FILTERING${CZ}
  --recursive         Walk subdirectories. Output mirrors input structure.
  --pattern GLOB      Filter input filenames by glob. Wrap in quotes.
                      Example: --pattern "DSC_*"  or  --pattern "*-RAW*"
  --min-mp N          Skip images below N megapixels (decimal ok, e.g. 2.5)
  --max-mp N          Skip images above N megapixels

${CW}MODES${CZ}
  --dry-run           Show what would be done without writing any files.
                      Pairs well with --verbose and --log.

  --preview           For each file, save a preview JPEG showing the crop
                      rectangle drawn on a scaled-down copy of the image.
                      Previews are saved to OUTPUT_DIR/previews/.
                      Requires ImageMagick.

  --verbose           Print per-file processing detail.

  --config FILE       Load options from a config file. CLI flags always
                      take precedence over config file values.

${CW}LOGGING${CZ}
  --log FILE          Export a per-file results log.
                      Extension determines format: results.csv or results.json

${CW}OTHER${CZ}
  --version           Print version and exit
  --help              Show this help

${CW}CONFIG FILE FORMAT${CZ}
  Plain key=value, one per line. Keys match long option names without
  the leading dashes. Booleans use true/false. Lines starting with #
  are ignored.

  Example (my-shoot.conf):
    ratio=3:2
    gravity=bottom
    suffix=_crop
    format=jpg
    skip=true
    verbose=true

${CW}EXAMPLES${CZ}
  Basic crop with defaults (3:2, bottom anchor):
    $SCRIPT_NAME ./photos ./out

  Widescreen crop, centered:
    $SCRIPT_NAME ./photos ./out --ratio 16:9 --gravity center

  Convert to PNG, skip existing, with suffix:
    $SCRIPT_NAME ./photos ./out --format png --suffix _web --skip

  Dry run to preview all operations, export as JSON log:
    $SCRIPT_NAME ./photos ./out --dry-run --verbose --log results.json

  Use a config profile, override suffix on the CLI:
    $SCRIPT_NAME ./photos ./out --config shoot.conf --suffix _v2

  Recursive, only files starting with IMG_, at least 10MP:
    $SCRIPT_NAME ./photos ./out --recursive --pattern "IMG_*" --min-mp 10

  Generate crop-overlay previews before committing:
    $SCRIPT_NAME ./photos ./out --preview --dry-run

EOF
  exit 0
}

# =============================================================================
#  DEPENDENCY CHECK
# =============================================================================

check_deps() {
  local -a missing=()
  local needs_im=false

  # jpegtran: always required for JPEG lossless path
  if ! command -v jpegtran &>/dev/null; then
    missing+=("  jpegtran  ->  brew install jpeg (macOS)  |  apt install libjpeg-turbo-progs (Linux)")
  fi

  # ImageMagick: needed for non-JPG output, preview, or non-JPG input
  local fmt_lc
  fmt_lc=$(lc "$FORMAT")
  [[ -n "$FORMAT" && "$fmt_lc" != "jpg" ]] && needs_im=true
  $PREVIEW && needs_im=true

  if $needs_im && ! command -v convert &>/dev/null && ! command -v magick &>/dev/null; then
    missing+=("  ImageMagick  ->  brew install imagemagick  |  apt install imagemagick")
  fi

  # Dimension reading: sips (macOS built-in) or ImageMagick identify
  if ! command -v sips &>/dev/null && ! command -v identify &>/dev/null && ! command -v magick &>/dev/null; then
    missing+=("  sips (macOS built-in) OR ImageMagick identify (part of imagemagick)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies:"
    for dep in "${missing[@]}"; do
      echo -e "  ${CR}-${CZ} $dep"
    done
    exit 1
  fi
}

# =============================================================================
#  CONFIG FILE
# =============================================================================

load_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "Config file not found: $cfg"
  info "Loading config: $cfg"

  while IFS='=' read -r key val; do
    # Skip blank lines and comments
    [[ -z "${key// /}" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key//[[:space:]]/}"
    # Trim leading/trailing whitespace from value
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    case "$key" in
      ratio)              RATIO="$val" ;;
      gravity)            GRAVITY="$val" ;;
      format)             FORMAT="$val" ;;
      suffix)             SUFFIX="$val" ;;
      overwrite)          [[ "$val" == "true" ]] && OVERWRITE=true ;;
      skip)               [[ "$val" == "true" ]] && SKIP=true ;;
      dry-run|dryrun)     [[ "$val" == "true" ]] && DRY_RUN=true ;;
      verbose)            [[ "$val" == "true" ]] && VERBOSE=true ;;
      recursive)          [[ "$val" == "true" ]] && RECURSIVE=true ;;
      preview)            [[ "$val" == "true" ]] && PREVIEW=true ;;
      pattern)            PATTERN="$val" ;;
      min-mp|minmp)       MIN_MP="$val" ;;
      max-mp|maxmp)       MAX_MP="$val" ;;
      log)                LOG_FILE="$val" ;;
    esac
  done < "$cfg"
}

# Detect ImageMagick command name (v7=magick, v6=convert).
# macOS ships its own /usr/bin/convert that is NOT ImageMagick - check magick first.
if command -v magick &>/dev/null; then
  IM_CMD="magick"
elif command -v convert &>/dev/null && convert --version 2>&1 | grep -q "ImageMagick"; then
  IM_CMD="convert"
else
  IM_CMD="magick"  # will surface a clear error if neither exists
fi

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================

parse_args() {
  local -a pos=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)    usage ;;
      --version)    echo "crop-tool v$VERSION"; exit 0 ;;
      --ratio)      [[ -z "$2" ]] && die "--ratio requires a value"; RATIO="$2";   shift 2 ;;
      --gravity)    [[ -z "$2" ]] && die "--gravity requires a value"; GRAVITY="$2"; shift 2 ;;
      --format)     [[ -z "$2" ]] && die "--format requires a value"; FORMAT="$2";  shift 2 ;;
      --suffix)     [[ -n "$2" ]] && SUFFIX="$2"; shift 2 ;;
      --overwrite)  OVERWRITE=true; shift ;;
      --skip)       SKIP=true;      shift ;;
      --dry-run)    DRY_RUN=true;   shift ;;
      --verbose)    VERBOSE=true;   shift ;;
      --recursive)  RECURSIVE=true; shift ;;
      --preview)    PREVIEW=true;   shift ;;
      --pattern)    [[ -z "$2" ]] && die "--pattern requires a value"; PATTERN="$2"; shift 2 ;;
      --min-mp)     [[ -z "$2" ]] && die "--min-mp requires a value"; MIN_MP="$2"; shift 2 ;;
      --max-mp)     [[ -z "$2" ]] && die "--max-mp requires a value"; MAX_MP="$2"; shift 2 ;;
      --log)        [[ -z "$2" ]] && die "--log requires a value"; LOG_FILE="$2"; shift 2 ;;
      --config)     shift 2 ;; # already loaded before parse_args runs
      --*)          die "Unknown option: $1  (run with --help for usage)" ;;
      *)            pos+=("$1"); shift ;;
    esac
  done

  [[ ${#pos[@]} -ge 1 ]] && INPUT_DIR="${pos[0]}"
  [[ ${#pos[@]} -ge 2 ]] && OUTPUT_DIR="${pos[1]}"

  [[ -z "$INPUT_DIR"  ]] && INPUT_DIR="./input"
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./cropped"
}

# =============================================================================
#  VALIDATION
# =============================================================================

validate() {
  [[ -d "$INPUT_DIR" ]] || die "Input directory not found: $INPUT_DIR"

  [[ "$RATIO" =~ ^[0-9]+:[0-9]+$ ]] \
    || die "Invalid ratio '$RATIO' - use A:B integer format (e.g. 3:2, 16:9, 4:5)"

  local ra="${RATIO%:*}" rb="${RATIO#*:}"
  (( ra > 0 && rb > 0 )) \
    || die "Ratio values must be greater than zero"

  local ok_g="center top bottom left right top-left top-right bottom-left bottom-right"
  [[ " $ok_g " =~ " $GRAVITY " ]] \
    || die "Invalid gravity '$GRAVITY' - valid values: $ok_g"

  if [[ -n "$FORMAT" ]]; then
    local fmt_lc
    fmt_lc=$(lc "$FORMAT")
    local ok_f="jpg jpeg png webp tiff"
    [[ " $ok_f " =~ " $fmt_lc " ]] \
      || die "Invalid format '$FORMAT' - use one of: jpg, png, webp, tiff"
    FORMAT="$fmt_lc"
    [[ "$FORMAT" == "jpeg" ]] && FORMAT="jpg"
  fi

  if $OVERWRITE && $SKIP; then
    die "--overwrite and --skip are mutually exclusive"
  fi

  if [[ -n "$LOG_FILE" ]]; then
    local log_ext="${LOG_FILE##*.}"
    log_ext=$(lc "$log_ext")
    [[ "$log_ext" == "csv" || "$log_ext" == "json" ]] \
      || die "Log file must end in .csv or .json (got .$log_ext)"
  fi
}

# =============================================================================
#  IMAGE DIMENSIONS
# =============================================================================

# Sets IMG_WIDTH and IMG_HEIGHT globals for the given file path.
get_img_dims() {
  local file="$1"
  IMG_WIDTH=""
  IMG_HEIGHT=""

  if command -v sips &>/dev/null; then
    IMG_WIDTH=$(sips  -g pixelWidth  "$file" 2>/dev/null | awk '/pixelWidth/  {print $2}')
    IMG_HEIGHT=$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  else
    # ImageMagick identify - use [0] to handle multi-frame files (e.g. animated webp)
    IMG_WIDTH=$(identify  -format "%w" "${file}[0]" 2>/dev/null | head -1)
    IMG_HEIGHT=$(identify -format "%h" "${file}[0]" 2>/dev/null | head -1)
  fi
}

# =============================================================================
#  GRAVITY -> MCU-ALIGNED OFFSETS
# =============================================================================

# Sets OFFSET_X and OFFSET_Y globals.
# Pass snap_mcu=true as 5th arg to round down to 16px boundaries (JPG-to-JPG only).
compute_offsets() {
  local iw=$1 ih=$2 cw=$3 ch=$4 snap_mcu=${5:-false}

  local slack_x=$(( iw - cw ))
  local slack_y=$(( ih - ch ))
  local raw_x raw_y

  case "$GRAVITY" in
    top-left)     raw_x=0;                  raw_y=0 ;;
    top)          raw_x=$(( slack_x / 2 )); raw_y=0 ;;
    top-right)    raw_x=$slack_x;           raw_y=0 ;;
    left)         raw_x=0;                  raw_y=$(( slack_y / 2 )) ;;
    center)       raw_x=$(( slack_x / 2 )); raw_y=$(( slack_y / 2 )) ;;
    right)        raw_x=$slack_x;           raw_y=$(( slack_y / 2 )) ;;
    bottom-left)  raw_x=0;                  raw_y=$slack_y ;;
    bottom)       raw_x=$(( slack_x / 2 )); raw_y=$slack_y ;;
    bottom-right) raw_x=$slack_x;           raw_y=$slack_y ;;
  esac

  if $snap_mcu; then
    # Snap to 16px MCU boundary for jpegtran lossless crop
    OFFSET_X=$(( raw_x / 16 * 16 ))
    OFFSET_Y=$(( raw_y / 16 * 16 ))
  else
    # Exact pixel offset - PNG, WEBP, TIFF do not need block alignment
    OFFSET_X=$raw_x
    OFFSET_Y=$raw_y
  fi
}

# =============================================================================
#  LOG HELPERS
# =============================================================================

# Append a pipe-delimited log entry. 11 fields.
add_log() {
  local fn="$1" ow="$2" oh="$3" cw="$4" ch="$5"
  local ox="$6" oy="$7" rat="$8" grav="$9"
  local out="${10}" st="${11}"
  LOG_ENTRIES+=("${fn}|${ow}|${oh}|${cw}|${ch}|${ox}|${oy}|${rat}|${grav}|${out}|${st}")
}

write_log() {
  [[ -z "$LOG_FILE" ]] && return

  local ext
  ext=$(lc "${LOG_FILE##*.}")

  case "$ext" in

    csv)
      echo "filename,orig_width,orig_height,crop_width,crop_height,offset_x,offset_y,ratio,gravity,output_path,status" \
        > "$LOG_FILE"
      local e
      for e in "${LOG_ENTRIES[@]}"; do
        echo "${e//|/,}" >> "$LOG_FILE"
      done
      ;;

    json)
      local total=${#LOG_ENTRIES[@]}
      local i=0
      printf '[\n' > "$LOG_FILE"
      local e
      for e in "${LOG_ENTRIES[@]}"; do
        IFS='|' read -r fn ow oh cw ch ox oy rat grav out st <<< "$e"
        local comma=","
        (( i == total - 1 )) && comma="" || true
        cat >> "$LOG_FILE" <<JEOF
  {
    "filename":    "$fn",
    "orig_width":  "$ow",
    "orig_height": "$oh",
    "crop_width":  "$cw",
    "crop_height": "$ch",
    "offset_x":    "$ox",
    "offset_y":    "$oy",
    "ratio":       "$rat",
    "gravity":     "$grav",
    "output_path": "$out",
    "status":      "$st"
  }${comma}
JEOF
        (( i += 1 )) || true
      done
      printf ']\n' >> "$LOG_FILE"
      ;;

  esac

  ok "Log written  ->  $LOG_FILE"
}

# =============================================================================
#  PREVIEW GENERATION
# =============================================================================

# Draws the crop rectangle on a scaled-down copy of the image and saves it
# to OUTPUT_DIR/previews/. Requires ImageMagick.
generate_preview() {
  local file="$1" fn="$2" iw=$3 ih=$4 cw=$5 ch=$6 ox=$7 oy=$8

  local pdir="$OUTPUT_DIR/previews"
  mkdir -p "$pdir"
  local pout="$pdir/${fn%.*}_preview.jpg"
  local pmax=1000  # max preview width in px

  # Scale factor (clamp to 1.0 so we never upscale)
  local scale
  scale=$(awk "BEGIN { s=$pmax/$iw; if (s>1) s=1; printf \"%.6f\", s }")

  # Scale the crop rectangle coordinates to match the preview dimensions
  local rx1 ry1 rx2 ry2
  rx1=$(awk "BEGIN { printf \"%d\", $ox * $scale }")
  ry1=$(awk "BEGIN { printf \"%d\", $oy * $scale }")
  rx2=$(awk "BEGIN { printf \"%d\", ($ox + $cw - 1) * $scale }")
  ry2=$(awk "BEGIN { printf \"%d\", ($oy + $ch - 1) * $scale }")

  local label="${cw}x${ch}  |  ${RATIO}  |  ${GRAVITY}"
  local lx=$(( rx1 + 6 ))
  local ly=$(( ry1 + 18 ))

  # Build the preview: resize, draw rectangle, annotate
  if $IM_CMD "$file" \
    -resize "${pmax}x>" \
    -fill none \
    -stroke "#00e676" \
    -strokewidth 2 \
    -draw "rectangle ${rx1},${ry1} ${rx2},${ry2}" \
    -fill "#00e676" \
    -pointsize 14 \
    -draw "text ${lx},${ly} '${label}'" \
    "$pout" 2>/dev/null; then
    verbose "Preview saved  ->  $pout"
  else
    warn "Preview generation failed for $fn"
  fi
}

# =============================================================================
#  PROCESS ONE FILE
# =============================================================================

process_file() {
  local file="$1"
  (( COUNT_FOUND += 1 )) || true

  local fn
  fn="$(basename "$file")"
  local name="${fn%.*}"
  local in_ext="${fn##*.}"
  local in_ext_lc
  in_ext_lc=$(lc "$in_ext")

  # Determine output extension
  local out_ext="$in_ext_lc"
  [[ "$out_ext" == "jpeg" ]] && out_ext="jpg"
  [[ -n "$FORMAT" ]] && out_ext="$FORMAT"

  # Build output path, preserving subdirectory structure in recursive mode
  local rel="${file#"$INPUT_DIR"/}"
  local rel_dir
  rel_dir="$(dirname "$rel")"
  local out_dir="$OUTPUT_DIR"
  if $RECURSIVE && [[ "$rel_dir" != "." ]]; then
    out_dir="$OUTPUT_DIR/$rel_dir"
  fi
  local output="$out_dir/${name}${SUFFIX}.${out_ext}"

  # ── Readability check ──────────────────────────────────────────────────────
  if [[ ! -r "$file" ]]; then
    err "$fn: cannot read file - skipping"
    (( COUNT_FAILED += 1 )) || true
    add_log "$fn" "?" "?" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "failed:unreadable"
    return
  fi

  # ── Get image dimensions ───────────────────────────────────────────────────
  local IMG_WIDTH IMG_HEIGHT
  get_img_dims "$file"

  if [[ -z "$IMG_WIDTH" || -z "$IMG_HEIGHT" ]] || \
     ! [[ "$IMG_WIDTH" =~ ^[0-9]+$ && "$IMG_HEIGHT" =~ ^[0-9]+$ ]] || \
     (( IMG_WIDTH == 0 || IMG_HEIGHT == 0 )); then
    err "$fn: could not read image dimensions - skipping"
    (( COUNT_FAILED += 1 )) || true
    add_log "$fn" "?" "?" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "failed:no-dimensions"
    return
  fi

  verbose "$fn  ${IMG_WIDTH}x${IMG_HEIGHT}"

  # ── Megapixel filter ───────────────────────────────────────────────────────
  local mp
  mp=$(awk "BEGIN { printf \"%.2f\", $IMG_WIDTH * $IMG_HEIGHT / 1000000 }")

  if [[ "$MIN_MP" != "0" ]]; then
    local below
    below=$(awk "BEGIN { print ($mp < $MIN_MP) ? 1 : 0 }")
    if [[ "$below" -eq 1 ]]; then
      verbose "Skipping: ${mp}MP is below --min-mp ${MIN_MP}"
      (( COUNT_SKIPPED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "skipped:below-min-mp"
      return
    fi
  fi

  if [[ "$MAX_MP" != "0" ]]; then
    local above
    above=$(awk "BEGIN { print ($mp > $MAX_MP) ? 1 : 0 }")
    if [[ "$above" -eq 1 ]]; then
      verbose "Skipping: ${mp}MP is above --max-mp ${MAX_MP}"
      (( COUNT_SKIPPED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "skipped:above-max-mp"
      return
    fi
  fi

  # ── Output conflict handling ───────────────────────────────────────────────
  if [[ -f "$output" ]]; then
    if $SKIP; then
      verbose "Skipping: output file already exists"
      (( COUNT_SKIPPED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "skipped:exists"
      return
    elif ! $OVERWRITE && ! $DRY_RUN; then
      err "$fn: output already exists at '$output'"
      err "     Use --overwrite to replace it, or --skip to skip it."
      (( COUNT_FAILED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "-" "-" "-" "-" "$RATIO" "$GRAVITY" "$output" "failed:conflict"
      return
    fi
  fi

  # ── Compute crop dimensions ───────────────────────────────────────────────
  local ra="${RATIO%:*}" rb="${RATIO#*:}"
  local IS_LOSSLESS_JPEG=false
  local CROP_W CROP_H

  if [[ "$in_ext_lc" =~ ^(jpg|jpeg)$ && "$out_ext" == "jpg" ]]; then
    IS_LOSSLESS_JPEG=true
    # MCU-aligned path: dimensions must be multiples of A*16 and B*16
    local W_BLOCK=$(( ra * 16 ))
    local H_BLOCK=$(( rb * 16 ))
    local units_w=$(( IMG_WIDTH  / W_BLOCK ))
    local units_h=$(( IMG_HEIGHT / H_BLOCK ))
    local N=$(( units_w <= units_h ? units_w : units_h ))
    if (( N == 0 )); then
      warn "$fn: too small for ratio ${RATIO} at MCU alignment"
      warn "     Image is ${IMG_WIDTH}x${IMG_HEIGHT}, minimum needed: ${W_BLOCK}x${H_BLOCK}"
      (( COUNT_SKIPPED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "0" "0" "0" "0" "$RATIO" "$GRAVITY" "$output" "skipped:too-small"
      return
    fi
    CROP_W=$(( N * W_BLOCK ))
    CROP_H=$(( N * H_BLOCK ))
  else
    # Exact pixel path: largest crop at ratio A:B that fits the image
    if (( IMG_WIDTH * rb >= IMG_HEIGHT * ra )); then
      CROP_H=$IMG_HEIGHT
      CROP_W=$(( IMG_HEIGHT * ra / rb ))
    else
      CROP_W=$IMG_WIDTH
      CROP_H=$(( IMG_WIDTH * rb / ra ))
    fi
    if (( CROP_W == 0 || CROP_H == 0 )); then
      warn "$fn: too small for ratio ${RATIO} (${IMG_WIDTH}x${IMG_HEIGHT})"
      (( COUNT_SKIPPED += 1 )) || true
      add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "0" "0" "0" "0" "$RATIO" "$GRAVITY" "$output" "skipped:too-small"
      return
    fi
  fi

  # ── Compute gravity-based offsets ──────────────────────────────────────────
  local OFFSET_X OFFSET_Y
  compute_offsets "$IMG_WIDTH" "$IMG_HEIGHT" "$CROP_W" "$CROP_H" $IS_LOSSLESS_JPEG

  verbose "Crop: ${CROP_W}x${CROP_H} at +${OFFSET_X}+${OFFSET_Y}  (gravity: $GRAVITY)"

  # ── Dry run path ───────────────────────────────────────────────────────────
  if $DRY_RUN; then
    printf "  ${CD}%-38s${CZ}  %s -> %s  ${CD}@ +%d+%d  (%s)${CZ}\n" \
      "$fn" "${IMG_WIDTH}x${IMG_HEIGHT}" "${CROP_W}x${CROP_H}" \
      "$OFFSET_X" "$OFFSET_Y" "$GRAVITY"
    (( COUNT_PROCESSED += 1 )) || true
    add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "$CROP_W" "$CROP_H" \
      "$OFFSET_X" "$OFFSET_Y" "$RATIO" "$GRAVITY" "$output" "dry-run"
    return
  fi

  # ── Create output directory ────────────────────────────────────────────────
  mkdir -p "$out_dir"

  # ── Perform crop ──────────────────────────────────────────────────────────
  local crop_ok=false

  if $IS_LOSSLESS_JPEG; then
    # Lossless path: jpegtran with MCU-aligned offsets
    if jpegtran \
        -crop "${CROP_W}x${CROP_H}+${OFFSET_X}+${OFFSET_Y}" \
        -copy all \
        -optimize \
        "$file" > "$output" 2>/dev/null; then
      crop_ok=true
    fi
  else
    # Native lossless path: ImageMagick with exact pixel offsets
    # PNG, WEBP, TIFF are cropped directly - no roundtrip through JPEG
    if [[ "$in_ext_lc" =~ ^(jpg|jpeg)$ ]]; then
      verbose "Note: jpg -> $out_ext will re-encode (not lossless)"
    fi
    if $IM_CMD "$file" \
        -crop "${CROP_W}x${CROP_H}+${OFFSET_X}+${OFFSET_Y}" \
        +repage \
        "$output" 2>/dev/null; then
      crop_ok=true
    fi
  fi

  # ── Handle result ──────────────────────────────────────────────────────────
  if $crop_ok; then
    local orig_size new_size delta=0
    orig_size=$(wc -c < "$file"   2>/dev/null || echo 0)
    new_size=$(wc -c  < "$output" 2>/dev/null || echo 0)
    delta=$(( orig_size - new_size ))
    (( BYTES_SAVED += delta )) || true

    ok "$fn  ${CD}${IMG_WIDTH}x${IMG_HEIGHT} -> ${CROP_W}x${CROP_H}${CZ}"
    (( COUNT_PROCESSED += 1 )) || true
    add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "$CROP_W" "$CROP_H" \
      "$OFFSET_X" "$OFFSET_Y" "$RATIO" "$GRAVITY" "$output" "ok"

    # Generate preview if requested
    if $PREVIEW; then
      generate_preview "$file" "$fn" \
        "$IMG_WIDTH" "$IMG_HEIGHT" "$CROP_W" "$CROP_H" "$OFFSET_X" "$OFFSET_Y"
    fi

  else
    err "$fn: crop command failed"
    (( COUNT_FAILED += 1 )) || true
    # Clean up any partial output
    [[ -f "$output" ]] && rm -f "$output"
    add_log "$fn" "$IMG_WIDTH" "$IMG_HEIGHT" "$CROP_W" "$CROP_H" \
      "$OFFSET_X" "$OFFSET_Y" "$RATIO" "$GRAVITY" "$output" "failed:crop-error"
  fi
}

# =============================================================================
#  SUMMARY
# =============================================================================

print_summary() {
  echo ""
  hr
  echo -e "${CW}  Summary${CZ}"
  hr
  printf "  %-14s %s\n"  "Found"       "$COUNT_FOUND"
  printf "  %-14s ${CG}%s${CZ}\n" "Processed"   "$COUNT_PROCESSED"
  printf "  %-14s ${CY}%s${CZ}\n" "Skipped"     "$COUNT_SKIPPED"
  printf "  %-14s ${CR}%s${CZ}\n" "Failed"       "$COUNT_FAILED"

  if ! $DRY_RUN && (( BYTES_SAVED != 0 )); then
    local bh
    bh=$(human_bytes "${BYTES_SAVED#-}")  # strip any negative sign for display
    if (( BYTES_SAVED >= 0 )); then
      printf "  %-14s ${CD}-%s saved${CZ}\n" "Size diff" "$bh"
    else
      printf "  %-14s ${CD}+%s larger${CZ}\n" "Size diff" "$bh"
    fi
  fi

  if $DRY_RUN; then
    echo ""
    echo -e "  ${CD}Dry run - nothing was written.${CZ}"
  fi

  hr
  echo ""
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
  # Pre-scan for --config so it's loaded before the main parse
  # (config sets the baseline; CLI flags override it)
  local _p=""
  for _a in "$@"; do
    if [[ "$_p" == "--config" ]]; then
      CONFIG_FILE="$_a"
      break
    fi
    _p="$_a"
  done
  [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"

  parse_args "$@"
  validate
  check_deps

  # ── Print run header ───────────────────────────────────────────────────────
  echo ""
  hr
  echo -e "${CW}  crop-tool${CZ} v${VERSION}"
  hr
  echo -e "  Input      $INPUT_DIR"
  echo -e "  Output     $OUTPUT_DIR"
  echo -e "  Ratio      $RATIO    Gravity: $GRAVITY"
  [[ -n "$FORMAT" ]]  && echo -e "  Format     $FORMAT"
  [[ -n "$SUFFIX" ]]  && echo -e "  Suffix     $SUFFIX"
  [[ -n "$PATTERN" ]] && echo -e "  Pattern    $PATTERN"
  (( MIN_MP != 0 ))   && echo -e "  Min MP     ${MIN_MP}MP"
  (( MAX_MP != 0 ))   && echo -e "  Max MP     ${MAX_MP}MP"
  $RECURSIVE          && echo -e "  Recursive  yes"
  $OVERWRITE          && echo -e "  ${CY}Overwrite  enabled${CZ}"
  $SKIP               && echo -e "  ${CY}Skip       existing outputs will be skipped${CZ}"
  $PREVIEW            && echo -e "  Preview    $OUTPUT_DIR/previews/"
  [[ -n "$LOG_FILE" ]] && echo -e "  Log        $LOG_FILE"
  $DRY_RUN            && echo -e "\n  ${CY}DRY RUN - no files will be written${CZ}"
  hr
  echo ""

  # ── Collect input files ────────────────────────────────────────────────────
  local -a depth_flag=()
  $RECURSIVE || depth_flag=( -maxdepth 1 )

  local -a files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$INPUT_DIR" "${depth_flag[@]}" -type f \( \
      -iname "*.jpg"  -o -iname "*.jpeg" -o \
      -iname "*.png"  -o -iname "*.webp" -o \
      -iname "*.tiff" -o -iname "*.tif" \
    \) -print0 | sort -z)

  # Apply filename pattern filter if set
  if [[ -n "$PATTERN" ]]; then
    local -a filtered=()
    local f
    for f in "${files[@]}"; do
      local bn
      bn="$(basename "$f")"
      case "$bn" in
        $PATTERN) filtered+=("$f") ;;
      esac
    done
    files=("${filtered[@]}")
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No matching images found in $INPUT_DIR"
    [[ -n "$PATTERN" ]] && warn "  (pattern filter active: '$PATTERN')"
    exit 0
  fi

  info "Found ${#files[@]} file(s) to process"
  echo ""

  # ── Process each file ──────────────────────────────────────────────────────
  local f
  for f in "${files[@]}"; do
    process_file "$f"
  done

  print_summary
  write_log
}

main "$@"
