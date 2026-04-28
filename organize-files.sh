#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CATEGORY_DEFINITIONS_FILE="$SCRIPT_DIR/category-definitions.tsv"

OS_NAME="$(uname -s)"
EXIFTOOL_AVAILABLE=0

if command -v exiftool >/dev/null 2>&1; then
  EXIFTOOL_AVAILABLE=1
fi

declare -a SOURCE_DIRS=()
declare -a TARGET_DIRS=()
declare -a IGNORE_EXTENSION_VALUES=()
declare -a FILES=()
declare -a CATEGORY_ORDER=()

declare -A CATEGORY_FOLDERS=()
declare -A CATEGORY_EXTENSIONS=()
declare -A EXT_TO_CATEGORY=()
declare -A SELECTED_CATEGORIES=()
declare -A INCLUDED_EXTENSIONS=()
declare -A IGNORED_EXTENSIONS=()
declare -A TARGET_PATH_BY_KEY=()
declare -A TARGET_SIZE_BY_KEY=()

OUTPUT=""
DRY_RUN=0
LOG_FILE=""
USE_NAME=0
USE_DATE=0
USE_SIZE=0
IGNORE_DUPLICATE_SUFFIX=0
ORGANIZE_BY_DATE=0
SEPARATE_BY_TYPE=0
MAX_FILES=0
USE_FILENAME_DATE=0
MOVE_FILES=0
HAS_CATEGORY_FILTERS=0
TRANSFER_VERB="COPY"
REPLACE_VERB="REPLACE"
TRANSFER_SUMMARY_LABEL="Copied"

die() {
  echo "$*" >&2
  exit 1
}

print_usage() {
  cat <<'EOF'
Usage: ./organize-files.sh -Source <dir...> -Targets <dir...> -Output <dir> [options]

Core options:
  -Source <dir...>
  -Targets <dir...>
  -Output <dir>
  -DryRun
  -LogFile <path>
  -UseName
  -UseDate
  -UseSize
  -IgnoreDuplicateSuffix
  -IgnoreExtensions <ext...>
  -OrganizeByDate
  -SeparateByType
  -SeparateMedia
  -MaxFiles <count>
  -UseFileNameDate
  -MoveFiles

Category flags:
  -Images  -Videos  -Audio  -Documents  -Archives  -Code  -Fonts
  -Ebooks  -Subtitles  -Data  -DiskImages  -Executables
  -DesignFiles  -Models3D
EOF
}

