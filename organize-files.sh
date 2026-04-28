#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CATEGORY_DEFINITIONS_FILE="$SCRIPT_DIR/category-definitions.tsv"
FILENAME_DATE_FORMATS_FILE="$SCRIPT_DIR/filename-date-formats.txt"

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
declare -a FILENAME_DATE_FORMATS=()
declare -a TEMP_FILES=()

declare -A CATEGORY_FOLDERS=()
declare -A CATEGORY_EXTENSIONS=()
declare -A EXT_TO_CATEGORY=()
declare -A SELECTED_CATEGORIES=()
declare -A INCLUDED_EXTENSIONS=()
declare -A IGNORED_EXTENSIONS=()
declare -A PLANNED_DESTINATIONS=()
declare -A TARGET_PATH_BY_KEY=()
declare -A TARGET_SIZE_BY_KEY=()

OUTPUT=""
DRY_RUN=0
LOG_FILE=""
THREADS=1
USE_NAME=0
USE_DATE=0
USE_SIZE=0
IGNORE_DUPLICATE_SUFFIX=0
ORGANIZE_BY_DATE=0
SEPARATE_BY_TYPE=0
MAX_FILES=0
USE_FILENAME_DATE=0
USE_METADATA_DATE=0
USE_SUPPLEMENTAL_METADATA=0
MOVE_FILES=0
HAS_CATEGORY_FILTERS=0
TRANSFER_VERB="COPY"
REPLACE_VERB="REPLACE"
TRANSFER_SUMMARY_LABEL="Copied"

die() {
  echo "$*" >&2
  exit 1
}

cleanup_temp_files() {
  local temp_file

  for temp_file in "${TEMP_FILES[@]}"; do
    if [[ -n "$temp_file" && -e "$temp_file" ]]; then
      rm -f -- "$temp_file"
    fi
  done
}

trap cleanup_temp_files EXIT

