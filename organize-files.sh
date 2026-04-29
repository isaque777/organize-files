#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CATEGORY_DEFINITIONS_FILE="$SCRIPT_DIR/config/category-definitions.tsv"
FILENAME_DATE_FORMATS_FILE="$SCRIPT_DIR/config/filename-date-formats.txt"

if [[ ! -f "$CATEGORY_DEFINITIONS_FILE" ]]; then
  CATEGORY_DEFINITIONS_FILE="$SCRIPT_DIR/category-definitions.tsv"
fi

if [[ ! -f "$FILENAME_DATE_FORMATS_FILE" ]]; then
  FILENAME_DATE_FORMATS_FILE="$SCRIPT_DIR/filename-date-formats.txt"
fi

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
GENERATE_REPORT=0
REPORT_FILE=""
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
  -GenerateReport
  -ReportFile <path>

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

csv_escape() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

append_csv_row() {
  local file_path="$1"
  shift
  local first=1 value

  for value in "$@"; do
    if (( first )); then
      first=0
    else
      printf ',' >> "$file_path"
    fi
    csv_escape "$value" >> "$file_path"
  done
  printf '\n' >> "$file_path"
}

format_epoch_iso() {
  local epoch="$1"

  if [[ -z "$epoch" ]] || (( epoch <= 0 )); then
    printf ''
    return
  fi

  format_epoch "$epoch" '%Y-%m-%dT%H:%M:%SZ'
}

get_default_report_file() {
  if [[ -n "$REPORT_FILE" ]]; then
    printf '%s' "$REPORT_FILE"
  else
    printf '%s' "$OUTPUT/organize-files-report.csv"
  fi
}

write_transfer_report() {
  local report_path="$1"
  local status="$2"
  local report_dir final_mtime final_mtime_iso final_creation final_creation_iso selected_iso
  local plan_type source_path destination_path dest_root log_line metadata_date_epoch supplemental_date_epoch selected_date_epoch date_source reliable_date_found size_bytes file_date_set_source

  report_dir="$(dirname -- "$report_path")"
  mkdir -p -- "$report_dir"
  : > "$report_path"
  append_csv_row "$report_path" Operation SourcePath DestinationPath SizeBytes SelectedDate DateSource ReliableDateFound FileDateSet FileDateSetSource FinalCreationTime FinalLastWriteTime Status

  while IFS= read -r -d '' plan_type \
    && IFS= read -r -d '' source_path \
    && IFS= read -r -d '' destination_path \
    && IFS= read -r -d '' dest_root \
    && IFS= read -r -d '' log_line \
    && IFS= read -r -d '' metadata_date_epoch \
    && IFS= read -r -d '' supplemental_date_epoch \
    && IFS= read -r -d '' selected_date_epoch \
    && IFS= read -r -d '' date_source \
    && IFS= read -r -d '' reliable_date_found \
    && IFS= read -r -d '' size_bytes \
    && IFS= read -r -d '' file_date_set_source; do
    if [[ "$status" == "Completed" && "$reliable_date_found" == "1" && "$date_source" != Filesystem:* ]]; then
      file_date_set_source="$date_source"
    fi

    selected_iso="$(format_epoch_iso "$selected_date_epoch")"
    final_creation_iso=""
    final_mtime_iso=""
    if [[ -f "$destination_path" ]]; then
      final_creation="$(get_creation_epoch "$destination_path")"
      final_mtime="$(get_mtime_epoch "$destination_path")"
      final_creation_iso="$(format_epoch_iso "$final_creation")"
      final_mtime_iso="$(format_epoch_iso "$final_mtime")"
    fi

    if [[ -z "$file_date_set_source" && "$status" != "Planned" && "$reliable_date_found" == "1" && "$date_source" != Filesystem:* ]]; then
      file_date_set_source="$date_source"
    fi

    append_csv_row "$report_path" "$plan_type" "$source_path" "$destination_path" "$size_bytes" "$selected_iso" "$date_source" "$reliable_date_found" "$([[ -n "$file_date_set_source" ]] && printf true || printf false)" "$file_date_set_source" "$final_creation_iso" "$final_mtime_iso" "$status"
  done < "$plan_file"

  echo "Report written to: $report_path"
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
  local remaining="$format"
  local regex=""

  DATE_TOKEN_ORDER=()
  while [[ -n "$remaining" ]]; do
    case "$remaining" in
      HHMMSS*) regex+='([01][0-9]|2[0-3])([0-5][0-9])([0-5][0-9])'; DATE_TOKEN_ORDER+=("HH" "MI" "SS"); remaining="${remaining:6}" ;;
      YYYY*) regex+='(19[0-9]{2}|20[0-9]{2}|21[0-9]{2})'; DATE_TOKEN_ORDER+=("YYYY"); remaining="${remaining:4}" ;;
      MM*) regex+='(0[1-9]|1[0-2])'; DATE_TOKEN_ORDER+=("MM"); remaining="${remaining:2}" ;;
      DD*) regex+='(0[1-9]|[12][0-9]|3[01])'; DATE_TOKEN_ORDER+=("DD"); remaining="${remaining:2}" ;;
      HH*) regex+='([01][0-9]|2[0-3])'; DATE_TOKEN_ORDER+=("HH"); remaining="${remaining:2}" ;;
      MI*) regex+='([0-5][0-9])'; DATE_TOKEN_ORDER+=("MI"); remaining="${remaining:2}" ;;
      SS*) regex+='([0-5][0-9])'; DATE_TOKEN_ORDER+=("SS"); remaining="${remaining:2}" ;;
      *) regex+='[^[:alnum:]]*'; remaining="${remaining:1}" ;;
    esac
  done

  DATE_REGEX="(^|[^0-9])${regex}([^0-9]|$)"
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

