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
└── README.md
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
  "show_finished": false,
  "carousel_limit": 0,
  "sort_by_deadline": true
}
```

| Setting | Type | Description |
| --- | --- | --- |
| `warning_days` | Non-negative integer | Show an approaching date in orange when its remaining time is within this threshold. |
| `urgent_days` | Non-negative integer | Show an urgent date in red when its remaining time is within this threshold. |
| `important_days` | Non-negative integer | Include a conference in the menu-bar carousel only when its next event is within this many days. |
| `display_local_time` | Boolean | Convert configured conference times to the computer's local time zone when `true`. |
| `show_finished` | Boolean | Keep conferences whose entire timeline has finished in the dropdown menu. |
| `carousel_limit` | Non-negative integer | Maximum number of rotating entries; `0` means no additional limit. |
| `sort_by_deadline` | Boolean | Use the next deadline when `true`; use each conference's `order` value when `false`. |

The `important_days` boundary is inclusive. For example, when it is `14`, a next event no more than 14×24 hours away can enter the carousel. This setting affects only the menu-bar carousel; all visible, active conferences remain available in the dropdown menu.

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
| `stages` | Array | Conference events in chronological order. |

When `visible` is `false`, the conference is removed from both the menu-bar carousel and the dropdown details, while its data remains in the configuration:

```json
"visible": false
```

### SwiftBar Conference Checklist

Open the plugin menu and expand **Conference Visibility**. It always contains every conference in the JSON configuration:

- a checked conference is shown in the menu-bar carousel and conference details;
- click a checked conference to hide it;
- click an unchecked conference to show it again.

Each click atomically updates that conference's `visible` value in the active JSON configuration and asks SwiftBar to refresh the plugin. The selector itself remains available even when every conference is hidden.

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

- `phase`: the current workflow phase, such as `Submit`, `Review`, `Rebuttal`, or `Decision`;
- `event`: the specific event, such as `Paper`, `Notification`, or `Camera Ready`;
- `datetime`: the local wall-clock time in the conference's configured time zone, formatted as `YYYY-MM-DD HH:MM`.
- `timezone` (optional): an AoE, UTC, or IANA time-zone override for this event. When omitted, the event inherits the conference's `timezone`.

Per-event time zones are useful when submission deadlines are AoE but the conference itself starts in the venue's local time zone:

```json
{
  "phase": "Waiting",
  "event": "Conf",
  "datetime": "2027-08-11 00:00",
  "timezone": "America/Denver"
}
```

The script treats the first future event of each conference as its next event. Timeline symbols mean:

- `✓`: completed;
- `▶`: the current next event;
- `○`: a later event.

Remaining time is shown to hour precision: `2d9h` means two days and nine hours, `9h` means less than one day remains, and durations below one hour are shown in minutes.

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

## Maintaining Conference Data

When adding or updating a conference:

1. Set `visible` to either `true` or `false`.
2. Use an integer for `order`; unique values are recommended.
3. Keep `stages` in chronological order.
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

### No conference is rotating in the menu bar

Check the following:

- the conference's `visible` value is `true`;
- its next event is within the `important_days` window;
- `carousel_limit` has the intended value;
- the conference still has a future timeline event.

## AI-Generated Code and Responsibility

This project was implemented primarily by OpenAI Codex, including the configuration format, Bash parsing logic, filtering behavior, and README. The code has not undergone formal verification, and the conference dates are not guaranteed to be correct. Users should review the implementation, inspect the configuration and external links, and confirm every final deadline on the corresponding official conference website.
