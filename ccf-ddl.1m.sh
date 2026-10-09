#!/bin/bash
# <xbar.title>CCF Conference Deadlines</xbar.title>
# <xbar.version>3.9</xbar.version>
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
# The optional clock override makes date-boundary and dense-axis tests repeatable.
NOW_EPOCH="${CCF_DDL_NOW_EPOCH:-$(date +%s)}"
case "$NOW_EPOCH" in
  ''|*[!0-9]*) printf '%s\n' 'CCF_DDL_NOW_EPOCH must be a Unix timestamp' >&2; exit 2 ;;
esac

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
CACHE_DATES=true

# One fallback theme for older configs; individual entries can be overridden.
TIMELINE_DEFAULTS='{
  "min_width": 49, "max_width": 160, "label_width": 15,
  "font": "Menlo", "font_size": 11,
  "colors": {
    "Submit": "#124D61,#9ADDEC", "Review": "#394966,#CDD7EF",
    "Rebuttal": "#6F4500,#FFD789", "Notification": "#10583F,#96E6BB",
    "Revision": "#5B357D,#DCBDF4", "Camera Ready": "#3E5360,#C9DBE5",
    "Conference": "#1B4A8D,#AECFFF", "Axis": "#45515D,#E0E5EB",
    "Default": "#45515D,#E0E5EB"
  },
  "markers": {
    "Abstract": "○", "Full": "●", "Deadline": "△", "Review": "●",
    "Rebuttal": "◇", "Notification": "◆", "Revision": "□",
    "Camera Ready": "●", "Conference": "●", "Default": "●"
  },
  "symbols": {"line": "─", "tick": "┬", "overlap": "+"}
}'

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccf-ddl.XXXXXX")" || exit 1
TMP_BASE="${RUN_DIR}/run"
CAROUSEL_FILE="${TMP_BASE}.carousel"
DROPDOWN_FILE="${TMP_BASE}.dropdown"
SORTED_FILE="${TMP_BASE}.sorted"
RECORDS_FILE="${TMP_BASE}.records"
TIMELINE_TMP="${TMP_BASE}.timeline"
VISIBILITY_FILE="${TMP_BASE}.visibility"
OVERVIEW_FILE="${TMP_BASE}.overview"
STAGES_TMP="${TMP_BASE}.stages"
RAW_RECORDS_FILE="${TMP_BASE}.raw-records"
STYLE_FILE="${TMP_BASE}.style"
CONFIG_INPUT_FILE="${TMP_BASE}.config"
CACHE_TMP=''
: > "$CAROUSEL_FILE"
: > "$DROPDOWN_FILE"
: > "$TIMELINE_TMP"
: > "$VISIBILITY_FILE"
: > "$OVERVIEW_FILE"
cleanup() {
  rm -f "$CAROUSEL_FILE" "$DROPDOWN_FILE" "$SORTED_FILE" "$RECORDS_FILE" "$TIMELINE_TMP" "$VISIBILITY_FILE" "$OVERVIEW_FILE" "$STAGES_TMP" "$RAW_RECORDS_FILE" "$STYLE_FILE" "$CONFIG_INPUT_FILE"
  if [ -n "$CACHE_TMP" ]; then rm -f "$CACHE_TMP"; fi
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

sanitize_text() {
  # xbar uses | as the parameter delimiter.
  printf '%s' "${1//|//}"
}

swiftbar_escape_attribute() {
  # Attribute values are double-quoted in SwiftBar output.
  local escaped="$1"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s' "$escaped"
}

SCRIPT_ACTION_PATH="$(swiftbar_escape_attribute "$SCRIPT_PATH")"

normalize_tz() {
  case "$1" in
    AoE|AOE|aoe) printf '%s' 'Etc/GMT+12' ;;
    UTC|utc|GMT|gmt) printf '%s' 'UTC' ;;
    *) printf '%s' "$1" ;;
  esac
}

DATE_IS_GNU=false
if date --version >/dev/null 2>&1; then DATE_IS_GNU=true; fi

is_gnu_date() { [ "$DATE_IS_GNU" = true ]; }