print_usage() {
  cat <<'EOF'
Usage: ./organize-files.sh -Sources <dir...> -Targets <dir...> -Output <dir> [options]

Core options:
  -Sources <dir...>
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
  -Threads <count>
  -UseFileNameDate
  -UseMetadataDate
  -UseSupplementalMetadata
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

load_filename_date_formats() {
  local formats_file="$1"
  local line trimmed_line

  [[ -f "$formats_file" ]] || die "Filename date formats file not found: $formats_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed_line="${line#"${line%%[![:space:]]*}"}"
    trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

    if [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]]; then
      continue
    fi

    FILENAME_DATE_FORMATS+=("$trimmed_line")
  done < "$formats_file"

  (( ${#FILENAME_DATE_FORMATS[@]} > 0 )) || die "Filename date formats file is empty: $formats_file"
}

date_format_to_regex() {
  local format="$1"
  local regex="$format"

  regex="${regex//YYYY/(20[0-9]{2})}"
  regex="${regex//MM/([0-1][0-9])}"
  regex="${regex//DD/([0-3][0-9])}"

  printf '%s' "$regex"
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

  local date_format regex_pattern
  for date_format in "${FILENAME_DATE_FORMATS[@]}"; do
    regex_pattern="$(date_format_to_regex "$date_format")"
    if [[ "$name" =~ $regex_pattern ]]; then
      year="${BASH_REMATCH[1]}"
      month="${BASH_REMATCH[2]}"
      day="${BASH_REMATCH[3]}"
      date_components_to_epoch "$year" "$month" "$day"
      return 0
    fi
  done

  return 1
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
  local category_name supplemental_epoch metadata_epoch filename_epoch creation_epoch

  if (( USE_SUPPLEMENTAL_METADATA )); then
    if supplemental_epoch="$(get_supplemental_date_epoch "$file_path")"; then
      printf '%s' "$supplemental_epoch"
      return 0
    fi
  fi

  category_name="$(get_category_name_for_file "$file_path" || true)"

  if (( USE_METADATA_DATE )) && [[ "$category_name" == "Images" || "$category_name" == "Videos" ]]; then
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

parse_datetime_to_epoch() {
  local value="$1"
  local parsed

  if [[ "$value" =~ ^[0-9]{10,13}$ ]]; then
    if (( ${#value} > 10 )); then
      printf '%s' "$((value / 1000))"
    else
      printf '%s' "$value"
    fi
    return 0
  fi

  if [[ "$OS_NAME" == "Darwin" ]]; then
    local normalized="$value"
    normalized="${normalized/Z/+0000}"
    parsed="$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null || true)"
    if [[ "$parsed" =~ ^[0-9]+$ ]]; then
      printf '%s' "$parsed"
      return 0
    fi

    parsed="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$value" '+%s' 2>/dev/null || true)"
    if [[ "$parsed" =~ ^[0-9]+$ ]]; then
      printf '%s' "$parsed"
      return 0
    fi
  else
    parsed="$(date -u -d "$value" '+%s' 2>/dev/null || true)"
    if [[ "$parsed" =~ ^[0-9]+$ ]]; then
      printf '%s' "$parsed"
      return 0
    fi
  fi

  return 1
}

extract_json_string_value() {
  local metadata_json="$1"
  local field_name="$2"
  local compact

  compact="$(printf '%s' "$metadata_json" | tr -d '\r\n')"
  printf '%s' "$compact" | sed -nE "s/.*\"$field_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" | head -n 1
}

extract_json_numeric_value() {
  local metadata_json="$1"
  local field_name="$2"
  local compact

  compact="$(printf '%s' "$metadata_json" | tr -d '\r\n')"
  printf '%s' "$compact" | sed -nE "s/.*\"$field_name\"[[:space:]]*:[[:space:]]*([0-9]{10,13}).*/\1/p" | head -n 1
}

extract_nested_timestamp_value() {
  local metadata_json="$1"
  local field_name="$2"
  local compact object_snippet

  compact="$(printf '%s' "$metadata_json" | tr -d '\r\n')"
  object_snippet="$(printf '%s' "$compact" | grep -oE "\"$field_name\"[[:space:]]*:[[:space:]]*\{[^}]*\}" | head -n 1 || true)"
  if [[ -z "$object_snippet" ]]; then
    return 1
  fi

  printf '%s' "$object_snippet" | sed -nE 's/.*"timestamp"[[:space:]]*:[[:space:]]*"?([0-9]{10,13})"?.*/\1/p' | head -n 1
}

extract_nested_formatted_value() {
  local metadata_json="$1"
  local field_name="$2"
  local compact object_snippet

  compact="$(printf '%s' "$metadata_json" | tr -d '\r\n')"
  object_snippet="$(printf '%s' "$compact" | grep -oE "\"$field_name\"[[:space:]]*:[[:space:]]*\{[^}]*\}" | head -n 1 || true)"
  if [[ -z "$object_snippet" ]]; then
    return 1
  fi

  printf '%s' "$object_snippet" | sed -nE 's/.*"formatted"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

extract_metadata_field_epoch() {
  local metadata_json="$1"
  local field_name="$2"
  local candidate

  candidate="$(extract_json_numeric_value "$metadata_json" "$field_name" || true)"
  if [[ -n "$candidate" ]]; then
    parse_datetime_to_epoch "$candidate"
    return $?
  fi

  candidate="$(extract_json_string_value "$metadata_json" "$field_name" || true)"
  if [[ -n "$candidate" ]]; then
    parse_datetime_to_epoch "$candidate"
    return $?
  fi

  candidate="$(extract_nested_timestamp_value "$metadata_json" "$field_name" || true)"
  if [[ -n "$candidate" ]]; then
    parse_datetime_to_epoch "$candidate"
    return $?
  fi

  candidate="$(extract_nested_formatted_value "$metadata_json" "$field_name" || true)"
  if [[ -n "$candidate" ]]; then
    parse_datetime_to_epoch "$candidate"
    return $?
  fi

  return 1
}

get_primary_supplemental_epoch_from_json() {
  local metadata_json="$1"
  local key epoch

  for key in CreationTime LastWriteTime creationTime lastWriteTime photoTakenTime modificationTime photoLastModifiedTime; do
    if epoch="$(extract_metadata_field_epoch "$metadata_json" "$key")"; then
      printf '%s' "$epoch"
      return 0
    fi
  done

  return 1
}

get_supplemental_date_epoch() {
  local file_path="$1"
  local metadata_json epoch

  metadata_json="$(get_supplemental_metadata "$file_path" || true)"
  if [[ -z "$metadata_json" ]]; then
    return 1
  fi

  if epoch="$(get_primary_supplemental_epoch_from_json "$metadata_json")"; then
    printf '%s' "$epoch"
    return 0
  fi

  return 1
}

get_supplemental_metadata_path() {
  local file_path="$1"
  local metadata_filename
  metadata_filename="$(basename -- "$file_path").supplemental-metadata.json"
  printf '%s/%s' "$(dirname -- "$file_path")" "$metadata_filename"
}

get_supplemental_metadata() {
  local file_path="$1"
  local metadata_path

  if (( ! USE_SUPPLEMENTAL_METADATA )); then
    return 1
  fi

  metadata_path="$(get_supplemental_metadata_path "$file_path")"

  if [[ ! -f "$metadata_path" ]]; then
    return 1
  fi

  cat "$metadata_path"
}

apply_supplemental_metadata() {
  local destination_path="$1"
  local metadata_json="$2"
  local primary_epoch

  if [[ -z "$metadata_json" ]] || [[ ! -f "$destination_path" ]]; then
    return 1
  fi

  if primary_epoch="$(get_primary_supplemental_epoch_from_json "$metadata_json")"; then
    if [[ "$OS_NAME" == "Darwin" ]]; then
      touch -t "$(date -u -r "$primary_epoch" '+%Y%m%d%H%M.%S')" "$destination_path" 2>/dev/null || true
    else
      touch -d "@$primary_epoch" -- "$destination_path" 2>/dev/null || true
    fi
  fi

  echo "Applied metadata to: $destination_path"
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

validate_positive_integer() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "$label must be a non-negative integer, got: $value"
  fi
}

validate_positive_integer_nonzero() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    die "$label must be a positive integer, got: $value"
  fi
}

require_directory() {
  local directory_path="$1"
  local label="$2"

  if [[ ! -d "$directory_path" ]]; then
    die "$label directory not found: $directory_path"
  fi
}

load_category_definitions "$CATEGORY_DEFINITIONS_FILE"
load_filename_date_formats "$FILENAME_DATE_FORMATS_FILE"

while (( $# > 0 )); do
  case "$1" in
    -Sources|-Source)
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
    -Threads)
      shift
      (( $# > 0 )) || die "Missing value for -Threads"
      THREADS="$1"
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
    -UseMetadataDate)
      USE_METADATA_DATE=1
      shift
      ;;
    -UseSupplementalMetadata)
      USE_SUPPLEMENTAL_METADATA=1
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
  die "-Sources requires at least one directory"
fi

if (( ${#TARGET_DIRS[@]} == 0 )); then
  die "-Targets requires at least one directory"
fi

if [[ -z "$OUTPUT" ]]; then
  die "-Output is required"
fi

validate_positive_integer "$MAX_FILES" "-MaxFiles"
validate_positive_integer_nonzero "$THREADS" "-Threads"

if (( ! USE_NAME && ! USE_DATE && ! USE_SIZE )); then
  echo "Defaulting to: Name + Date"
  USE_NAME=1
  USE_DATE=1
fi

if (( THREADS > 1 )) && ! command -v xargs >/dev/null 2>&1; then
  die "-Threads requires xargs to be available"
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
plan_file="$(mktemp)"
TEMP_FILES+=("$plan_file")
plan_count=0
has_destination_collisions=0
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
      append_log_line "$log_line"
    else
      if [[ -n "${PLANNED_DESTINATIONS[$destination_path]+x}" ]]; then
        has_destination_collisions=1
      else
        PLANNED_DESTINATIONS["$destination_path"]=1
      fi

      printf '%s\0%s\0%s\0%s\0%s\0' "replace" "$file_path" "$destination_path" "$dest_root" "$log_line" >> "$plan_file"
      plan_count=$((plan_count + 1))
    fi
  else
    log_line="${TRANSFER_VERB}: $file_path -> $destination_path"

    if (( DRY_RUN )); then
      echo "[SIMULATION] $log_line"
      append_log_line "$log_line"
    else
      if [[ -n "${PLANNED_DESTINATIONS[$destination_path]+x}" ]]; then
        has_destination_collisions=1
      else
        PLANNED_DESTINATIONS["$destination_path"]=1
      fi

      printf '%s\0%s\0%s\0%s\0%s\0' "transfer" "$file_path" "$destination_path" "$dest_root" "$log_line" >> "$plan_file"
      plan_count=$((plan_count + 1))
    fi
  fi
done

if (( total > 0 )); then
  printf '\n' >&2
fi

if (( ! DRY_RUN && plan_count > 0 )); then
  effective_threads=$THREADS
  if (( effective_threads > plan_count )); then
    effective_threads=$plan_count
  fi

  if (( has_destination_collisions && effective_threads > 1 )); then
    echo "Destination collisions detected in the transfer plan. Falling back to a single-threaded transfer phase."
    effective_threads=1
  fi

  if (( effective_threads > 1 )); then
    echo "Processing $plan_count file transfers with $effective_threads threads..."

    xargs -0 -n 5 -P "$effective_threads" bash -c '
      set -euo pipefail
      move_files="$1"
      os_name="$2"
      plan_type="$3"
      source_path="$4"
      destination_path="$5"
      dest_root="$6"
      log_line="$7"

      mkdir -p -- "$dest_root"

      if (( move_files )); then
        if [[ "$os_name" == "Darwin" ]]; then
          mv -f "$source_path" "$destination_path"
        else
          mv -f -- "$source_path" "$destination_path"
        fi
      else
        if [[ "$os_name" == "Darwin" ]]; then
          cp -f "$source_path" "$destination_path"
        else
          cp -f -- "$source_path" "$destination_path"
        fi
      fi
    ' _ "$MOVE_FILES" "$OS_NAME" < "$plan_file"
  else
    while IFS= read -r -d '' plan_type \
      && IFS= read -r -d '' source_path \
      && IFS= read -r -d '' destination_path \
      && IFS= read -r -d '' dest_root \
      && IFS= read -r -d '' log_line; do
      mkdir -p -- "$dest_root"
      invoke_transfer "$source_path" "$destination_path"
    done < "$plan_file"
  fi

  while IFS= read -r -d '' plan_type \
    && IFS= read -r -d '' source_path \
    && IFS= read -r -d '' destination_path \
    && IFS= read -r -d '' dest_root \
    && IFS= read -r -d '' log_line; do
    echo "$log_line"
    append_log_line "$log_line"

    # Apply supplemental metadata if available
    if (( USE_SUPPLEMENTAL_METADATA )); then
      metadata_json="$(get_supplemental_metadata "$source_path" || true)"
      if [[ -n "$metadata_json" ]]; then
        apply_supplemental_metadata "$destination_path" "$metadata_json"
      fi
    fi

    if [[ "$plan_type" == "replace" ]]; then
      replaced=$((replaced + 1))
    else
      transferred=$((transferred + 1))
    fi
  done < "$plan_file"
fi

echo
echo "========== SUMMARY =========="
echo "Total scanned : $total"
printf '%-13s: %s\n' "$TRANSFER_SUMMARY_LABEL" "$transferred"
echo "Replaced      : $replaced"
echo "Skipped       : $skipped"
echo "============================="