is_epoch_today() {
  local epoch="$1"
  local epoch_date current_date

  if [[ -z "$epoch" ]] || (( epoch <= 0 )); then
    return 1
  fi

  if [[ "$OS_NAME" == "Darwin" ]]; then
    epoch_date="$(date -r "$epoch" '+%Y-%m-%d' 2>/dev/null || true)"
  else
    epoch_date="$(date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null || true)"
  fi

  current_date="$(date '+%Y-%m-%d')"
  [[ -n "$epoch_date" && "$epoch_date" == "$current_date" ]]
}

apply_file_date_epoch() {
  local destination_path="$1"
  local epoch="$2"
  local label="$3"

  if [[ -z "$epoch" ]] || (( epoch <= 0 )) || [[ ! -f "$destination_path" ]]; then
    return 1
  fi

  if [[ "$OS_NAME" == "Darwin" ]]; then
    touch -t "$(date -r "$epoch" '+%Y%m%d%H%M.%S')" "$destination_path" 2>/dev/null || return 1
  else
    touch -d "@$epoch" -- "$destination_path" 2>/dev/null || return 1
  fi

  echo "Applied $label to: $destination_path"
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
  local hour="00"
  local minute="00"
  local second="00"

  local date_format regex_pattern group_index token match_offset
  for date_format in "${FILENAME_DATE_FORMATS[@]}"; do
    date_format_to_regex "$date_format"
    regex_pattern="$DATE_REGEX"
    if [[ "$name" =~ $regex_pattern ]]; then
      match_offset=2
      group_index=0
      year=""; month=""; day=""; hour="00"; minute="00"; second="00"
      for token in "${DATE_TOKEN_ORDER[@]}"; do
        group_index=$((group_index + 1))
        case "$token" in
          YYYY) year="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
          MM) month="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
          DD) day="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
          HH) hour="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
          MI) minute="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
          SS) second="${BASH_REMATCH[$((group_index + match_offset - 1))]}" ;;
        esac
      done

      if [[ -n "$year" && -n "$month" && -n "$day" ]]; then
        date_components_to_epoch_time "$year" "$month" "$day" "$hour" "$minute" "$second"
        return 0
      fi
    fi
  done

  return 1
}

date_components_to_epoch_time() {
  local year="$1"
  local month="$2"
  local day="$3"
  local hour="$4"
  local minute="$5"
  local second="$6"

  if [[ "$OS_NAME" == "Darwin" ]]; then
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$year-$month-$day $hour:$minute:$second" '+%s' 2>/dev/null
  else
    date -u -d "$year-$month-$day $hour:$minute:$second" '+%s' 2>/dev/null
  fi
}

get_metadata_date_epoch() {
  local info
  info="$(get_metadata_date_info "$1" || true)"
  if [[ -n "$info" ]]; then
    printf '%s' "${info%%$'\t'*}"
    return 0
  fi
  return 1
}