timezone_file_path() {
  local tz="$1" zone_dir
  case "$tz" in
    ''|/*|*..*|*[!A-Za-z0-9_+/-]*) return 1 ;;
  esac
  if [ -n "${TZDIR:-}" ]; then
    [ -f "$TZDIR/$tz" ] || return 1
    printf '%s' "$TZDIR/$tz"
    return 0
  fi
  # Do not let an unknown TZ silently fall back to UTC. Only installed IANA
  # zone files (including aliases) and the normalized UTC/AoE names are used.
  for zone_dir in /usr/share/zoneinfo /var/db/timezone/zoneinfo /usr/share/lib/zoneinfo; do
    if [ -f "$zone_dir/$tz" ]; then printf '%s' "$zone_dir/$tz"; return 0; fi
  done
  return 1
}

valid_timezone() {
  [ "$1" = UTC ] || timezone_file_path "$1" >/dev/null
}

parse_epoch() {
  # Usage: parse_epoch "2027-04-10 23:59" "AoE"
  local dt="$1"
  local tz_raw="$2"
  local tz epoch canonical year
  tz="$(normalize_tz "$tz_raw")"
  valid_timezone "$tz" || return 2

  case "$dt" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  year="${dt%%-*}"
  [ "$year" != 0000 ] || return 1

  if is_gnu_date; then
    epoch="$(TZ="$tz" date -d "${dt}:00" +%s 2>/dev/null)" || return 1
    canonical="$(TZ="$tz" date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || return 1
  else
    # Explicit seconds avoid BSD date inheriting the current system seconds.
    epoch="$(TZ="$tz" date -j -f '%Y-%m-%d %H:%M:%S' "${dt}:00" '+%s' 2>/dev/null)" || return 1
    canonical="$(TZ="$tz" date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || return 1
  fi
  # BSD date rolls Feb 30 into March and normalizes nonexistent DST times.
  # A round trip must match every field, rather than accepting that rollover.
  [ "$canonical" = "${dt}:00" ] || return 1
  printf '%s\n' "$epoch"
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

format_local_datetime() {
  if is_gnu_date; then
    date -d "@$1" "+$2"
  else
    date -r "$1" "+$2"
  fi
}

one_month_later() {
  local year month day clock next_month month_days
  if is_gnu_date; then
    IFS=' ' read -r year month day clock <<EOF_LOCAL_DATE
$(format_local_datetime "$1" '%Y %m %d %H:%M:%S')
EOF_LOCAL_DATE
    next_month="$(date -d "${year}-${month}-01 +1 month" '+%Y-%m')"
    month_days="$(date -d "${next_month}-01 +1 month -1 day" '+%d')"
    if [ "$day" -gt "$month_days" ]; then day="$month_days"; fi
    date -d "${next_month}-${day} ${clock}" '+%s'
  else
    date -r "$1" -v+1m '+%s'
  fi
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
# A single snapshot prevents a preference click/config edit from mixing two
# versions of the configuration while a refresh is building its cache.
cp "$CONFIG_FILE" "$CONFIG_INPUT_FILE" || emit_error "Unable to read configuration" "$CONFIG_FILE"

validate_config() {
  jq -e --argjson defaults "$TIMELINE_DEFAULTS" '
    def nonempty_string: type == "string" and length > 0;
    def integer_between($min; $max): type == "number" and floor == . and . >= $min and . <= $max;
    def color_pair: type == "string" and test("^#[0-9A-Fa-f]{6}(,#[0-9A-Fa-f]{6})?$");
    # Restrict markers to single-cell ASCII/box-drawing/geometric glyphs.
    # Emoji, whitespace and the SwiftBar parameter delimiter break alignment.
    def glyph: type == "string" and length == 1 and (. as $symbol |
      (explode[0] as $code | ($code >= 33 and $code <= 126 and $code != 92 and $code != 124) or
                             ($code >= 9472 and $code <= 9599)) or
      ("○●△▲▽▼◇◆□■◊◦◎◉◌" | contains($symbol)));
    def valid_timeline:
      type == "object" and
      ($defaults * . | . as $theme |
        (.min_width | integer_between(16; 500)) and
        (.max_width | integer_between(16; 500)) and .max_width >= .min_width and
        (.label_width | integer_between(8; 64)) and
        (.font | nonempty_string and length <= 80 and
          all(explode[]; . >= 32 and . != 34 and . != 92 and . != 124 and . != 127)) and
        (.font_size | integer_between(6; 48)) and
        (.colors | type == "object" and all(.[]; color_pair)) and
        (.markers | type == "object" and all(.[]; glyph)) and
        (.symbols | type == "object" and all(.[]; glyph))
      );
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
    (((.settings | has("cache_dates")) == false) or (.settings.cache_dates | type == "boolean")) and
    (((.settings | has("timeline")) == false) or (.settings.timeline | valid_timeline)) and
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
        (((. | has("timezone")) == false) or (.timezone | nonempty_string)) and
        (((. | has("kind")) == false) or
          (.kind == "start" or .kind == "end" or .kind == "deadline" or
           .kind == "notification" or .kind == "milestone")) and
        (((. | has("phase_after")) == false) or (.phase_after | nonempty_string))
      )
    )
  ' "$CONFIG_INPUT_FILE" >/dev/null 2>&1
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
  .settings.sort_by_deadline,
  (.settings | if has("cache_dates") then .cache_dates else true end)
] | @tsv' "$CONFIG_INPUT_FILE")"

IFS=$'\t' read -r WARNING_DAYS URGENT_DAYS IMPORTANT_DAYS DISPLAY_LOCAL_TIME SHOW_PHASE_IN_CAROUSEL SHOW_CCF_LEVEL SHOW_FINISHED CAROUSEL_LIMIT SORT_BY_DEADLINE CACHE_DATES <<EOF_SETTINGS
$SETTINGS_LINE
EOF_SETTINGS

THEME_LINE="$(jq -r --argjson defaults "$TIMELINE_DEFAULTS" '
  ($defaults * (.settings.timeline // {})) |
  [.min_width, .max_width, .label_width, .font, .font_size] | @tsv
' "$CONFIG_INPUT_FILE")"
IFS=$'\t' read -r TIMELINE_MIN_WIDTH TIMELINE_MAX_WIDTH TIMELINE_LABEL_WIDTH TIMELINE_FONT TIMELINE_FONT_SIZE <<EOF_THEME
$THEME_LINE
EOF_THEME
case "$TIMELINE_FONT" in
  *[!A-Za-z0-9_-]*) TIMELINE_FONT_ATTRIBUTE="font=\"$(swiftbar_escape_attribute "$TIMELINE_FONT")\"" ;;
  *) TIMELINE_FONT_ATTRIBUTE="font=$TIMELINE_FONT" ;;
esac
TIMELINE_ATTRIBUTES="$TIMELINE_FONT_ATTRIBUTE size=$TIMELINE_FONT_SIZE"
jq -r --argjson defaults "$TIMELINE_DEFAULTS" '
  ($defaults * (.settings.timeline // {})) |
  (.colors | to_entries[] | ["COLOR", .key, .value] | @tsv),
  (.markers | to_entries[] | ["MARKER", .key, .value] | @tsv),
  (.symbols | to_entries[] | ["SYMBOL", .key, .value] | @tsv)
' "$CONFIG_INPUT_FILE" > "$STYLE_FILE"

# Convert the JSON hierarchy to a small record stream once. The remaining
# state machine stays compatible with the Bash 3.2 bundled with macOS.
generate_raw_records() {
jq -r '
  # One shared mapping drives both the workflow state and chart markers.
  def marker_phase:
    (.event | ascii_downcase) as $name |
    if .phase == "Submit" then
      if $name | test("abstract") then "Abstract"
      elif $name | test("paper") then "Full"
      else "Deadline" end
    elif $name | test("rebuttal|response|discussion|feedback|interactive") then "Rebuttal"
    elif $name | test("notification|decision|results|early reject") then "Notification"
    elif $name | test("revision") then "Revision"
    elif .phase == "Response" or .phase == "Rebuttal" or
         .phase == "Discussion" or .phase == "Feedback" then "Rebuttal"
    elif .phase == "Decision" then "Notification"
    elif .phase == "Camera" then "Camera Ready"
    elif .phase == "Waiting" then "Conference"
    else .phase end;
  def event_kind($marker):
    if has("kind") then .kind else
      (.event | ascii_downcase) as $name |
      if $name | test("(^|[^a-z])(starts?|begins?|opens?)([^a-z]|$)") then "start"
      elif $name | test("(^|[^a-z])(ends?|closes?)([^a-z]|$)") then "end"
      elif $marker == "Notification" then "notification"
      elif $marker == "Conference" then "start"
      elif ($name | test("due|deadline")) or
           $marker == "Abstract" or $marker == "Full" or $marker == "Deadline" or
           $marker == "Revision" or $marker == "Camera Ready" then "deadline"
      else "milestone" end
    end;
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
  ($conference.stages[] |
    marker_phase as $marker |
    [
      "STAGE",
      .phase,
      .event,
      .datetime,
      (.timezone // $conference.timezone),
      $marker,
      (if .phase == "Submit" then "Submit" else $marker end),
      event_kind($marker),
      (.phase_after // "")
    ] | @tsv),
  (["END"] | @tsv)
' "$CONFIG_INPUT_FILE" > "$RAW_RECORDS_FILE"
}

build_cached_records() {
  local raw_line line record raw_phase event dt tz marker phase event_kind after epoch
  local f1 f2 f3 f4 f5 f6 f7 f8 sequence=0 parse_status source_display local_display local_date display_zone
  generate_raw_records || return 1
  : > "$RECORDS_FILE"
  : > "$STAGES_TMP"
  while IFS= read -r raw_line; do
    line="${raw_line//$'\t'/$'\037'}"
    IFS=$'\037' read -r record f1 f2 f3 f4 f5 f6 f7 f8 <<EOF_CACHE_FIELDS
$line
EOF_CACHE_FIELDS
    case "$record" in
      CONF)
        printf '%s\n' "$raw_line" >> "$RECORDS_FILE"
        sequence=0
        : > "$STAGES_TMP"
        ;;
      STAGE)
        raw_phase="${f1//|//}"; event="${f2//|//}"; dt="$f3"; tz="$f4"
        marker="${f5//|//}"; phase="${f6//|//}"; event_kind="$f7"; after="${f8//|//}"
        if epoch="$(parse_epoch "$dt" "$tz")"; then
          case "$tz" in AoE|AOE|aoe) display_zone='AoE' ;; *) display_zone="$tz" ;; esac
          source_display="$dt $display_zone"
          local_display="$(format_local_datetime "$epoch" '%Y-%m-%d %H:%M %Z')" || return 1
          local_date="${local_display:0:10}"
          local_display="$local_display (local)"
          sequence=$((sequence + 1))
          printf 'STAGE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$sequence" "$raw_phase" "$event" "$source_display" "$local_display" "$local_date" "$marker" "$phase" "$event_kind" "$after" >> "$STAGES_TMP"
        else
          parse_status=$?
          printf 'ERROR\t%s\t%s\t%s\t%s\n' "$parse_status" "$event" "$dt" "$tz" >> "$RECORDS_FILE"
        fi
        ;;
      END)
        # Error records precede sorted stages, so an invalid conference never
        # acquires a next event before its error is discovered on a cache hit.
        LC_ALL=C sort -t $'\t' -n -k2,2 -k3,3 "$STAGES_TMP" >> "$RECORDS_FILE" || return 1
        printf '%s\n' 'END' >> "$RECORDS_FILE"
        ;;
    esac
  done < "$RAW_RECORDS_FILE"
}

timezone_fingerprint() {
  local tz path zone_files=()
  printf 'TZ=%s\nTZDIR=%s\n' "${TZ-<system>}" "${TZDIR-<system>}"
  if [ -r /etc/localtime ]; then zone_files[${#zone_files[@]}]='/etc/localtime'; fi
  # A single checksum process covers all relevant source/local zone files.
  # File contents, not today's UTC offset, invalidate cached DST conversions.
  while IFS= read -r tz; do
    case "$tz" in AoE|AOE|aoe) tz='Etc/GMT+12' ;; UTC|utc|GMT|gmt) tz='UTC' ;; esac
    if path="$(timezone_file_path "$tz")"; then
      case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
      zone_files[${#zone_files[@]}]="$path"
    else
      printf 'Missing zone: %s\n' "$tz"
    fi
  done < <(jq -r '[.conferences[] | .timezone, (.stages[] | .timezone // empty)] +
                  [(env.TZ // "" | ltrimstr(":"))] | unique[]' "$CONFIG_INPUT_FILE")
  if [ "${#zone_files[@]}" -gt 0 ]; then cksum "${zone_files[@]}"; fi
}

cache_debug() {
  if [ "${CCF_DDL_CACHE_DEBUG:-0}" = 1 ]; then printf 'Date cache: %s\n' "$1" >&2; fi
}

load_cached_records() {
  local cache_identity cache_id cache_key config_sum script_sum zone_sum body_sum
  local tag version saved_key saved_sum
  local cache_format=1
  if ! bool_true "$CACHE_DATES"; then
    build_cached_records || emit_error "Unable to parse conference dates" "$CONFIG_FILE"
    cache_debug disabled
    return
  fi

  case "$CONFIG_FILE" in /*) cache_identity="$CONFIG_FILE" ;; *) cache_identity="$PWD/$CONFIG_FILE" ;; esac
  cache_id="$(printf '%s' "$cache_identity" | cksum)"
  cache_id="${cache_id// /-}"
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    CACHE_DIR="$XDG_CACHE_HOME/ccf-ddl"
  else
    case "$OSTYPE" in darwin*) CACHE_DIR="$HOME/Library/Caches/ccf-ddl" ;; *) CACHE_DIR="$HOME/.cache/ccf-ddl" ;; esac
  fi
  CACHE_DIR="${CCF_DDL_CACHE_DIR:-$CACHE_DIR}"
  CACHE_FILE="$CACHE_DIR/parsed-${cache_id}.cache"
  config_sum="$(cksum < "$CONFIG_INPUT_FILE")"
  script_sum="$(cksum < "$SCRIPT_DIR/$(basename "$0")")"
  zone_sum="$(timezone_fingerprint | cksum)"
  cache_key="$(printf '%s\n' "$cache_format" "$cache_identity" "$config_sum" "$script_sum" "$DATE_IS_GNU" "$zone_sum" | cksum)"

  if [ -f "$CACHE_FILE" ] && [ ! -L "$CACHE_FILE" ]; then
    IFS=$'\t' read -r tag version saved_key saved_sum < "$CACHE_FILE"
    if [ "$tag" = CCF_DDL_CACHE ] && [ "$version" = "$cache_format" ] && [ "$saved_key" = "$cache_key" ]; then
      tail -n +2 "$CACHE_FILE" > "$RECORDS_FILE"
      body_sum="$(cksum < "$RECORDS_FILE")"
      if [ "$body_sum" = "$saved_sum" ]; then
        cache_debug hit
        return
      fi
    fi
  fi

  build_cached_records || emit_error "Unable to parse conference dates" "$CONFIG_FILE"
  if (umask 077; mkdir -p "$CACHE_DIR") 2>/dev/null; then
    CACHE_TMP="$(mktemp "$CACHE_DIR/.parsed-${cache_id}.XXXXXX" 2>/dev/null)" || CACHE_TMP=''
  fi
  if [ -n "$CACHE_TMP" ]; then
    body_sum="$(cksum < "$RECORDS_FILE")"
    if { printf 'CCF_DDL_CACHE\t%s\t%s\t%s\n' "$cache_format" "$cache_key" "$body_sum"; cat "$RECORDS_FILE"; } > "$CACHE_TMP" &&
       chmod 600 "$CACHE_TMP" && mv -f "$CACHE_TMP" "$CACHE_FILE"; then
      CACHE_TMP=''
      cache_debug rebuilt
      return
    fi
  fi
  # A read-only/unavailable cache never prevents the normal uncached plugin.
  cache_debug unavailable
}

load_cached_records

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
NEXT_EVENT=''
NEXT_DT=''
NEXT_EPOCH=''
CURRENT_STAGE=''
CONF_INVALID=false
PREVIOUS_EPOCH=''
PREVIOUS_PHASE=''
PREVIOUS_KIND=''
PREVIOUS_AFTER=''
FIRST_STAGE=true
VISIBLE_COUNT=0
CHART_END_EPOCH="$(one_month_later "$NOW_EPOCH")"
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
  NEXT_EVENT=''
  NEXT_DT=''
  NEXT_EPOCH=''
  CURRENT_STAGE=''
  CONF_INVALID=false
  PREVIOUS_EPOCH=''
  PREVIOUS_PHASE=''
  PREVIOUS_KIND=''
  PREVIOUS_AFTER=''
  FIRST_STAGE=true
  : > "$TIMELINE_TMP"
}

phase_before_first_event() {
  local phase="$1" kind="$2"
  case "$phase" in
    Rebuttal|Notification) CURRENT_STAGE='Review' ;;
    Conference) CURRENT_STAGE='Waiting' ;;
    *)
      if [ "$kind" = start ]; then CURRENT_STAGE="Waiting for $phase"
      else CURRENT_STAGE="$phase"; fi
      ;;
  esac
}

phase_after_event() {
  local phase="$1" kind="$2" override="$3" current="$4" following_phase="$5" following_kind="$6"
  if [ -n "$override" ]; then CURRENT_STAGE="$override"; return; fi
  if [ "$kind" = start ]; then CURRENT_STAGE="$phase"; return; fi

  if [ "$kind" = notification ]; then
    # A notification is a point in time, not a phase that lasts until the
    # next milestone. Early/round notifications keep the conference in Review.
    case "$following_phase" in
      Revision|"Camera Ready"|Submit)
        if [ "$following_kind" = start ]; then CURRENT_STAGE="Waiting for $following_phase"
        else CURRENT_STAGE="$following_phase"; fi
        ;;
      Conference) CURRENT_STAGE='Waiting' ;;
      '') CURRENT_STAGE='Finished' ;;
      *) CURRENT_STAGE='Review' ;;
    esac
    return
  fi

  if [ "$kind" = end ] || [ "$kind" = deadline ]; then
    case "$phase" in
      Submit|Rebuttal|Revision)
        if [ "$following_phase" = "$phase" ] && [ "$following_kind" != start ]; then
          CURRENT_STAGE="$current"
        else
          case "$following_phase" in
            Revision|"Camera Ready") phase_before_first_event "$following_phase" "$following_kind" ;;
            *) CURRENT_STAGE='Review' ;;
          esac
        fi
        ;;
      "Camera Ready")
        case "$following_phase" in
          "Camera Ready") CURRENT_STAGE='Camera Ready' ;;
          Review|Rebuttal|Notification|Revision) CURRENT_STAGE='Review' ;;
          *) CURRENT_STAGE='Waiting' ;;
        esac
        ;;
      Conference) CURRENT_STAGE='Waiting' ;;
      *) CURRENT_STAGE="$current" ;;
    esac
    return
  fi
  CURRENT_STAGE="$phase"
}

process_cached_stage() {
  local epoch="$1" raw_phase="$2" event="$3" source_display="$4" local_display="$5"
  local local_date="$6" marker="$7" phase="$8" kind="$9" after="${10}" event_display symbol='○'
  if [ "$FIRST_STAGE" = true ]; then
    phase_before_first_event "$phase" "$kind"
    FIRST_STAGE=false
  fi
  if [ -n "$PREVIOUS_EPOCH" ] && [ "$PREVIOUS_EPOCH" -le "$NOW_EPOCH" ]; then
    phase_after_event "$PREVIOUS_PHASE" "$PREVIOUS_KIND" "$PREVIOUS_AFTER" "$CURRENT_STAGE" "$phase" "$kind"
  fi
  if bool_true "$DISPLAY_LOCAL_TIME"; then event_display="$local_display"; else event_display="$source_display"; fi
  if [ "$epoch" -le "$NOW_EPOCH" ]; then
    symbol='✓'
  elif [ "$NEXT_FOUND" = false ] && [ "$CONF_INVALID" = false ]; then
    NEXT_FOUND=true
    NEXT_EVENT="$event"
    NEXT_DT="$event_display"
    NEXT_EPOCH="$epoch"
    symbol='▶'
  fi
  printf '%s\n' "$symbol $event · $event_display" >> "$TIMELINE_TMP"
  if [ "$CONF_INVALID" = false ] && [ "$epoch" -gt "$NOW_EPOCH" ] && [ "$epoch" -le "$CHART_END_EPOCH" ]; then
    printf 'EVENT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CONF_INDEX" "$epoch" "$raw_phase" "$event" "$local_date" "$marker" "$phase" >> "$OVERVIEW_FILE"
  fi
  PREVIOUS_EPOCH="$epoch"
  PREVIOUS_PHASE="$phase"
  PREVIOUS_KIND="$kind"
  PREVIOUS_AFTER="$after"
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

  VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
  if [ "$CONF_INVALID" = true ]; then CURRENT_STAGE='Unavailable (invalid timeline)'
  elif [ "$NEXT_FOUND" = false ]; then CURRENT_STAGE='Finished'; fi
  printf 'CONF\t%s\t%s\n' "$CONF_INDEX" "$conference_label" >> "$OVERVIEW_FILE"

  # A malformed timeline must not silently choose another event or disappear
  # as "finished". Keep its diagnostic details visible until it is repaired.
  if [ "$CONF_INVALID" = true ]; then
    printf '%s\n' "$conference_label" >> "$DROPDOWN_FILE"
    printf '%s\n' "--Current: ${CURRENT_STAGE}" >> "$DROPDOWN_FILE"
    printf '%s\n' '--Next event: unavailable; fix invalid dates or time zones' >> "$DROPDOWN_FILE"
    printf '%s\n' '--Timeline' >> "$DROPDOWN_FILE"
    while IFS= read -r tl; do printf '%s\n' "----${tl}" >> "$DROPDOWN_FILE"; done < "$TIMELINE_TMP"
    printf '%s\n' '---' >> "$DROPDOWN_FILE"
    CONF_ACTIVE=false
    return 0
  fi

  if [ "$NEXT_FOUND" = true ]; then
    local delta remain color top_line epoch_key important_secs
    delta=$((NEXT_EPOCH - NOW_EPOCH))
    remain="$(remaining_text "$delta")"
    color="$(status_color "$delta")"
    if bool_true "$SHOW_PHASE_IN_CAROUSEL"; then
      top_line="${conference_label} · $(sanitize_text "$CURRENT_STAGE")→${NEXT_EVENT} · ${remain}"
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
      printf '%s | href=%s\n' "$conference_label" "$url" >> "$DROPDOWN_FILE"
    else
      printf '%s\n' "$conference_label" >> "$DROPDOWN_FILE"
    fi
    printf '%s\n' "--Current: $(sanitize_text "$CURRENT_STAGE")" >> "$DROPDOWN_FILE"
    printf '%s\n' "--Next event: ${NEXT_EVENT}" >> "$DROPDOWN_FILE"
    printf '%s\n' "--When: ${NEXT_DT} · ${remain}" >> "$DROPDOWN_FILE"
    printf '%s\n' "--Timeline" >> "$DROPDOWN_FILE"
    while IFS= read -r tl; do
      printf '%s\n' "----${tl}" >> "$DROPDOWN_FILE"
    done < "$TIMELINE_TMP"
    printf '%s\n' '---' >> "$DROPDOWN_FILE"
  else
    if bool_true "$SHOW_FINISHED"; then
      if [ -n "$url" ]; then
        printf '%s | href=%s\n' "$conference_label" "$url" >> "$DROPDOWN_FILE"
      else
        printf '%s\n' "$conference_label" >> "$DROPDOWN_FILE"
      fi
      printf '%s\n' '--Status: finished' >> "$DROPDOWN_FILE"
      printf '%s\n' '--Current: Finished' >> "$DROPDOWN_FILE"
      printf '%s\n' '--Next event: none' >> "$DROPDOWN_FILE"
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
  line="${raw_line//$'\r'/}"
  case "$line" in
    ''|'#'*) continue ;;
  esac

  # A non-whitespace delimiter preserves empty TSV fields (including url and
  # optional phase_after), unlike Bash's whitespace-collapsing tab IFS.
  line="${line//$'\t'/$'\037'}"
  IFS=$'\037' read -r kind f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 <<EOF_FIELDS
$line
EOF_FIELDS

  case "$kind" in
    CONF)
      flush_conf
      reset_conf "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" "$f7" "$f8"
      ;;

    STAGE)
      [ "$CONF_ACTIVE" = true ] || continue
      bool_true "$CONF_VISIBLE" || continue
      process_cached_stage "$f1" "$f3" "$f4" "$f5" "$f6" "$f7" "$f8" "$f9" "$f10" "$f11"
      ;;

    ERROR)
      [ "$CONF_ACTIVE" = true ] || continue
      bool_true "$CONF_VISIBLE" || continue
      CONF_INVALID=true
      error_label='Invalid date/time'
      if [ "$f1" -eq 2 ]; then error_label='Invalid timezone'; fi
      printf '%s\n' "⚠ ${error_label}: ${f2} · ${f3//|//} ${f4//|//}" >> "$TIMELINE_TMP"
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

echo "Timeline Overview · next month"
if [ "$VISIBLE_COUNT" -eq 0 ]; then
  echo "--No selected conferences"
else
  chart_end="$CHART_END_EPOCH"
  event_count="$(awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" '$1 == "EVENT" && $3 > now && $3 <= end {count++} END {print count+0}' "$OVERVIEW_FILE")"
  active_count="$(awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" '$1 == "EVENT" && $3 > now && $3 <= end {active[$2]=1} END {for (id in active) count++; print count+0}' "$OVERVIEW_FILE")"
  event_word='milestones'
  if [ "$event_count" -eq 1 ]; then event_word='milestone'; fi
  echo "--${active_count} active of ${VISIBLE_COUNT} selected · ${event_count} ${event_word} · local time | $TIMELINE_ATTRIBUTES"
  echo "--Window: $(format_local_datetime "$NOW_EPOCH" '%Y-%m-%d %H:%M %Z') → $(format_local_datetime "$chart_end" '%Y-%m-%d %H:%M %Z') | $TIMELINE_ATTRIBUTES"
  if [ "$event_count" -eq 0 ]; then
    echo "--No milestones in the next month for selected conferences | $TIMELINE_ATTRIBUTES"
  else
    awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" \
        -v minimum_width="$TIMELINE_MIN_WIDTH" -v maximum_width="$TIMELINE_MAX_WIDTH" \
        -v label_width="$TIMELINE_LABEL_WIDTH" -v attributes="$TIMELINE_ATTRIBUTES" -v style_file="$STYLE_FILE" '
    BEGIN {
      while ((getline style_line < style_file) > 0) {
        split(style_line, fields, "\t")
        if (fields[1] == "COLOR") colors[fields[2]] = fields[3]
        if (fields[1] == "MARKER") markers[fields[2]] = fields[3]
        if (fields[1] == "SYMBOL") symbols[fields[2]] = fields[3]
      }
      close(style_file)
    }
    function phase_color(phase) {
      # SwiftBar selects the first color in Light and the second in Dark.
      # All Submit milestones share one track/color; their shapes differ.
      if (phase == "Submit" || phase == "Abstract" || phase == "Full" || phase == "Deadline") return colors["Submit"]
      return phase in colors ? colors[phase] : colors["Default"]
    }
    function marker_shape(phase) {
      return phase in markers ? markers[phase] : markers["Default"]
    }
    function known_phase(phase) {
      return phase == "Submit" || phase == "Abstract" || phase == "Full" || phase == "Deadline" ||
             phase == "Review" || phase == "Rebuttal" ||
             phase == "Notification" || phase == "Revision" ||
             phase == "Camera Ready" || phase == "Conference"
    }
    function print_legend(phase) {
      printf "--%s %s | %s color=%s\n", marker_shape(phase), phase, attributes, phase_color(phase)
    }
    function short_date(local_date, day) {
      day = substr(local_date, 9, 2) + 0
      if (ambiguous_day[day]) return sprintf("%d/%d", substr(local_date, 6, 2) + 0, day)
      return sprintf("%d", day)
    }
    function plot_position(epoch, last_position, position) {
      position = int((epoch - now) * last_position / (end - now) + 0.5)
      if (position < 0) position = 0
      if (position > last_position) position = last_position
      return position
    }
    # Find the narrowest proportional axis whose centered date labels all fit
    # on one row. A capped width avoids an unusably wide SwiftBar menu.
    function axis_fits(candidate, key, i, position, local_date, date_key, n, label_text, label_length, start, previous_end) {
      for (key in trial_seen) delete trial_seen[key]
      for (key in trial_count) delete trial_count[key]
      for (key in trial_at) delete trial_at[key]
      for (i = 1; i <= event_total; i++) {
        position = plot_position(event_epoch[i], candidate - 1)
        local_date = event_date[i]
        date_key = position SUBSEP local_date
        if (!(date_key in trial_seen)) {
          trial_seen[date_key] = 1
          trial_count[position]++
          trial_at[position SUBSEP trial_count[position]] = local_date
        }
      }
      previous_end = -2
      for (position = 0; position < candidate; position++) {
        for (n = 1; n <= trial_count[position]; n++) {
          label_text = short_date(trial_at[position SUBSEP n])
          label_length = length(label_text)
          start = position - int(label_length / 2)
          if (start < 0) start = 0
          if (start + label_length > candidate) start = candidate - label_length
          if (start <= previous_end + 1) return 0
          previous_end = start + label_length - 1
        }
      }
      return 1
    }
    $1 == "CONF" {
      labels[$2] = $3
      order[++selected] = $2
    }
    $1 == "EVENT" {
      epoch = $3 + 0
      if (epoch > now && epoch <= end) {
        phase = $7
        track_phase = $8
        if (!known_phase(phase) && !(phase in extra_seen)) {
          extra_seen[phase] = 1
          extra_phase[++extra_count] = phase
        }
        event_total++
        event_epoch[event_total] = epoch
        event_id[event_total] = $2
        event_phase[event_total] = phase
        event_track_phase[event_total] = track_phase
        event_date[event_total] = $6
        group = $2 SUBSEP track_phase
        if (!(group in seen_group)) {
          seen_group[group] = 1
          row_count[$2]++
          row_phase[$2 SUBSEP row_count[$2]] = track_phase
        }
        milestones[$2]++
      }
    }
    END {
      for (i = 1; i <= event_total; i++) {
        local_date = event_date[i]
        day = substr(local_date, 9, 2) + 0
        year_month = substr(local_date, 1, 7)
        if ((day in first_month) && first_month[day] != year_month) ambiguous_day[day] = 1
        else first_month[day] = year_month
      }
      for (width = minimum_width; width <= maximum_width; width++) {
        if (axis_fits(width)) break
      }
      if (width > maximum_width) {
        width = maximum_width
        axis_fits(width)
      }
      last = width - 1
      # Use one axis width for ticks, date labels, and all phase tracks.
      for (i = 1; i <= event_total; i++) {
        position = plot_position(event_epoch[i], last)
        tick[position] = 1
        group = event_id[i] SUBSEP event_track_phase[i]
        key = group SUBSEP position
        if (key in marker) marker[key] = symbols["overlap"]
        else marker[key] = marker_shape(event_phase[i])
      }
      # The daily case fits on one row after widening. Only extraordinarily
      # clustered dates beyond the width cap need an additional date row.
      for (position = 0; position <= last; position++) {
        for (n = 1; n <= trial_count[position]; n++) {
          label_text = short_date(trial_at[position SUBSEP n])
          label_length = length(label_text)
          start = position - int(label_length / 2)
          if (start < 0) start = 0
          if (start + label_length > width) start = width - label_length
          for (row = 1; row <= label_rows; row++) {
            if (start > last_end[row] + 1) break
          }
          if (row > label_rows) label_rows = row
          for (offset = 0; offset < label_length; offset++) {
            label_cell[row SUBSEP (start + offset)] = substr(label_text, offset + 1, 1)
          }
          last_end[row] = start + label_length - 1
        }
      }
      # Visible left labels matter: SwiftBar trims leading spaces in titles.
      for (row = 1; row <= label_rows; row++) {
        date_line = ""
        for (column = 0; column <= last; column++) {
          key = row SUBSEP column
          date_line = date_line ((key in label_cell) ? label_cell[key] : " ")
        }
        row_label = (row == 1 ? "Date" : "Date " row)
        printf "--%-*s%s | %s\n", label_width, row_label, date_line, attributes
      }
      axis = ""
      for (column = 0; column <= last; column++) {
        axis = axis ((column == 0 || column == last || tick[column]) ? symbols["tick"] : symbols["line"])
      }
      printf "--%-*s%s | %s color=%s\n", label_width, "Axis", axis, attributes, colors["Axis"]

      for (i = 1; i <= selected; i++) {
        id = order[i]
        label = substr(labels[id], 1, label_width - 1)
        if (!milestones[id]) continue
        for (row = 1; row <= row_count[id]; row++) {
          phase = row_phase[id SUBSEP row]
          group = id SUBSEP phase
          track = ""
          for (column = 0; column <= last; column++) {
            key = group SUBSEP column
            track = track ((key in marker) ? marker[key] : symbols["line"])
          }
          printf "--%-*s%s  %s | %s color=%s\n", label_width, label, track, phase, attributes, phase_color(phase)
        }
      }
      print "--Legend | " attributes
      print_legend("Abstract")
      print_legend("Full")
      print_legend("Deadline")
      print_legend("Review")
      print_legend("Rebuttal")
      print_legend("Notification")
      print_legend("Revision")
      print_legend("Camera Ready")
      print_legend("Conference")
      for (i = 1; i <= extra_count; i++) print_legend(extra_phase[i])
      print "--" symbols["overlap"] " Overlapping milestones at the same chart position | " attributes " color=" colors["Axis"]
      print "--Exact dates and times are in each conference menu | " attributes " color=" colors["Axis"]
    }
    ' "$OVERVIEW_FILE"
  fi
fi
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
