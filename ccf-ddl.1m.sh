#!/bin/bash
# <xbar.title>CCF Conference Deadlines</xbar.title>
# <xbar.version>3.2</xbar.version>
# <xbar.author>OpenAI</xbar.author>
# <xbar.desc>SwiftBar/xbar conference deadlines with selectable conferences, time-zone conversion, and full timelines.</xbar.desc>
# <xbar.dependencies>bash,jq</xbar.dependencies>

# macOS ships Bash 3.2, so this script intentionally avoids associative arrays,
# mapfile/readarray, GNU-only sed flags, and other newer Bash features.

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
SCRIPT_PATH="${SWIFTBAR_PLUGIN_PATH:-$0}"
case "$SCRIPT_PATH" in
  /*) ;;
  *) SCRIPT_PATH="$SCRIPT_DIR/$(basename "$SCRIPT_PATH")" ;;
esac
DEFAULT_CONFIG_FILE="$HOME/.config/xbar/ccf-ddl.json"
CONFIG_FILE="${CCF_DDL_CONFIG:-$DEFAULT_CONFIG_FILE}"

# Keep the repository directly runnable while preferring the installed config.
if [ -z "${CCF_DDL_CONFIG:-}" ] && [ ! -f "$CONFIG_FILE" ] && [ -f "$SCRIPT_DIR/ccf-ddl.json" ]; then
  CONFIG_FILE="$SCRIPT_DIR/ccf-ddl.json"
fi
NOW_EPOCH="$(date +%s)"

# Defaults; replaced by values from ccf-ddl.json after validation.
WARNING_DAYS=7
URGENT_DAYS=3
IMPORTANT_DAYS=14
DISPLAY_LOCAL_TIME=true
SHOW_PHASE_IN_CAROUSEL=false
SHOW_CCF_LEVEL=false
SHOW_FINISHED=false
CAROUSEL_LIMIT=0   # 0 = rotate all active conferences
SORT_BY_DEADLINE=true

TMP_BASE="${TMPDIR:-/tmp}/ccf-ddl.$$"
CAROUSEL_FILE="${TMP_BASE}.carousel"
DROPDOWN_FILE="${TMP_BASE}.dropdown"
SORTED_FILE="${TMP_BASE}.sorted"
RECORDS_FILE="${TMP_BASE}.records"
TIMELINE_TMP="${TMP_BASE}.timeline"
VISIBILITY_FILE="${TMP_BASE}.visibility"
: > "$CAROUSEL_FILE"
: > "$DROPDOWN_FILE"
: > "$TIMELINE_TMP"
: > "$VISIBILITY_FILE"
trap 'rm -f "$CAROUSEL_FILE" "$DROPDOWN_FILE" "$SORTED_FILE" "$RECORDS_FILE" "$TIMELINE_TMP" "$VISIBILITY_FILE"' EXIT HUP INT TERM

sanitize_text() {
  # xbar uses | as the parameter delimiter.
  printf '%s' "$1" | tr '|' '/'
}

swiftbar_escape_attribute() {
  # Attribute values are double-quoted in SwiftBar output.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

SCRIPT_ACTION_PATH="$(swiftbar_escape_attribute "$SCRIPT_PATH")"

trim_cr() {
  printf '%s' "$1" | tr -d '\r'
}

normalize_tz() {
  case "$1" in
    AoE|AOE|aoe) printf '%s' 'Etc/GMT+12' ;;
    UTC|utc|GMT|gmt) printf '%s' 'UTC' ;;
    *) printf '%s' "$1" ;;
  esac
}

display_tz() {
  case "$1" in
    AoE|AOE|aoe) printf '%s' 'AoE' ;;
    *) printf '%s' "$1" ;;
  esac
}

is_gnu_date() {
  date --version >/dev/null 2>&1
}

parse_epoch() {
  # Usage: parse_epoch "2027-04-10 23:59" "AoE"
  local dt="$1"
  local tz_raw="$2"
  local tz
  tz="$(normalize_tz "$tz_raw")"

  if is_gnu_date; then
    TZ="$tz" date -d "$dt" +%s 2>/dev/null
  else
    # BSD date (macOS): TZ determines how the input wall-clock time is interpreted.
    TZ="$tz" date -j -f '%Y-%m-%d %H:%M' "$dt" '+%s' 2>/dev/null
  fi
}

remaining_text() {
  local delta="$1"
  local days hours
  if [ "$delta" -le 0 ]; then
    printf '%s' 'now'
  elif [ "$delta" -ge 86400 ]; then
    days=$((delta / 86400))
    hours=$(( (delta % 86400) / 3600 ))
    printf '%sd%sh' "$days" "$hours"
  elif [ "$delta" -ge 3600 ]; then
    printf '%sh' "$((delta / 3600))"
  else
    printf '%sm' "$(( (delta + 59) / 60 ))"
  fi
}

status_color() {
  local delta="$1"
  local urgent_secs=$((URGENT_DAYS * 86400))
  local warning_secs=$((WARNING_DAYS * 86400))
  if [ "$delta" -le "$urgent_secs" ]; then
    printf '%s' 'red'
  elif [ "$delta" -le "$warning_secs" ]; then
    printf '%s' 'orange'
  else
    printf '%s' ''
  fi
}

bool_true() {
  case "$1" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

format_datetime() {
  local epoch="$1"
  local source_datetime="$2"
  local source_timezone="$3"
  local converted

  if bool_true "$DISPLAY_LOCAL_TIME"; then
    if is_gnu_date; then
      converted="$(date -d "@$epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)"
    else
      converted="$(date -r "$epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)"
    fi

    if [ -n "$converted" ]; then
      printf '%s' "$converted (local)"
      return 0
    fi
  fi

  printf '%s %s' "$source_datetime" "$(display_tz "$source_timezone")"
}

emit_error() {
  echo "⚠ CCF DDL"
  echo "---"
  echo "$(sanitize_text "$1")"
  if [ -n "${2:-}" ]; then
    echo "--$(sanitize_text "$2")"
  fi
  exit 0
}

set_conference_visibility() {
  local conference_index="$1"
  local new_visibility="$2"
  local config_tmp original_mode

  case "$conference_index" in
    ''|*[!0-9]*)
      printf '%s\n' "Invalid conference index: $conference_index" >&2
      return 1
      ;;
  esac

  case "$new_visibility" in
    true|false) ;;
    *)
      printf '%s\n' "Invalid visibility value: $new_visibility" >&2
      return 1
      ;;
  esac

  config_tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || {
    printf '%s\n' "Unable to create a temporary configuration beside: $CONFIG_FILE" >&2
    return 1
  }

  if ! jq --argjson conference_index "$conference_index" \
          --argjson new_visibility "$new_visibility" '
    if $conference_index >= 0 and $conference_index < (.conferences | length) then
      .conferences[$conference_index].visible = $new_visibility
    else
      error("conference index out of range")
    end
  ' "$CONFIG_FILE" > "$config_tmp"; then
    rm -f "$config_tmp"
    printf '%s\n' "Unable to update conference visibility in: $CONFIG_FILE" >&2
    return 1
  fi

  original_mode="$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || stat -c '%a' "$CONFIG_FILE" 2>/dev/null)"
  if [ -n "$original_mode" ]; then
    chmod "$original_mode" "$config_tmp" 2>/dev/null || true
  fi

  if ! mv "$config_tmp" "$CONFIG_FILE"; then
    rm -f "$config_tmp"
    printf '%s\n' "Unable to replace configuration: $CONFIG_FILE" >&2
    return 1
  fi
}

[ -f "$CONFIG_FILE" ] || emit_error "Configuration not found" "Expected: $CONFIG_FILE"
command -v jq >/dev/null 2>&1 || emit_error "Missing dependency: jq" "Install it with: brew install jq"

validate_config() {
  jq -e '
    def nonempty_string: type == "string" and length > 0;
    .schema_version == 1 and
    (.settings | type == "object") and
    (.settings.warning_days | type == "number" and . >= 0 and floor == .) and
    (.settings.urgent_days | type == "number" and . >= 0 and floor == .) and
    (.settings.important_days | type == "number" and . >= 0 and floor == .) and
    (((.settings | has("display_local_time")) == false) or
      (.settings.display_local_time | type == "boolean")) and
    (((.settings | has("show_phase_in_carousel")) == false) or
      (.settings.show_phase_in_carousel | type == "boolean")) and
    (((.settings | has("show_ccf_level")) == false) or
      (.settings.show_ccf_level | type == "boolean")) and
    (.settings.show_finished | type == "boolean") and
    (.settings.carousel_limit | type == "number" and . >= 0 and floor == .) and
    (.settings.sort_by_deadline | type == "boolean") and
    (.conferences | type == "array" and length > 0) and
    all(.conferences[];
      (.name | nonempty_string) and
      (.short_name | nonempty_string) and
      (.ccf_level | nonempty_string) and
      (.visible | type == "boolean") and
      (.timezone | nonempty_string) and
      (.url | type == "string") and
      (.order | type == "number" and floor == .) and
      (.stages | type == "array" and length > 0) and
      all(.stages[];
        (.phase | nonempty_string) and
        (.event | nonempty_string) and
        (.datetime | nonempty_string) and
        (((. | has("timezone")) == false) or (.timezone | nonempty_string))
      )
    )
  ' "$CONFIG_FILE" >/dev/null 2>&1
}

validate_config || emit_error "Invalid JSON configuration" "Check schema version and required fields in: $CONFIG_FILE"

case "${1:-}" in
  --set-visible)
    set_conference_visibility "${2:-}" "${3:-}" || exit 1
    exit 0
    ;;
  '') ;;
  *)
    printf '%s\n' "Unknown action: $1" >&2
    exit 2
    ;;
esac

SETTINGS_LINE="$(jq -r '[
  .settings.warning_days,
  .settings.urgent_days,
  .settings.important_days,
  (.settings | if has("display_local_time") then .display_local_time else true end),
  (.settings | if has("show_phase_in_carousel") then .show_phase_in_carousel else false end),
  (.settings | if has("show_ccf_level") then .show_ccf_level else false end),
  .settings.show_finished,
  .settings.carousel_limit,
  .settings.sort_by_deadline
] | @tsv' "$CONFIG_FILE")"

IFS=$'\t' read -r WARNING_DAYS URGENT_DAYS IMPORTANT_DAYS DISPLAY_LOCAL_TIME SHOW_PHASE_IN_CAROUSEL SHOW_CCF_LEVEL SHOW_FINISHED CAROUSEL_LIMIT SORT_BY_DEADLINE <<EOF_SETTINGS
$SETTINGS_LINE
EOF_SETTINGS

# Convert the JSON hierarchy to a small record stream once. The remaining
# state machine stays compatible with the Bash 3.2 bundled with macOS.
jq -r '
  .conferences | to_entries[] |
  .key as $conference_index |
  .value as $conference |
  ([
    "CONF",
    $conference.name,
    $conference.short_name,
    $conference.ccf_level,
    $conference.timezone,
    $conference.url,
    ($conference.order | tostring),
    ($conference.visible | tostring),
    ($conference_index | tostring)
  ] | @tsv),
  ($conference.stages[] | [
    "STAGE",
    .phase,
    .event,
    .datetime,
    (.timezone // $conference.timezone)
  ] | @tsv),
  (["END"] | @tsv)
' "$CONFIG_FILE" > "$RECORDS_FILE" || emit_error "Unable to read JSON configuration" "$CONFIG_FILE"

# Current conference state.
CONF_ACTIVE=false
CONF_FULL=''
CONF_SHORT=''
CONF_CCF=''
CONF_TZ='AoE'
CONF_URL=''
CONF_ORDER='0'
CONF_VISIBLE=true
CONF_INDEX='0'
NEXT_FOUND=false
NEXT_STAGE=''
NEXT_EVENT=''
NEXT_DT=''
NEXT_EPOCH=''
reset_conf() {
  CONF_ACTIVE=true
  CONF_FULL="$1"
  CONF_SHORT="$2"
  CONF_CCF="$3"
  CONF_TZ="$4"
  CONF_URL="$5"
  CONF_ORDER="$6"
  CONF_VISIBLE="$7"
  CONF_INDEX="$8"
  NEXT_FOUND=false
  NEXT_STAGE=''
  NEXT_EVENT=''
  NEXT_DT=''
  NEXT_EPOCH=''
  : > "$TIMELINE_TMP"
}

flush_conf() {
  [ "$CONF_ACTIVE" = true ] || return 0

  local full short ccf conference_label url full_attribute next_visibility checked_parameter
  full="$(sanitize_text "$CONF_FULL")"
  short="$(sanitize_text "$CONF_SHORT")"
  ccf="$(sanitize_text "$CONF_CCF")"
  url="$CONF_URL"
  full_attribute="$(swiftbar_escape_attribute "$full")"

  if bool_true "$SHOW_CCF_LEVEL"; then
    conference_label="[CCF-${ccf}] ${short}"
  else
    conference_label="$short"
  fi

  if bool_true "$CONF_VISIBLE"; then
    next_visibility=false
    checked_parameter=' checked=true'
  else
    next_visibility=true
    checked_parameter=''
  fi
  printf '%s\n' "--${conference_label} | tooltip=\"${full_attribute}\" bash=\"${SCRIPT_ACTION_PATH}\" param1=--set-visible param2=${CONF_INDEX} param3=${next_visibility} terminal=false refresh=true${checked_parameter}" >> "$VISIBILITY_FILE"

  if ! bool_true "$CONF_VISIBLE"; then
    CONF_ACTIVE=false
    return 0
  fi

  if [ "$NEXT_FOUND" = true ]; then
    local delta remain color top_line epoch_key important_secs
    delta=$((NEXT_EPOCH - NOW_EPOCH))
    remain="$(remaining_text "$delta")"
    color="$(status_color "$delta")"
    if bool_true "$SHOW_PHASE_IN_CAROUSEL"; then
      top_line="${conference_label} · ${NEXT_STAGE}→${NEXT_EVENT} · ${remain}"
    else
      top_line="${conference_label} · ${NEXT_EVENT} · ${remain}"
    fi
    epoch_key="$NEXT_EPOCH"
    important_secs=$((IMPORTANT_DAYS * 86400))

    # Only upcoming dates inside the configured importance window rotate in
    # the menu bar. The dropdown still contains every active conference.
    if [ "$delta" -le "$important_secs" ]; then
      if [ -n "$color" ]; then
        printf '%s\t%s\t%s | dropdown=false color=%s\n' "$epoch_key" "$CONF_ORDER" "$top_line" "$color" >> "$CAROUSEL_FILE"
      else
        printf '%s\t%s\t%s | dropdown=false\n' "$epoch_key" "$CONF_ORDER" "$top_line" >> "$CAROUSEL_FILE"
      fi
    fi

    if [ -n "$url" ]; then
      printf '%s | href=%s tooltip="%s"\n' "$conference_label" "$url" "$full_attribute" >> "$DROPDOWN_FILE"
    else
      printf '%s | tooltip="%s"\n' "$conference_label" "$full_attribute" >> "$DROPDOWN_FILE"
    fi
    printf '%s\n' "--Current: ${NEXT_STAGE}" >> "$DROPDOWN_FILE"
    printf '%s\n' "--Next: ${NEXT_EVENT}" >> "$DROPDOWN_FILE"
    printf '%s\n' "--DDL: ${NEXT_DT} · ${remain}" >> "$DROPDOWN_FILE"
    printf '%s\n' "--Timeline" >> "$DROPDOWN_FILE"
    while IFS= read -r tl; do
      printf '%s\n' "----${tl}" >> "$DROPDOWN_FILE"
    done < "$TIMELINE_TMP"
    printf '%s\n' '---' >> "$DROPDOWN_FILE"
  else
    if bool_true "$SHOW_FINISHED"; then
      if [ -n "$url" ]; then
        printf '%s | href=%s tooltip="%s"\n' "$conference_label" "$url" "$full_attribute" >> "$DROPDOWN_FILE"
      else
        printf '%s | tooltip="%s"\n' "$conference_label" "$full_attribute" >> "$DROPDOWN_FILE"
      fi
      printf '%s\n' '--Status: finished' >> "$DROPDOWN_FILE"
      printf '%s\n' '--Timeline' >> "$DROPDOWN_FILE"
      while IFS= read -r tl; do
        printf '%s\n' "----${tl}" >> "$DROPDOWN_FILE"
      done < "$TIMELINE_TMP"
      printf '%s\n' '---' >> "$DROPDOWN_FILE"
    fi
  fi

  CONF_ACTIVE=false
}

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="$(trim_cr "$raw_line")"
  case "$line" in
    ''|'#'*) continue ;;
  esac

  IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7 extra <<EOF_FIELDS
$line
EOF_FIELDS

  case "$kind" in
    CONF)
      flush_conf
      reset_conf "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" "$f7" "$extra"
      ;;

    STAGE)
      [ "$CONF_ACTIVE" = true ] || continue
      bool_true "$CONF_VISIBLE" || continue
      stage="$f1"
      event="$f2"
      dt="$f3"
      stage_tz="$f4"
      event_epoch="$(parse_epoch "$dt" "$stage_tz")"
      if [ -z "$event_epoch" ]; then
        printf '%s\n' "⚠ Invalid date: $(sanitize_text "$event") · $(sanitize_text "$dt") $(display_tz "$stage_tz")" >> "$TIMELINE_TMP"
        continue
      fi
      event_display="$(format_datetime "$event_epoch" "$dt" "$stage_tz")"

      if [ "$event_epoch" -le "$NOW_EPOCH" ]; then
        printf '%s\n' "✓ $(sanitize_text "$event") · $(sanitize_text "$event_display")" >> "$TIMELINE_TMP"
      else
        if [ "$NEXT_FOUND" = false ]; then
          NEXT_FOUND=true
          NEXT_STAGE="$(sanitize_text "$stage")"
          NEXT_EVENT="$(sanitize_text "$event")"
          NEXT_DT="$(sanitize_text "$event_display")"
          NEXT_EPOCH="$event_epoch"
          printf '%s\n' "▶ $(sanitize_text "$event") · $(sanitize_text "$event_display")" >> "$TIMELINE_TMP"
        else
          printf '%s\n' "○ $(sanitize_text "$event") · $(sanitize_text "$event_display")" >> "$TIMELINE_TMP"
        fi
      fi
      ;;

    END)
      flush_conf
      ;;
  esac
done < "$RECORDS_FILE"
flush_conf

# xbar rotates all lines before the first --- separator.
if [ ! -s "$CAROUSEL_FILE" ]; then
  echo "CCF DDL · no visible important dates in ${IMPORTANT_DAYS}d"
else
  if bool_true "$SORT_BY_DEADLINE"; then
    sort -n -k1,1 -k2,2 "$CAROUSEL_FILE" > "$SORTED_FILE"
  else
    sort -n -k2,2 -k1,1 "$CAROUSEL_FILE" > "$SORTED_FILE"
  fi

  if [ "$CAROUSEL_LIMIT" -gt 0 ] 2>/dev/null; then
    head -n "$CAROUSEL_LIMIT" "$SORTED_FILE" | cut -f3-
  else
    cut -f3- "$SORTED_FILE"
  fi
fi

echo "---"
echo "CCF Conference Deadlines"
echo "--Config: $(sanitize_text "$CONFIG_FILE")"
echo "--Carousel window: ${IMPORTANT_DAYS} days"
if bool_true "$DISPLAY_LOCAL_TIME"; then
  echo "--Times: computer local timezone"
else
  echo "--Times: configured conference timezone"
fi
echo "--Refresh | refresh=true"
echo "---"

echo "Conference Visibility"
if [ -s "$VISIBILITY_FILE" ]; then
  cat "$VISIBILITY_FILE"
else
  echo "--No conferences configured"
fi
echo "---"

# Remove the trailing conference separator for a cleaner menu.
if [ -s "$DROPDOWN_FILE" ]; then
  # Portable way to print all but the final line on macOS/Linux.
  awk 'NR==1{prev=$0; next} {print prev; prev=$0}' "$DROPDOWN_FILE"
else
  echo "No active conferences"
fi