get_metadata_date_info() {
  local file_path="$1"
  local tag value

  if (( ! EXIFTOOL_AVAILABLE )); then
    return 1
  fi

  for tag in DateTimeOriginal MediaCreateDate CreationDate CreateDate TrackCreateDate MediaModifyDate FileModifyDate ModifyDate; do
    value="$(exiftool -s3 -d '%s' -"$tag" -- "$file_path" 2>/dev/null | head -n 1 || true)"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
      printf '%s\tMetadata:%s' "$value" "$tag"
      return 0
    fi
  done


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
  local supplemental_epoch="${2:-}"
  local metadata_epoch="${3:-}"
  local supplemental_checked="${4:-0}"
  local metadata_checked="${5:-0}"
  local category_name filename_epoch creation_epoch

  if (( USE_SUPPLEMENTAL_METADATA )); then
    if [[ -n "$supplemental_epoch" ]]; then
      printf '%s' "$supplemental_epoch"
      return 0
    fi

    if [[ "$supplemental_checked" != "1" ]] && supplemental_epoch="$(get_supplemental_date_epoch "$file_path")"; then
      printf '%s' "$supplemental_epoch"
      return 0
    fi
  fi

  category_name="$(get_category_name_for_file "$file_path" || true)"

  if (( USE_METADATA_DATE )) && [[ "$category_name" == "Images" || "$category_name" == "Videos" ]]; then
    if [[ -n "$metadata_epoch" ]]; then
      printf '%s' "$metadata_epoch"
      return 0
    fi

    if [[ "$metadata_checked" != "1" ]] && metadata_epoch="$(get_metadata_date_epoch "$file_path")"; then
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
  local file_name base_name parent_dir

  file_name="$(basename -- "$file_path")"
  base_name="${file_name%.*}"
  parent_dir="$(dirname -- "$file_path")"

  printf '%s\n' "$parent_dir/$file_name.supplemental-metadata.json"
  printf '%s\n' "$parent_dir/$file_name.json"
  printf '%s\n' "$parent_dir/$base_name.json"
}

