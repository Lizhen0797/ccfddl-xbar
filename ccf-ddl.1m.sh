#!/bin/bash
# <xbar.title>CCF Conference Deadlines</xbar.title>
# <xbar.version>3.7</xbar.version>
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

TMP_BASE="${TMPDIR:-/tmp}/ccf-ddl.$$"
CAROUSEL_FILE="${TMP_BASE}.carousel"
DROPDOWN_FILE="${TMP_BASE}.dropdown"
SORTED_FILE="${TMP_BASE}.sorted"
RECORDS_FILE="${TMP_BASE}.records"
TIMELINE_TMP="${TMP_BASE}.timeline"
VISIBILITY_FILE="${TMP_BASE}.visibility"
OVERVIEW_FILE="${TMP_BASE}.overview"
: > "$CAROUSEL_FILE"
: > "$DROPDOWN_FILE"
: > "$TIMELINE_TMP"
: > "$VISIBILITY_FILE"
: > "$OVERVIEW_FILE"
trap 'rm -f "$CAROUSEL_FILE" "$DROPDOWN_FILE" "$SORTED_FILE" "$RECORDS_FILE" "$TIMELINE_TMP" "$VISIBILITY_FILE" "$OVERVIEW_FILE"' EXIT HUP INT TERM

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

  VISIBLE_COUNT=$((VISIBLE_COUNT + 1))
  printf 'CONF\t%s\t%s\n' "$CONF_INDEX" "$conference_label" >> "$OVERVIEW_FILE"

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
      printf '%s | href=%s\n' "$conference_label" "$url" >> "$DROPDOWN_FILE"
    else
      printf '%s\n' "$conference_label" >> "$DROPDOWN_FILE"
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
        printf '%s | href=%s\n' "$conference_label" "$url" >> "$DROPDOWN_FILE"
      else
        printf '%s\n' "$conference_label" >> "$DROPDOWN_FILE"
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
      # Store the computer-local calendar date for axis labels. macOS awk does
      # not provide strftime, and the detail menu can use the source timezone.
      local_date=''
      if [ "$event_epoch" -gt "$NOW_EPOCH" ] && [ "$event_epoch" -le "$CHART_END_EPOCH" ]; then
        local_date="$(format_local_datetime "$event_epoch" '%Y-%m-%d')"
      fi
      printf 'EVENT\t%s\t%s\t%s\t%s\t%s\n' "$CONF_INDEX" "$event_epoch" "$stage" "$event" "$local_date" >> "$OVERVIEW_FILE"

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

echo "Timeline Overview · next month"
if [ "$VISIBLE_COUNT" -eq 0 ]; then
  echo "--No selected conferences"
else
  chart_end="$CHART_END_EPOCH"
  event_count="$(awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" '$1 == "EVENT" && $3 > now && $3 <= end {count++} END {print count+0}' "$OVERVIEW_FILE")"
  active_count="$(awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" '$1 == "EVENT" && $3 > now && $3 <= end {active[$2]=1} END {for (id in active) count++; print count+0}' "$OVERVIEW_FILE")"
  event_word='milestones'
  if [ "$event_count" -eq 1 ]; then event_word='milestone'; fi
  echo "--${active_count} active of ${VISIBLE_COUNT} selected · ${event_count} ${event_word} · local time | font=Menlo size=11"
  echo "--Window: $(format_local_datetime "$NOW_EPOCH" '%Y-%m-%d %H:%M %Z') → $(format_local_datetime "$chart_end" '%Y-%m-%d %H:%M %Z') | font=Menlo size=11"
  if [ "$event_count" -eq 0 ]; then
    echo '--No milestones in the next month for selected conferences | font=Menlo size=11'
  else
    awk -F '\t' -v now="$NOW_EPOCH" -v end="$chart_end" '
    BEGIN { minimum_width = 49; maximum_width = 160 }
    # Normalize presentation labels only; the JSON and conference detail menus
    # retain their original phase and event names.
    function display_phase(raw, event, name) {
      name = tolower(event)
      if (raw == "Submit") {
        if (name ~ /abstract/) return "Abstract"
        if (name ~ /paper/) return "Full"
        return "Deadline"
      }
      if (name ~ /(rebuttal|response|discussion|feedback|interactive)/) return "Rebuttal"
      if (name ~ /(notification|decision|results|early reject)/) return "Notification"
      if (name ~ /revision/) return "Revision"
      if (raw == "Response" || raw == "Rebuttal" || raw == "Discussion" || raw == "Feedback") return "Rebuttal"
      if (raw == "Decision") return "Notification"
      if (raw == "Camera") return "Camera Ready"
      if (raw == "Waiting") return "Conference"
      return raw
    }
    function phase_color(phase) {
      # SwiftBar selects the first color in Light and the second in Dark.
      # All Submit milestones share one track/color; their shapes differ.
      if (phase == "Submit" || phase == "Abstract" || phase == "Full" || phase == "Deadline") return "#124D61,#9ADDEC"
      if (phase == "Review") return "#394966,#CDD7EF"
      if (phase == "Rebuttal") return "#6F4500,#FFD789"
      if (phase == "Notification") return "#10583F,#96E6BB"
      if (phase == "Camera Ready") return "#3E5360,#C9DBE5"
      if (phase == "Revision") return "#5B357D,#DCBDF4"
      if (phase == "Conference") return "#1B4A8D,#AECFFF"
      return "#45515D,#E0E5EB"
    }
    function marker_shape(phase) {
      if (phase == "Abstract") return "○"
      if (phase == "Deadline") return "△"
      if (phase == "Notification") return "◆"
      if (phase == "Rebuttal") return "◇"
      if (phase == "Revision") return "□"
      return "●"
    }
    function known_phase(phase) {
      return phase == "Submit" || phase == "Abstract" || phase == "Full" || phase == "Deadline" ||
             phase == "Review" || phase == "Rebuttal" ||
             phase == "Notification" || phase == "Revision" ||
             phase == "Camera Ready" || phase == "Conference"
    }
    function print_legend(phase) {
      printf "--%s %s | font=Menlo size=11 color=%s\n", marker_shape(phase), phase, phase_color(phase)
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
        phase = display_phase($4, $5)
        track_phase = ($4 == "Submit" ? "Submit" : phase)
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
        if (key in marker) marker[key] = "+"
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
        printf "--%-15s%s | font=Menlo size=11\n", row_label, date_line
      }
      axis = ""
      for (column = 0; column <= last; column++) {
        axis = axis ((column == 0 || column == last || tick[column]) ? "┬" : "─")
      }
      printf "--%-15s%s | font=Menlo size=11 color=#45515D,#E0E5EB\n", "Axis", axis

      for (i = 1; i <= selected; i++) {
        id = order[i]
        label = substr(labels[id], 1, 14)
        if (!milestones[id]) continue
        for (row = 1; row <= row_count[id]; row++) {
          phase = row_phase[id SUBSEP row]
          group = id SUBSEP phase
          track = ""
          for (column = 0; column <= last; column++) {
            key = group SUBSEP column
            track = track ((key in marker) ? marker[key] : "─")
          }
          printf "--%-15s%s  %s | font=Menlo size=11 color=%s\n", label, track, phase, phase_color(phase)
        }
      }
      print "--Legend | font=Menlo size=11"
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
      print "--+ Overlapping milestones at the same chart position | font=Menlo size=11 color=#45515D,#E0E5EB"
      print "--Exact dates and times are in each conference menu | font=Menlo size=11 color=#45515D,#E0E5EB"
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
