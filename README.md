# CCF Conference Deadlines for SwiftBar and xbar

A macOS [SwiftBar](https://github.com/swiftbar/SwiftBar) and [xbar](https://xbarapp.com/) plugin for tracking academic conference timelines. It reads conference data from a JSON file, rotates upcoming important dates in the menu bar, and shows the full submission, review, rebuttal, notification, and camera-ready timeline in the dropdown menu.

> **AI-generated project notice:** The Bash code, initial JSON configuration, and this README were generated and revised by OpenAI Codex from user requirements. AI-generated code and conference dates may contain errors. Review the implementation before use, and always confirm a deadline on the official conference website before submitting a paper.

## Features

- Stores global settings, conferences, and timeline events in JSON.
- Provides a SwiftBar checklist for showing or hiding every configured conference.
- Rotates only dates within a configurable importance window, which defaults to 14 days.
- Lets each conference be shown or hidden independently with `visible`.
- Supports AoE, UTC, and other IANA time zones, including per-event overrides.
- Can automatically convert every conference event to the computer's local time zone.
- Marks completed, current, and future timeline events automatically.
- Separates the current workflow stage from the nearest upcoming event.
- Rejects invalid calendar dates, unknown time zones, and nonexistent daylight-saving wall-clock times instead of silently normalizing them.
- Caches validated timestamps, sorted events, and local display text between refreshes; countdowns and workflow state still update every minute.
- Lets the timeline width, label width, font, colors, markers, and axis symbols be configured in JSON.
- Shows a combined, color-coded timeline of selected conferences' events in the next calendar month.
- Uses red and orange colors for urgent and approaching dates.
- Supports deadline-based or configured ordering and an optional carousel limit.
- Provides official conference links and complete timelines in the dropdown menu.
- Remains compatible with the Bash 3.2 version bundled with macOS.

This project does not fetch conference information from the internet or update dates automatically. All dates come from the local JSON configuration.

## Repository Layout

```text
.
├── ccf-ddl.1m.sh   # SwiftBar/xbar plugin, executed once per minute
├── ccf-ddl.json    # Settings, conferences, and timeline events
├── README.md
└── tests/         # Timeline, date-validation, and workflow regression tests
```

## Requirements

- macOS
- [SwiftBar](https://github.com/swiftbar/SwiftBar) or [xbar](https://xbarapp.com/)
- Bash 3.2 or later
- `jq`

Install `jq` with Homebrew:

```bash
brew install jq
```

## SwiftBar Installation

1. Create the configuration directory and copy the JSON file:

   ```bash
   mkdir -p "$HOME/.config/xbar"
   cp ccf-ddl.json "$HOME/.config/xbar/ccf-ddl.json"
   ```

2. Open SwiftBar's configured **Plugin Folder**, then copy `ccf-ddl.1m.sh` into it.

3. Make the plugin executable:

   ```bash
   chmod +x "/path/to/SwiftBar/ccf-ddl.1m.sh"
   ```

4. Refresh the plugin in SwiftBar.

The `.1m.` segment in the filename tells SwiftBar or xbar to execute the plugin once per minute. The output format remains compatible with xbar if you prefer to use it instead.

You can also run the plugin directly from the repository:

```bash
./ccf-ddl.1m.sh
```

When run directly, the script uses `ccf-ddl.json` from its own directory if `~/.config/xbar/ccf-ddl.json` does not exist.

## Configuration

The configuration has the following top-level structure:

```json
{
  "schema_version": 1,
  "verified_at": "2026-09-22",
  "time_convention": {},
  "settings": {},
  "conferences": []
}
```

### Global Settings

```json
"settings": {
  "warning_days": 7,
  "urgent_days": 3,
  "important_days": 14,
  "display_local_time": true,
  "show_phase_in_carousel": false,
  "show_ccf_level": false,
  "show_finished": false,
  "carousel_limit": 0,
  "sort_by_deadline": true,
  "cache_dates": true,
  "timeline": {}
}
```

| Setting | Type | Description |
| --- | --- | --- |
| `warning_days` | Non-negative integer | Show an approaching date in orange when its remaining time is within this threshold. |
| `urgent_days` | Non-negative integer | Show an urgent date in red when its remaining time is within this threshold. |
| `important_days` | Non-negative integer | Include a conference in the menu-bar carousel only when its next event is within this many days. |
| `display_local_time` | Boolean | Convert configured conference times to the computer's local time zone when `true`. |
| `show_phase_in_carousel` | Boolean | Prefix the next event with the actual current workflow stage in the menu-bar carousel when `true`. |
| `show_ccf_level` | Boolean | Prefix conference abbreviations with their CCF level throughout the menu when `true`. |
| `show_finished` | Boolean | Keep conferences whose entire timeline has finished in the dropdown menu. |
| `carousel_limit` | Non-negative integer | Maximum number of rotating entries; `0` means no additional limit. |
| `sort_by_deadline` | Boolean | Use the next deadline when `true`; use each conference's `order` value when `false`. |
| `cache_dates` | Boolean | Cache date parsing and timezone conversions when `true` (the default if omitted). |
| `timeline` | Object | Optional timeline appearance overrides; omitted fields keep their defaults. |

The `important_days` boundary is inclusive. For example, when it is `14`, a next event no more than 14×24 hours away can enter the carousel. This setting affects only the menu-bar carousel; all visible, active conferences remain available in the dropdown menu.

### Timeline Appearance

The repository JSON contains the full default theme in `settings.timeline`.
Existing installed configurations need no changes: the plugin deep-merges a
partial theme with its defaults. For example, the following overrides only
the maximum axis width, font size, Submit color, and submission markers:

```json
"timeline": {
  "max_width": 200,
  "font_size": 12,
  "marker_version": 3,
  "colors": {
    "Submit": "#8A3D0A,#FFBD8A"
  },
  "markers": {
    "Abstract": "◎",
    "Full": "■"
  }
}
```

| Property | Default | Meaning / accepted values |
| --- | --- | --- |
| `min_width` | `49` | Minimum axis width in character cells, from 16 to 500. |
| `max_width` | `160` | Maximum axis width in character cells, from 16 to 500 and at least `min_width`. |
| `label_width` | `15` | Conference-label column width, from 8 to 64; longer names are truncated. |
| `font` | `"Menlo"` | Font family; use a monospaced font to preserve alignment. Names with spaces, such as `"SF Mono"`, are supported. |
| `font_size` | `11` | Font size, an integer from 6 to 48. |
| `colors` | Default light/dark palette | Map from phase/style names to `#RRGGBB` or `#light,#dark`. |
| `marker_version` | `3` in new themes | Use `3` for explicit overrides. Untagged/`1` icon themes and `2` code themes upgrade known defaults to the colored-icon theme. |
| `markers` | Geometric icons | Map from milestone names to one supported single-cell character; legacy/custom two-character ASCII alphanumeric codes are also accepted. |
| `symbols.line` | `"─"` | Track/axis line character. |
| `symbols.tick` | `"┬"` | Axis tick character. |
| `symbols.overlap` | `"+"` | Marker used when multiple milestones share a track position. |

Color keys are `Submit`, `Review`, `Rebuttal`, `Decision`, `Revision`,
`Camera Ready`, `Conference`, `Axis`, and `Default`. The `Submit` color applies
to both the entire Submit track and its grouped Abstract/Full/Deadline legend.
Marker keys describe node types within those groups:

- Submit: `Abstract`, `Full`, `Deadline`.
- Review: `Review` (reviews/checkpoints), `Early Reject`, `Round Update`, `Review Discussion` (internal discussion).
- Rebuttal: `Rebuttal Start`, `Rebuttal End`, `Rebuttal Due`.
- Decision: `Initial Decision`, `Final Decision`, `Revision Decision`.
- Revision: `Minor Revision`, `Major Revision`, `Revision Due`.
- Final preparation and meeting: `Camera Ready`, `Conference`.

`Rebuttal` and `Revision` also provide fallback markers for custom events without
a known role; `Default` covers unknown groups. Legacy `colors.Notification` and
`markers.Notification` are accepted as Decision aliases when their new keys are
absent. Non-default legacy phase-marker overrides also apply to their node types
unless an explicit node override is supplied. Themes with no `marker_version`
or version `1` upgrade known old default shapes and colors; version `2` themes
replace the v3.12 default letter codes and palette with colored icons. Only known
defaults migrate; non-default customizations remain. This is a display-only
migration: the plugin does not rewrite the configuration or visibility choices.
In version `3`, all overrides are explicit, including an intentionally selected
old color or code. A phase fallback does not replace its typed nodes. Keep each
color/icon combination distinct to avoid reintroducing ambiguity.
Custom phase keys can be added to either map; unknown phases use `Default`.
Colors and symbols are applied consistently to tracks and the legend.

The default palette retains the tested light/dark contrast. Supported geometric
markers include `○●△▲▽▼◇◆□■◊◦◎◉◌`. Two-character marker
codes accept only ASCII letters/digits. Track, tick, and overlap symbols must
still be single-cell characters; whitespace, emoji, backslashes, and `|` are rejected to
avoid breaking alignment or SwiftBar's parameter syntax. Width limits affect
the chart layout, not its calendar-month window or the actual event times.

### Conference Configuration

Each conference has the following structure:

```json
{
  "name": "USENIX Security 2027 Cycle 1",
  "short_name": "USENIX'27 C1",
  "ccf_level": "A",
  "visible": true,
  "timezone": "AoE",
  "url": "https://www.usenix.org/conference/usenixsecurity27/call-for-papers",
  "order": 10,
  "stages": [
    {
      "phase": "Submit",
      "event": "Registration",
      "datetime": "2026-08-18 23:59"
    }
  ]
}
```

| Field | Type | Description |
| --- | --- | --- |
| `name` | String | Full conference name. |
| `short_name` | String | Short name shown in the menu bar. |
| `ccf_level` | String | CCF ranking level. |
| `visible` | Boolean | Whether this conference is displayed. |
| `timezone` | String | `AoE`, `UTC`, or an IANA time-zone name. |
| `url` | String | Conference page opened from the dropdown menu. |
| `order` | Integer | Display order when deadline sorting is disabled. |
| `stages` | Array | Conference events; the plugin sorts them by their actual instants after applying time zones. |

When `visible` is `false`, the conference is removed from both the menu-bar carousel and the dropdown details, while its data remains in the configuration:

```json
"visible": false
```

### SwiftBar Conference Checklist

Open the plugin menu and expand **Conference Visibility**. It always contains every conference in the JSON configuration:

- a checked conference is shown in the menu-bar carousel and conference details;
- click a checked conference to hide it;
- click an unchecked conference to show it again.

The visibility checklist and conference headings use `short_name`, such as `NeurIPS'26` or `ICSE'27`, to keep the menu compact. Set `show_ccf_level` to `true` to prefix these labels with values such as `[CCF-A]`. Hover over a visibility checklist item to see its full conference name. Conference headings omit the hover tooltip so it cannot cover the `Current` line in their submenus. Each click atomically updates that conference's `visible` value in the active JSON configuration and asks SwiftBar to refresh the plugin. The selector itself remains available even when every conference is hidden.

### Combined Timeline Overview

Expand **Timeline Overview** for a horizontal, CCF Cycle-inspired timeline. All conferences checked in **Conference Visibility** share one date axis. A marker's horizontal position is proportional to its actual time between the current moment and the same local clock time one calendar month later. Past dates are not plotted, and selected conferences with no milestone in this window are omitted from the chart (they remain selected in **Conference Visibility**). If a conference has milestones in different display phases, it gets adjacent tracks on the same axis.

The chart and workflow engine share the B workflow classification: seven display
groups, with typed event nodes inside each group. Each conference gets at most
one track per group, not a separate track for every node type. Configured phase
names and detailed event names remain available in the JSON and conference menus.

| Configured phase or event | Track group | Node types in the legend |
| --- | --- | --- |
| Abstract, Paper/Full Paper, Registration, Artifacts, and other `Submit` events | Submit | `○` Abstract, `●` Full, `△` Deadline |
| Reviews Released, Early Reject, intermediate round notifications, and internal reviewer/AC discussion | Review | `●` Reviews, `△` Early Reject, `○` Round Update, `□` Discussion |
| Author Response, Rebuttal, Discussion, Feedback, or Interactive windows | Rebuttal | `◇` Starts, `◆` Ends, `△` Due |
| Initial Notification, Final Notification/Decision, Revision Notification/Decision | Decision | `◇` Initial, `◆` Final, `□` Revision Result |
| Minor/Major Revision, revision deadlines, and shepherd approval | Revision | `○` Minor, `□` Major, `△` Due |
| Camera Ready, Final Paper/Version, Direct Camera, or Revision Camera | Camera Ready | `●` Final Version |
| `Waiting` / Conf / Conference | Conference | `●` Start |

Early Reject and intermediate round notifications are Review checkpoints, not
final decisions. A generic Notification in the Decision phase is a Final node;
explicit Initial and Revision names retain their respective node types. In this
repository data, both NDSS cycles use `Early Reject Notification` in place of
the former `Round 2 Notification` label for display consistency; the underlying
dates have not changed.

Author discussion belongs to Rebuttal, while internal reviewer/AC discussion
belongs to Review. Internal/private or Reviewer-AC names are recognized; use the
optional `audience` field for an ambiguous Discussion event. Combined names such
as `Results / Rebuttal Starts` or `Early Reject / Response Starts` open the
Rebuttal window and retain their full original name in the conference details.
Revision tasks are distinguished from final-version tasks even when an older
configuration stores both under Camera; for example, Minor Revision belongs to
Revision, while Revision Camera belongs to Camera Ready.

The complete legend remains below the chart, with one row per group:

```text
Submit       · ○ Abstract · ● Full · △ Deadline
Review       · ● Reviews · △ Early Reject · ○ Round Update · □ Discussion
Rebuttal     · ◇ Starts · ◆ Ends · △ Due
Decision     · ◇ Initial · ◆ Final · □ Revision Result
Revision     · ○ Minor · □ Major · △ Due
Camera Ready · ● Final Version
Conference   · ● Start
```

Color identifies the workflow group; icon shape identifies a node inside that
group. Every default color/icon pair is distinct in both appearances: Full is
an orange filled circle, while Reviews is a violet filled circle. No letter
codes appear by default. Tracks and their grouped legend share the same color:

| Group | Color family | Light / dark colors |
| --- | --- | --- |
| Submit | Orange | `#8A3D0A` / `#FFBD8A` |
| Review | Violet | `#65358A` / `#DDBAF6` |
| Rebuttal | Amber | `#705000` / `#F8D77C` |
| Decision | Green | `#10583F` / `#96E6BB` |
| Revision | Rose | `#8A345A` / `#F4B4D3` |
| Camera Ready | Teal | `#00616A` / `#91DFE5` |
| Conference | Blue | `#1B4A8D` / `#AECFFF` |

The plugin uses [SwiftBar light/dark color pairs](https://swiftbar.github.io/SwiftBar/#parameters):
dark hues on light menus and pale hues on dark menus. These defaults pass a
4.5:1 contrast check against representative `#E9E9E9` / `#303030` backgrounds;
actual translucent menu surfaces vary. Colors apply to the entire group row,
without inline ANSI sequences. Shapes provide an additional cue, although
users with color-vision deficiencies may prefer custom icons or full event names
in the individual conference menus.

Custom Rebuttal/Revision events without a recognized role add an inline Other
entry (`◊`/`◌`) when present; unknown groups use `?` and get their own legend row.
Default icons occupy exactly one chart cell. Custom two-cell codes remain
supported; they are centered and clamped without shifting later events.
The axis widens when needed to fit markers and date labels. `+` means milestones
share a position or custom markers still collide at the width cap; whole markers
collapse, never partially overwrite one another. Exact events remain in the
individual conference menus. A plugin palette cannot override macOS temporarily
dimming the entire menu, including uncolored text.

Every plotted milestone position gets a tick and a computer-local date label above the axis. The axis grows just enough to keep date labels on one row, including a synthetic test with a milestone every day of a 31-day month. Its width is capped so an extremely clustered set of events cannot make the SwiftBar menu arbitrarily wide; only that exceptional case can require another date row. Labels normally show just the day number; if the same number occurs in two months within the window, both labels include the month (for example, `2/1` and `3/1`). The `Date` and `Axis` prefixes keep the scale aligned with the conference tracks in SwiftBar, which trims leading spaces. Open an individual conference below the chart for exact local timestamps and event names. Toggling a conference updates the chart after SwiftBar refreshes the plugin.

### Date-Only Time Convention

Conference pages often publish only a calendar date, even for a multi-day response, rebuttal, or conference period. The configuration uses these defaults when the official source does not publish a more precise time:

- the first day of a date range uses `00:00`;
- the last day of a date range uses `23:59`;
- notifications and releases, including early-reject notifications and review releases, use `00:00`;
- response, rebuttal, feedback, discussion, and other window starts use `00:00`;
- submission deadlines and window ends or due dates use `23:59`;
- the first day of a conference uses `00:00` in the venue's local time zone, when that time zone is known;
- an event-specific time from the official source can replace these date-only defaults.

The top-level `time_convention` object records this policy in the JSON file. Event names distinguish starts and announcements from deadlines: for example, `Rebuttal Starts` is at `00:00`, while `Rebuttal Ends` or `Rebuttal Due` is at `23:59`.

ICSE 2027 is a notable ambiguous case: its page calls September 23–25 a three-day author-response period, but also says that all dates are at `23:59:59 AoE`. This configuration treats the inclusive period as September 23 `00:00` through September 25 `23:59` AoE. That is a tracker normalization, not a guarantee that HotCRP will open at midnight; the submission system and organizer announcements remain authoritative.

### Timeline Events

Each timeline event contains:

- `phase`: the event's workflow group, such as `Submit`, `Review`, `Rebuttal`, or `Decision`; this is not automatically the current stage;
- `event`: the specific event, such as `Paper`, `Notification`, or `Camera Ready`;
- `datetime`: the local wall-clock time in the conference's configured time zone, formatted as `YYYY-MM-DD HH:MM`.
- `timezone` (optional): an AoE, UTC, or IANA time-zone override for this event. When omitted, the event inherits the conference's `timezone`.
- `kind` (optional): `start`, `end`, `deadline`, `notification`, or `milestone`. This makes the event's role explicit instead of inferring it from its English name.
- `audience` (optional): `authors` or `reviewers`. Author discussion maps to Rebuttal; internal reviewer/AC discussion maps to Review. Use this to disambiguate a Discussion name; omitted values retain the legacy author-discussion interpretation unless an internal/private/Reviewer-AC name makes the audience clear.
- `phase_after` (optional): the workflow stage to use after this event occurs. Use this override for a transition that cannot be inferred from ordinary milestones.

Per-event time zones are useful when submission deadlines are AoE but the conference itself starts in the venue's local time zone:

```json
{
  "phase": "Waiting",
  "event": "Conf",
  "datetime": "2027-08-11 00:00",
  "timezone": "America/Denver"
}
```

Dates must exactly match `YYYY-MM-DD HH:MM` and exist in the specified time zone. For example, `2027-02-30`, `2027-02-29`, `24:00`, an unknown IANA zone, or a time skipped by a daylight-saving transition is rejected. Event seconds are explicitly zero. The plugin never silently moves such a date into another day. If a visible conference contains an invalid date or time zone, its details show a diagnostic and its countdown and overview markers are withheld until the data is fixed; other conferences continue to work.

The script sorts events by their parsed timestamps, including per-event time zones, and selects the earliest event strictly after the current instant as `Next event`. Equal timestamps keep their original JSON order. Timeline symbols mean:

- `✓`: completed;
- `▶`: the nearest upcoming event, not a statement that its stage has already started;
- `○`: a later event.

With `show_phase_in_carousel` set to `false`, the menu-bar carousel shows only the conference abbreviation, next event, and remaining time, for example `NeurIPS'26 · Notification · 2d9h`. Set it to `true` to show `NeurIPS'26 · Review→Notification · 2d9h` instead. The prefix is the current stage, not the future event's configured phase. Dropdown details show separate `Current`, `Next event`, and `When` lines. Remaining time is shown to hour precision: `2d9h` means two days and nine hours, `9h` means less than one day remains, and durations below one hour are shown in minutes.

### Current Stage vs. Next Event

`Current` is inferred from milestones that have already occurred, rather than
copied from the next event's group. Author Response, Discussion, Feedback,
Interactive, and Rebuttal windows are normalized to `Rebuttal`; internal
reviewer/AC discussion remains `Review`. Early/round review updates and Decision
notifications are instantaneous checkpoints, not persistent Current stages.

| Position in the configured timeline | Current | Example next event |
| --- | --- | --- |
| Submission deadlines remain | Submit | Paper |
| Last submission deadline passed; rebuttal has not started | Review | Response Starts |
| Rebuttal start reached; its end is still ahead | Rebuttal | Response Ends |
| Rebuttal ended; decision is still ahead | Review | Notification |
| Decision notification reached; revision deadline follows | Revision | Revision Due |
| Decision notification reached; camera-ready deadline follows | Camera Ready | Camera Ready |
| Final preparation completed; conference start is ahead | Waiting | Conf |
| No future milestones remain | Finished | none |

Stage transitions apply at the exact event timestamp: a start is active at that
instant, while an end or deadline is already completed. An early/round
notification or review release keeps the current stage at `Review` and never
implies that the user's paper was rejected. Consecutive author
response/discussion end milestones can represent one continuous normalized
Rebuttal window; a later explicit start instead represents a separate window,
with Review in between.

These are workflow inferences from the configured data, not knowledge of an organizer's submission system. Missing opening dates cannot be recovered from a deadline alone. Add explicit start events to describe exact windows, and use `kind` for non-English/custom event names. `phase_after` takes precedence over inferred transitions, for example:

```json
{
  "phase": "Response",
  "event": "Author response opens",
  "datetime": "2027-03-22 00:00",
  "kind": "start",
  "phase_after": "Rebuttal"
}
```

Existing configurations need no new fields. Without `kind`, names such as `Starts`, `Ends`, and `Due` plus the shared phase mapping determine the event role. Without `phase_after`, the normal workflow transitions apply. `Finished` means that the configured timeline has no future milestone; it does not infer an unrecorded conference end date.

For example, an internal discussion can explicitly identify its audience:

```json
{
  "phase": "Discussion",
  "event": "Discussion Starts",
  "datetime": "2027-03-22 00:00",
  "audience": "reviewers"
}
```

### Local Time-Zone Conversion

Conference dates remain stored in the time zone declared by each conference or by an individual event override. With the default setting below, the plugin first interprets the configured wall-clock time in that source time zone and then displays the equivalent time in the computer's local time zone:

```json
"display_local_time": true
```

For example, an AoE deadline may be displayed as:

```text
2026-10-08 00:59 NZDT (local)
```

The operating system applies the appropriate UTC offset and daylight-saving rule for each event date. The output includes the local time-zone abbreviation and the `(local)` marker.

To display the original configured date and time zone instead, use:

```json
"display_local_time": false
```

For backward compatibility, the script treats a configuration without `display_local_time` as if the value were `true`.

## Custom Configuration Path

Set `CCF_DDL_CONFIG` to use another JSON file:

```bash
CCF_DDL_CONFIG="/path/to/my-ccf-ddl.json" ./ccf-ddl.1m.sh
```

The script checks configuration locations in this order:

1. the file specified by `CCF_DDL_CONFIG`;
2. `~/.config/xbar/ccf-ddl.json`;
3. `ccf-ddl.json` in the script's directory.

## Parsed Date Cache

Date caching is enabled by default, including for legacy configurations without
`cache_dates`. The cache stores validated timestamps, deterministic event order,
source/local display timestamps, local calendar dates, and validation errors.
It does not store the current stage, next event, countdown, or one-month window;
those are recalculated on every refresh, even on a cache hit.

The plugin rebuilds the cache when the configuration content, plugin code, local
timezone, or relevant installed timezone-file contents change. Configuration
checks use content checksums rather than modification times, so same-size edits
with unchanged timestamps are detected. A single configuration snapshot is used
per refresh. Cache files are published atomically with private permissions;
damaged or truncated files are rebuilt. If the cache directory is unavailable
or read-only, the plugin runs normally without persistent caching.

By default, caches live outside the repository and installed configuration:

- macOS: `~/Library/Caches/ccf-ddl`;
- other systems: `~/.cache/ccf-ddl`;
- if `XDG_CACHE_HOME` is set: `$XDG_CACHE_HOME/ccf-ddl` instead.

Set `CCF_DDL_CACHE_DIR` to override that location. To disable caching, use
`"cache_dates": false` in `settings`. For diagnostics, `CCF_DDL_CACHE_DEBUG=1`
prints `hit`, `rebuilt`, `disabled`, or `unavailable` to stderr without changing
the SwiftBar menu output:

```bash
CCF_DDL_CACHE_DEBUG=1 CCF_DDL_CONFIG="./ccf-ddl.json" ./ccf-ddl.1m.sh
```

Only parsed data is cached; cached content is never sourced or evaluated as
shell code. Caching does not fetch new conference dates or modify preferences.

## Maintaining Conference Data

When adding or updating a conference:

1. Set `visible` to either `true` or `false`.
2. Use an integer for `order`; unique values are recommended.
3. Prefer chronological order for readability; the plugin sorts by actual event timestamps automatically.
4. Use the time zone specified by the official conference website.
5. Add a stage-level `timezone` when an event uses a different time zone, such as a venue-local conference start following AoE submission deadlines.
6. Apply the top-level date-only time convention unless the official source gives an explicit time.
7. Update the top-level `verified_at` value after verifying the data.

Conference organizers may revise dates at any time. `verified_at` records the last manual verification of the configuration; it does not mean that the program continuously validates the data.

## Local Validation

Validate the JSON syntax:

```bash
jq empty ccf-ddl.json
```

Check the Bash syntax:

```bash
bash -n ccf-ddl.1m.sh
```

Run the timeline regression test. It uses a fixed clock and synthetic daily
milestones across both 28- and 31-day months, checks that their labels fit on
one row and every node survives, verifies the shared Submit track and its
Abstract/Full/Deadline markers and phase-grouped legend, checks light/dark color contrast
against representative menu backgrounds, and confirms that empty conference
tracks are hidden:

```bash
bash tests/test_timeline_overview.sh
```

Run the date and workflow tests. They cover invalid dates, leap-year rules,
unknown time zones, a daylight-saving gap, explicit zero seconds, unsorted
mixed-zone events, current/next separation, exact start/end boundaries, and
optional event-role and transition overrides:

```bash
bash tests/test_dates_and_phases.sh
```

Run the cache/theme regression tests. They compare cold/warm output and native
date-call counts, advance the clock on a cache hit, change the local timezone,
test concurrent refreshes and same-size edits with preserved modification times, recover corrupted and
truncated caches, retain invalid-date diagnostics, and exercise theme overrides,
legacy defaults, and unavailable/disabled caching:

```bash
bash tests/test_cache_and_theme.sh
```

Run the B workflow regression test. It checks both NDSS labels, typed nodes in
all seven groups, chart/legend color agreement, author versus internal
discussion, checkpoint and decision transitions, distinct color/icon pairs,
legacy icon/code-theme migration, and theme aliases:

```bash
bash tests/test_workflow_groups.sh
```

Check node-marker layout, including every typed/fallback icon, exact tick alignment,
equal track widths, endpoint clipping, mixed one-/two-cell overrides, and crowded
events at the width cap:

```bash
bash tests/test_node_markers.sh
```

Tests use isolated temporary cache directories and do not write to the installed
configuration or normal cache location.

Inspect the generated xbar output:

```bash
./ccf-ddl.1m.sh
```

## Troubleshooting

### `Missing dependency: jq`

Install `jq`, then refresh xbar:

```bash
brew install jq
```

### `Configuration not found`

Make sure the configuration is available at `~/.config/xbar/ccf-ddl.json`, or select another path with `CCF_DDL_CONFIG`.

### `Invalid JSON configuration`

Start by checking the JSON syntax:

```bash
jq empty ccf-ddl.json
```

If the syntax is valid, check the types of all required fields. The script validates global settings, `visible`, conference metadata, and timeline event fields.

### `Unavailable (invalid timeline)`

Expand the conference's Timeline to find the invalid event. Correct its date/time
or time-zone name in the active JSON file and refresh SwiftBar. Real calendar
dates are required, including February's leap-year rules; use `00:00` on the
following day instead of `24:00`. The plugin does not auto-correct invalid data.

### No conference is rotating in the menu bar

Check the following:

- the conference's `visible` value is `true`;
- its next event is within the `important_days` window;
- `carousel_limit` has the intended value;
- the conference still has a future timeline event.

## AI-Generated Code and Responsibility

This project was implemented primarily by OpenAI Codex, including the configuration format, Bash parsing logic, filtering behavior, and README. The code has not undergone formal verification, and the conference dates are not guaranteed to be correct. Users should review the implementation, inspect the configuration and external links, and confirm every final deadline on the corresponding official conference website.