get_supplemental_metadata() {
  local file_path="$1"
  local metadata_path

  if (( ! USE_SUPPLEMENTAL_METADATA )); then
    return 1
  fi

  while IFS= read -r metadata_path; do
    if [[ -f "$metadata_path" ]]; then
      cat "$metadata_path"
      return 0
    fi
  done < <(get_supplemental_metadata_path "$file_path")

  return 1
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

apply_date_taken_fallback() {
  local destination_path="$1"
  local metadata_epoch="$2"
  local supplemental_epoch="$3"
  local destination_mtime

  if [[ -z "$metadata_epoch" ]] || (( metadata_epoch <= 0 )) || [[ ! -f "$destination_path" ]]; then
    return 0
  fi

  destination_mtime="$(get_mtime_epoch "$destination_path")"
  if [[ -n "$supplemental_epoch" ]] && ! is_epoch_today "$destination_mtime"; then
    return 0
  fi

  apply_file_date_epoch "$destination_path" "$metadata_epoch" "Date taken" || \
    echo "Warning: Failed to apply Date taken to file: $destination_path"
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
    -ReportFile)
      shift
      (( $# > 0 )) || die "Missing value for -ReportFile"
      REPORT_FILE="$1"
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
    -GenerateReport)
      GENERATE_REPORT=1
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
  category_name="$(get_category_name_for_file "$file_path" || true)"
  supplemental_date_epoch=""
  metadata_date_epoch=""
  metadata_date_info=""
  metadata_date_source=""
  filename_date_epoch=""
  creation_epoch=""
  modified_epoch=""
  best_date_source=""
  reliable_date_found=0
  supplemental_date_checked=0
  metadata_date_checked=0

  if (( USE_SUPPLEMENTAL_METADATA )); then
    supplemental_date_checked=1
    supplemental_date_epoch="$(get_supplemental_date_epoch "$file_path" || true)"
  fi

  if (( USE_METADATA_DATE )) && [[ "$category_name" == "Images" || "$category_name" == "Videos" ]]; then
    metadata_date_checked=1
    metadata_date_info="$(get_metadata_date_info "$file_path" || true)"
    if [[ -n "$metadata_date_info" ]]; then
      metadata_date_epoch="${metadata_date_info%%$'\t'*}"
      metadata_date_source="${metadata_date_info#*$'\t'}"
    fi
  fi

  filename_date_epoch="$(get_date_from_filename_epoch "$(basename -- "$file_path")" || true)"
  creation_epoch="$(get_creation_epoch "$file_path")"
  modified_epoch="$(get_mtime_epoch "$file_path")"

  if [[ -n "$supplemental_date_epoch" ]]; then
    best_date_epoch="$supplemental_date_epoch"
    best_date_source="Supplemental"
    reliable_date_found=1
  elif [[ -n "$metadata_date_epoch" ]]; then
    best_date_epoch="$metadata_date_epoch"
    best_date_source="$metadata_date_source"
    reliable_date_found=1
  elif [[ -n "$filename_date_epoch" ]]; then
    best_date_epoch="$filename_date_epoch"
    best_date_source="Filename"
    reliable_date_found=1
  elif [[ -n "$creation_epoch" ]] && (( creation_epoch > 0 )); then
    best_date_epoch="$creation_epoch"
    best_date_source="Filesystem:CreationTime"
  else
    best_date_epoch="$modified_epoch"
    best_date_source="Filesystem:LastWriteTime"
  fi

  best_date_display="$(format_optional_epoch "$best_date_epoch")"
  created_display="$(format_optional_epoch "$creation_epoch")"
  modified_display="$(format_optional_epoch "$modified_epoch")"

  date_log="DATE: $(basename -- "$file_path") | Selected=$best_date_display | Source=$best_date_source | Reliable=$reliable_date_found | Created=$created_display | Modified=$modified_display"
  echo "$date_log"
  append_log_line "$date_log"

  dest_root="$OUTPUT"

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
    fi

    if (( ! DRY_RUN )); then
      if [[ -n "${PLANNED_DESTINATIONS[$destination_path]+x}" ]]; then
        has_destination_collisions=1
      else
        PLANNED_DESTINATIONS["$destination_path"]=1
      fi
    fi

    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "replace" "$file_path" "$destination_path" "$dest_root" "$log_line" "$metadata_date_epoch" "$supplemental_date_epoch" "$best_date_epoch" "$best_date_source" "$reliable_date_found" "$(stat_size "$file_path")" "" >> "$plan_file"
    plan_count=$((plan_count + 1))
  else
    log_line="${TRANSFER_VERB}: $file_path -> $destination_path"

    if (( DRY_RUN )); then
      echo "[SIMULATION] $log_line"
      append_log_line "$log_line"
    fi

    if (( ! DRY_RUN )); then
      if [[ -n "${PLANNED_DESTINATIONS[$destination_path]+x}" ]]; then
        has_destination_collisions=1
      else
        PLANNED_DESTINATIONS["$destination_path"]=1
      fi
    fi

    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "transfer" "$file_path" "$destination_path" "$dest_root" "$log_line" "$metadata_date_epoch" "$supplemental_date_epoch" "$best_date_epoch" "$best_date_source" "$reliable_date_found" "$(stat_size "$file_path")" "" >> "$plan_file"
    plan_count=$((plan_count + 1))
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

    xargs -0 -n 12 -P "$effective_threads" bash -c '
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
      && IFS= read -r -d '' log_line \
      && IFS= read -r -d '' metadata_date_epoch \
      && IFS= read -r -d '' supplemental_date_epoch \
      && IFS= read -r -d '' selected_date_epoch \
      && IFS= read -r -d '' date_source \
      && IFS= read -r -d '' reliable_date_found \
      && IFS= read -r -d '' size_bytes \
      && IFS= read -r -d '' file_date_set_source; do
      mkdir -p -- "$dest_root"
      invoke_transfer "$source_path" "$destination_path"
    done < "$plan_file"
  fi

  while IFS= read -r -d '' plan_type \
    && IFS= read -r -d '' source_path \
    && IFS= read -r -d '' destination_path \
    && IFS= read -r -d '' dest_root \
    && IFS= read -r -d '' log_line \
    && IFS= read -r -d '' metadata_date_epoch \
    && IFS= read -r -d '' supplemental_date_epoch \
    && IFS= read -r -d '' selected_date_epoch \
    && IFS= read -r -d '' date_source \
    && IFS= read -r -d '' reliable_date_found \
    && IFS= read -r -d '' size_bytes \
    && IFS= read -r -d '' file_date_set_source; do
    echo "$log_line"
    append_log_line "$log_line"

    # Apply supplemental metadata if available
    if (( USE_SUPPLEMENTAL_METADATA )); then
      metadata_json="$(get_supplemental_metadata "$source_path" || true)"
      if [[ -n "$metadata_json" ]]; then
        apply_supplemental_metadata "$destination_path" "$metadata_json"
      fi
    fi

    if [[ "$reliable_date_found" == "1" && "$date_source" != Filesystem:* ]]; then
      apply_file_date_epoch "$destination_path" "$selected_date_epoch" "$date_source" || \
        echo "Warning: Failed to apply selected date to file: $destination_path"
    fi

    if [[ "$plan_type" == "replace" ]]; then
      replaced=$((replaced + 1))
    else
      transferred=$((transferred + 1))
    fi
  done < "$plan_file"
fi

if (( GENERATE_REPORT )); then
  if (( DRY_RUN )); then
    write_transfer_report "$(get_default_report_file)" "Planned"
  else
    write_transfer_report "$(get_default_report_file)" "Completed"
  fi
fi

echo
echo "========== SUMMARY =========="
echo "Total scanned : $total"
printf '%-13s: %s\n' "$TRANSFER_SUMMARY_LABEL" "$transferred"
echo "Replaced      : $replaced"
echo "Skipped       : $skipped"
echo "============================="