append_log_line() {
  local line="$1"

  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p -- "$(dirname -- "$LOG_FILE")"
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

normalize_extension() {
  local extension="${1:-}"

  extension="${extension#"${extension%%[![:space:]]*}"}"
  extension="${extension%"${extension##*[![:space:]]}"}"
  extension="${extension,,}"

  if [[ -z "$extension" ]]; then
    printf ''
    return
  fi

  if [[ "$extension" != .* ]]; then
    extension=".$extension"
  fi

  printf '%s' "$extension"
}

get_file_extension() {
  local base_name
  base_name="$(basename -- "$1")"

  if [[ "$base_name" != *.* ]]; then
    printf ''
    return
  fi

  normalize_extension "${base_name##*.}"
}

register_category() {
  local key="$1"
  local folder="$2"
  shift 2

  CATEGORY_ORDER+=("$key")
  CATEGORY_FOLDERS["$key"]="$folder"
  CATEGORY_EXTENSIONS["$key"]="$*"

  local extension normalized_extension
  for extension in "$@"; do
    normalized_extension="$(normalize_extension "$extension")"
    if [[ -z "$normalized_extension" ]]; then
      continue
    fi

    if [[ -z "${EXT_TO_CATEGORY[$normalized_extension]+x}" ]]; then
      EXT_TO_CATEGORY["$normalized_extension"]="$key"
    fi
  done
}

load_category_definitions() {
  local definitions_file="$1"
  local key folder extension_blob
  local -a extensions=()

  [[ -f "$definitions_file" ]] || die "Category definitions file not found: $definitions_file"

  while IFS=$'\t' read -r key folder extension_blob || [[ -n "$key$folder$extension_blob" ]]; do
    if [[ -z "$key" || "$key" == \#* ]]; then
      continue
    fi

    read -r -a extensions <<< "$extension_blob"
    if (( ${#extensions[@]} == 0 )); then
      die "Invalid category definition line for category: $key"
    fi

    register_category "$key" "$folder" "${extensions[@]}"
  done < "$definitions_file"
}

select_category() {
  SELECTED_CATEGORIES["$1"]=1
}

build_extension_filters() {
  local extension normalized_extension category_name

  if (( ${#SELECTED_CATEGORIES[@]} > 0 )); then
    HAS_CATEGORY_FILTERS=1
    for category_name in "${CATEGORY_ORDER[@]}"; do
      if [[ -z "${SELECTED_CATEGORIES[$category_name]+x}" ]]; then
        continue
      fi

      for extension in ${CATEGORY_EXTENSIONS[$category_name]}; do
        normalized_extension="$(normalize_extension "$extension")"
        if [[ -n "$normalized_extension" ]]; then
          INCLUDED_EXTENSIONS["$normalized_extension"]=1
        fi
      done
    done
  fi

  for extension in "${IGNORE_EXTENSION_VALUES[@]}"; do
    normalized_extension="$(normalize_extension "$extension")"
    if [[ -n "$normalized_extension" ]]; then
      IGNORED_EXTENSIONS["$normalized_extension"]=1
    fi
  done
}

join_selected_categories() {
  local result=""
  local separator=""
  local category_name

  for category_name in "${CATEGORY_ORDER[@]}"; do
    if [[ -n "${SELECTED_CATEGORIES[$category_name]+x}" ]]; then
      result+="${separator}${category_name}"
      separator=", "
    fi
  done

  printf '%s' "$result"
}

stat_size() {
  if [[ "$OS_NAME" == "Darwin" ]]; then
    stat -f '%z' "$1"
  else
    stat -c '%s' -- "$1"
  fi
}

get_mtime_epoch() {
  if [[ "$OS_NAME" == "Darwin" ]]; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' -- "$1"
  fi
}

get_creation_epoch() {
  if [[ "$OS_NAME" == "Darwin" ]]; then
    stat -f '%B' "$1"
  else
    stat -c '%W' -- "$1"
  fi
}

format_epoch() {
  local epoch="$1"
  local format_string="$2"

  if [[ "$OS_NAME" == "Darwin" ]]; then
    date -u -r "$epoch" "+$format_string"
  else
    date -u -d "@$epoch" "+$format_string"
  fi
}

format_optional_epoch() {
  local epoch="$1"

  if [[ -z "$epoch" ]] || (( epoch <= 0 )); then
    printf 'N/A'
    return
  fi

  format_epoch "$epoch" '%Y-%m-%d %H:%M:%S'
}

date_components_to_epoch() {
  local year="$1"
  local month="$2"
  local day="$3"

  if [[ "$OS_NAME" == "Darwin" ]]; then
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$year-$month-$day 00:00:00" '+%s' 2>/dev/null
  else
    date -u -d "$year-$month-$day 00:00:00" '+%s' 2>/dev/null
  fi
}

get_date_from_filename_epoch() {
  local name="$1"
  local year=""
  local month=""
  local day=""

  if [[ "$name" =~ (20[0-9]{2})([0-1][0-9])([0-3][0-9]) ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  elif [[ "$name" =~ (20[0-9]{2})-([0-1][0-9])-([0-3][0-9]) ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  elif [[ "$name" =~ (20[0-9]{2})_([0-1][0-9])_([0-3][0-9]) ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  date_components_to_epoch "$year" "$month" "$day"
}

get_metadata_date_epoch() {
  local file_path="$1"
  local value

  if (( ! EXIFTOOL_AVAILABLE )); then
    return 1
  fi

  value="$(exiftool -s3 -d '%s' -DateTimeOriginal -CreateDate -MediaCreateDate -- "$file_path" 2>/dev/null | head -n 1 || true)"

  if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
    printf '%s' "$value"
    return 0
  fi

  return 1
}

should_skip_file() {
  local file_path="$1"
  local base_name extension

  base_name="$(basename -- "$file_path")"
  extension="$(get_file_extension "$file_path")"

  if [[ -n "$extension" && -n "${IGNORED_EXTENSIONS[$extension]+x}" ]]; then
    return 0
  fi

  if (( IGNORE_DUPLICATE_SUFFIX )) && [[ "$base_name" =~ \([0-9]+\)\.[^.]+$ ]]; then
    return 0
  fi

  return 1
}

should_include_file() {
  local file_path="$1"
  local extension

  if should_skip_file "$file_path"; then
    return 1
  fi

  if (( ! HAS_CATEGORY_FILTERS )); then
    return 0
  fi

  extension="$(get_file_extension "$file_path")"
  [[ -n "$extension" && -n "${INCLUDED_EXTENSIONS[$extension]+x}" ]]
}

get_category_name_for_file() {
  local extension
  extension="$(get_file_extension "$1")"

  if [[ -n "$extension" && -n "${EXT_TO_CATEGORY[$extension]+x}" ]]; then
    printf '%s' "${EXT_TO_CATEGORY[$extension]}"
    return 0
  fi

  return 1
}

get_file_key() {
  local file_path="$1"
  local parts=()

  if (( USE_NAME )); then
    parts+=("$(basename -- "$file_path" | tr '[:upper:]' '[:lower:]')")
  fi

  if (( USE_DATE )); then
    parts+=("$(get_mtime_epoch "$file_path")")
  fi

  local joined=""
  local separator=""
  local part

  for part in "${parts[@]}"; do
    joined+="${separator}${part}"
    separator='|'
  done

  printf '%s' "$joined"
}

copy_file() {
  if [[ "$OS_NAME" == "Darwin" ]]; then
    cp -f "$1" "$2"
  else
    cp -f -- "$1" "$2"
  fi
}

move_file() {
  if [[ "$OS_NAME" == "Darwin" ]]; then
    mv -f "$1" "$2"
  else
    mv -f -- "$1" "$2"
  fi
}

invoke_transfer() {
  local source_path="$1"
  local destination_path="$2"

  if (( MOVE_FILES )); then
    move_file "$source_path" "$destination_path"
  else
    copy_file "$source_path" "$destination_path"
  fi
}

get_best_date_epoch() {
  local file_path="$1"
  local category_name metadata_epoch filename_epoch creation_epoch

  category_name="$(get_category_name_for_file "$file_path" || true)"

  if [[ "$category_name" == "Images" || "$category_name" == "Videos" ]]; then
    if metadata_epoch="$(get_metadata_date_epoch "$file_path")"; then
      printf '%s' "$metadata_epoch"
      return 0
    fi
  fi

  if (( USE_FILENAME_DATE )); then
    if filename_epoch="$(get_date_from_filename_epoch "$(basename -- "$file_path")")"; then
      printf '%s' "$filename_epoch"
      return 0
    fi
  fi

  creation_epoch="$(get_creation_epoch "$file_path")"
  if [[ -n "$creation_epoch" ]] && (( creation_epoch > 0 )); then
    printf '%s' "$creation_epoch"
    return 0
  fi

  get_mtime_epoch "$file_path"
}

collect_files_from_directory() {
  local directory_path="$1"
  local file_path

  while IFS= read -r -d '' file_path; do
    if should_include_file "$file_path"; then
      FILES+=("$file_path")
      if (( MAX_FILES > 0 && ${#FILES[@]} >= MAX_FILES )); then
        return 0
      fi
    fi
  done < <(find "$directory_path" -type f -print0)
}

parse_multi_value_option() {
  local -n target_ref=$1
  shift

  if (( $# == 0 )) || [[ "$1" == -* ]]; then
    die "Expected at least one value for the previous option."
  fi

  while (( $# > 0 )) && [[ "$1" != -* ]]; do
    target_ref+=("$1")
    shift
  done

  PARSE_REMAINING_COUNT=$#
}

require_directory() {
  local directory_path="$1"
  local label="$2"

  if [[ ! -d "$directory_path" ]]; then
    die "$label directory not found: $directory_path"
  fi
}

load_category_definitions "$CATEGORY_DEFINITIONS_FILE"

while (( $# > 0 )); do
  case "$1" in
    -Source)
      shift
      parse_multi_value_option SOURCE_DIRS "$@"
      shift $(( $# - PARSE_REMAINING_COUNT ))
      ;;
    -Targets)
      shift
      parse_multi_value_option TARGET_DIRS "$@"
      shift $(( $# - PARSE_REMAINING_COUNT ))
      ;;
    -IgnoreExtensions)
      shift
      parse_multi_value_option IGNORE_EXTENSION_VALUES "$@"
      shift $(( $# - PARSE_REMAINING_COUNT ))
      ;;
    -Output)
      shift
      (( $# > 0 )) || die "Missing value for -Output"
      OUTPUT="$1"
      shift
      ;;
    -LogFile)
      shift
      (( $# > 0 )) || die "Missing value for -LogFile"
      LOG_FILE="$1"
      shift
      ;;
    -MaxFiles)
      shift
      (( $# > 0 )) || die "Missing value for -MaxFiles"
      MAX_FILES="$1"
      shift
      ;;
    -DryRun)
      DRY_RUN=1
      shift
      ;;
    -UseName)
      USE_NAME=1
      shift
      ;;
    -UseDate)
      USE_DATE=1
      shift
      ;;
    -UseSize)
      USE_SIZE=1
      shift
      ;;
    -IgnoreDuplicateSuffix)
      IGNORE_DUPLICATE_SUFFIX=1
      shift
      ;;
    -OrganizeByDate)
      ORGANIZE_BY_DATE=1
      shift
      ;;
    -SeparateByType|-SeparateMedia)
      SEPARATE_BY_TYPE=1
      shift
      ;;
    -UseFileNameDate)
      USE_FILENAME_DATE=1
      shift
      ;;
    -MoveFiles)
      MOVE_FILES=1
      shift
      ;;
    -Images|-Image)
      select_category "Images"
      shift
      ;;
    -Videos|-Video)
      select_category "Videos"
      shift
      ;;
    -Audio)
      select_category "Audio"
      shift
      ;;
    -Documents|-Document)
      select_category "Documents"
      shift
      ;;
    -Archives|-Archive)
      select_category "Archives"
      shift
      ;;
    -Code)
      select_category "Code"
      shift
      ;;
    -Fonts|-Font)
      select_category "Fonts"
      shift
      ;;
    -Ebooks|-Ebook)
      select_category "Ebooks"
      shift
      ;;
    -Subtitles|-Subtitle)
      select_category "Subtitles"
      shift
      ;;
    -Data)
      select_category "Data"
      shift
      ;;
    -DiskImages|-DiskImage)
      select_category "DiskImages"
      shift
      ;;
    -Executables|-Executable)
      select_category "Executables"
      shift
      ;;
    -DesignFiles|-Design)
      select_category "DesignFiles"
      shift
      ;;
    -Models3D|-Model3D)
      select_category "Models3D"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if (( ${#SOURCE_DIRS[@]} == 0 )); then
  die "-Source requires at least one directory"
fi

if (( ${#TARGET_DIRS[@]} == 0 )); then
  die "-Targets requires at least one directory"
fi

if [[ -z "$OUTPUT" ]]; then
  die "-Output is required"
fi

if ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]]; then
  die "-MaxFiles must be a non-negative integer"
fi

if (( ! USE_NAME && ! USE_DATE && ! USE_SIZE )); then
  echo "Defaulting to: Name + Date"
  USE_NAME=1
  USE_DATE=1
fi

if (( MOVE_FILES )); then
  TRANSFER_VERB="MOVE"
  REPLACE_VERB="MOVE-REPLACE"
  TRANSFER_SUMMARY_LABEL="Moved"
fi

for source_dir in "${SOURCE_DIRS[@]}"; do
  require_directory "$source_dir" "Source"
done

for target_dir in "${TARGET_DIRS[@]}"; do
  require_directory "$target_dir" "Target"
done

build_extension_filters

echo "Indexing targets..."

for target_dir in "${TARGET_DIRS[@]}"; do
  while IFS= read -r -d '' file_path; do
    if ! should_include_file "$file_path"; then
      continue
    fi

    key="$(get_file_key "$file_path")"
    TARGET_PATH_BY_KEY["$key"]="$file_path"
    TARGET_SIZE_BY_KEY["$key"]="$(stat_size "$file_path")"
  done < <(find "$target_dir" -type f -print0)
done

if (( HAS_CATEGORY_FILTERS )); then
  echo "Scanning selected categories: $(join_selected_categories)"
else
  echo "Scanning all files..."
fi

for source_dir in "${SOURCE_DIRS[@]}"; do
  collect_files_from_directory "$source_dir"
  if (( MAX_FILES > 0 && ${#FILES[@]} >= MAX_FILES )); then
    break
  fi
done

total=${#FILES[@]}
current=0
transferred=0
replaced=0
skipped=0

for file_path in "${FILES[@]}"; do
  current=$((current + 1))

  if (( total > 0 )); then
    printf '\rSyncing files: %d / %d' "$current" "$total" >&2
  fi

  key="$(get_file_key "$file_path")"
  best_date_epoch="$(get_best_date_epoch "$file_path")"
  best_date_display="$(format_optional_epoch "$best_date_epoch")"
  created_display="$(format_optional_epoch "$(get_creation_epoch "$file_path")")"
  modified_display="$(format_optional_epoch "$(get_mtime_epoch "$file_path")")"

  date_log="DATE: $(basename -- "$file_path") | Selected=$best_date_display | Created=$created_display | Modified=$modified_display"
  echo "$date_log"
  append_log_line "$date_log"

  dest_root="$OUTPUT"
  category_name="$(get_category_name_for_file "$file_path" || true)"

  if (( SEPARATE_BY_TYPE )); then
    if [[ -n "$category_name" ]]; then
      dest_root="$dest_root/${CATEGORY_FOLDERS[$category_name]}"
    else
      dest_root="$dest_root/Other"
    fi
  fi

  if (( ORGANIZE_BY_DATE )); then
    year="$(format_epoch "$best_date_epoch" '%Y')"
    month="$(format_epoch "$best_date_epoch" '%m')"
    dest_root="$dest_root/$year/$month"
  fi

  destination_path="$dest_root/$(basename -- "$file_path")"

  if [[ -n "${TARGET_PATH_BY_KEY[$key]+x}" ]]; then
    target_size="${TARGET_SIZE_BY_KEY[$key]}"
    source_size="$(stat_size "$file_path")"

    if (( USE_SIZE && USE_NAME )); then
      if (( source_size <= target_size )); then
        skipped=$((skipped + 1))
        continue
      fi
    else
      skipped=$((skipped + 1))
      continue
    fi

    log_line="${REPLACE_VERB}: $file_path -> $destination_path"

    if (( DRY_RUN )); then
      echo "[SIMULATION] $log_line"
    else
      mkdir -p -- "$dest_root"
      invoke_transfer "$file_path" "$destination_path"
      echo "$log_line"
      replaced=$((replaced + 1))
    fi
  else
    log_line="${TRANSFER_VERB}: $file_path -> $destination_path"

    if (( DRY_RUN )); then
      echo "[SIMULATION] $log_line"
    else
      mkdir -p -- "$dest_root"
      invoke_transfer "$file_path" "$destination_path"
      echo "$log_line"
      transferred=$((transferred + 1))
    fi
  fi

  append_log_line "$log_line"
done

if (( total > 0 )); then
  printf '\n' >&2
fi

echo
echo "========== SUMMARY =========="
echo "Total scanned : $total"
printf '%-13s: %s\n' "$TRANSFER_SUMMARY_LABEL" "$transferred"
echo "Replaced      : $replaced"
echo "Skipped       : $skipped"
echo "============================="