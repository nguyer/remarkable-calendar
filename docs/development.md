# Development

This guide covers the architecture, source layout, builds, tests, and maintenance of **reMarkable Calendar**. For installation and everyday use, start with the [README](../README.md). Google account setup is covered in the [Google Calendar guide](google-calendar.md).

## Project layout

| Location               | Responsibility                                                                           |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| `src/main.rs`          | CLI, SQLite initialization/migrations, weekly event responses, and loopback HTTP server  |
| `src/lifecycle.rs`     | Native AppLoad lifecycle connection                                                      |
| `src/google.rs`        | Google authorization refresh, calendar discovery, event conversion, and cached snapshots |
| `src/settings.rs`      | Calendar selections, display preferences, and rolling sync windows                       |
| `src/sync_job.rs`      | Background sync jobs, progress, and single-job coordination                              |
| `src/edits.rs`         | Local event changes, persistent Google outbox, version checks, and acknowledgments       |
| `qml/`                 | Qt Quick screens and reusable controls                                                   |
| `packaging/`           | AppLoad manifest and QML resource listing                                                |
| `scripts/`             | Build, deployment, testing, and desktop Google authorization helpers                     |
| `tests/`               | HTTP/lifecycle, authorization-helper, and QML layout tests                               |
| `examples/events.json` | Optional sample data; never imported automatically                                       |

## Architecture

The Rust backend stores local events, Google snapshots, settings, and pending edits in SQLite. The Qt Quick frontend communicates with it through JSON over `127.0.0.1:38765`. The listener is bound to loopback, and Google network work runs in a background worker so cached navigation remains available during sync.

AppLoad launches `backend/entry`, passes a Unix `SOCK_SEQPACKET` socket path, and loads `/qml/Main.qml` from the resource bundle. The backend initializes the database and binds HTTP before connecting to the lifecycle socket. It exits when the lifecycle connection closes or receives termination. QML's `unloading()` terminates the AppLoad endpoint. Do not add a separate shell launcher or detached backend process.

Google synchronization uses bounded, paginated calendar snapshots, with recurring events expanded by Google. A successful download replaces that calendar's cached interval; a failed download retains its previous snapshot. Pending local changes overlay the cache. Sync sends queued changes before pulling events; stable creation IDs and conditional version checks help prevent duplicate creates and silent overwrites. Failures remain visible in the outbox. There is no continuous connectivity monitor or periodic sync timer: automatic sync is evaluated on backend launch.

Weeks start on Monday and use a Monday-inclusive, next-Monday-exclusive interval. Multi-day events are clipped into daily display segments, while their original span is retained for details and editing. All-day end dates are exclusive in storage and Google's API; the editor displays the last included date.

### QML organization

`Main.qml` owns shared state, navigation, request lifetimes, and layout calculations. Screens receive that controller through a required `app` property.

| File                                                           | Responsibility                                                |
| -------------------------------------------------------------- | ------------------------------------------------------------- |
| `WeekView.qml`                                                 | Weekly toolbar, date labels, event columns, and week gestures |
| `CalendarToolbar.qml` | Shared primary-view navigation, Settings, Sync, and top-edge gesture space |
| `DayPage.qml` | Primary day screen containing its toolbar and schedule |
| `DetailsView.qml`                                              | Event details overlay and toolbar                 |
| `DayView.qml`                                                  | All-day events, hourly schedule, and day gestures             |
| `EventView.qml`                                                | Event details                                                 |
| `EventEditor.qml`                                              | Create/edit form and keyboard                                 |
| `SettingsView.qml`                                             | Calendar selection, display preferences, and sync status      |
| `ChangeConfirmation.qml`                                       | Delete/discard confirmation                                   |
| `ToolbarTitle.qml`                                             | Consistent uppercase toolbar typography                       |
| `ToolbarButton.qml`, `SettingsAction.qml`, `CalendarEvent.qml` | Reusable controls and event presentation                      |

Screen aliases let the controller measure the weekly canvas, position scroll views, and dismiss the keyboard. Add new QML files to `packaging/application.qrc`; otherwise the tablet bundle will not contain them.

Keep eInk updates stable: calculate weekly event placement before publishing a new model, fit whole entries, and preserve the displayed date/events until a navigation request completes. The weekly view does not scroll. Avoid `Accessible` attached properties: they previously prevented loading on the tablet's Qt build.

## Development environment

Use Linux or WSL, keeping the checkout in the Linux filesystem, for example `~/Code/remarkable-calendar`. Install a current stable Rust toolchain via rustup, Python 3, Node.js for layout tests, Qt 6 tools, and a C compiler for bundled SQLite.

On Debian/Ubuntu, the system dependencies include:

```sh
sudo apt update
sudo apt install build-essential python3 nodejs qt6-base-dev-tools qt6-declarative-dev-tools gcc-aarch64-linux-gnu
```

Qt's `net.asivery.AppLoad` module is provided on the tablet. A desktop QML runner cannot fully validate the app without a compatible AppLoad environment.

## Build for the tablet

The current target is **Paper Pro Move / ARM64**, `aarch64-unknown-linux-gnu`. It is not the ARM32 target used by reMarkable 1/2. Check the tablet with `ssh root@10.11.99.1 uname -m`; the expected result is `aarch64`.

From the repository root:

```sh
rustup target add aarch64-unknown-linux-gnu
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
./scripts/build-backend.sh
RCC=/usr/lib/qt6/libexec/rcc ./scripts/build-ui.sh
```

`CC_aarch64_unknown_linux_gnu` is required because bundled SQLite includes C code. Set `RCC` to your Qt **6** resource compiler; `/usr/bin/rcc` may be a Qt 5 wrapper. The resource bundle uses format 3 without compression and contains QML source rather than host-specific bytecode.

In the original development SDK, the UI build command is:

```sh
RCC=/opt/codex/ferrari/5.0.58-dirty/sysroots/x86_64-codexsdk-linux/usr/libexec/rcc ./scripts/build-ui.sh
```

Use that path only if the SDK exists on your computer. Confirm the compiler with `rcc --version` at your chosen path.

The complete installable bundle is written to `dist/remarkable-calendar/`, containing `manifest.json`, `resources.rcc`, `icon.png`, and `backend/entry`. The compiled Rust executable is named `remarkable-calendar-core`; the build script copies it to the AppLoad entry path.

A distribution cross compiler can require a newer glibc than the tablet provides. Compare tablet `ldd --version` with the requirements reported by `readelf --version-info dist/remarkable-calendar/backend/entry`. If incompatible, use the matching reMarkable ARM64 SDK linker, C compiler, and sysroot. Do not replace tablet system libraries.

### Deploy and iterate

Close Calendar on the tablet before deploying:

```sh
./scripts/deploy.sh 10.11.99.1
```

Then select **AppLoad → Reload** and reopen **Calendar**. The deploy script copies the bundle and replaces the backend through a temporary file; it does not reload AppLoad automatically. Stop any manually launched legacy backend before opening the app, since only one process can own the HTTP port.

For **QML-only changes**, rebuild just the UI bundle, then deploy and reload. A backend build must already exist in the bundle folder. For **Rust changes**, rebuild the backend before deploying. Deployment retains the existing tablet data directories.

## Tests and checks

Run from the repository root:

```sh
./scripts/test.sh
node tests/layout.cjs
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
git diff --check
```

The main test script runs Rust tests, builds the host executable, and runs the Python authorization and AppLoad/HTTP integration tests. Tests require local socket access and port `38765` to be free. They use temporary databases and mock services; they do not establish tablet compatibility or exercise a live Google account.

The layout tests extract the actual QML helper functions from `Main.qml` and run them with deterministic measurements. Keep the extracted function section compatible with that harness when moving code. Parse changed QML with a compatible `qmlformat`; desktop import diagnostics may be incomplete without the tablet modules.

On the tablet, verify week/day navigation, event return navigation, overflow labels, keyboard dismissal, display preferences, contrast, and close/reopen persistence. For sync changes, also check offline edits, reconnect-and-sync, Google permissions, and pending/error handling. Host tests do not replace these device checks.

## Storage, compatibility, and backups

The repository name is `remarkable-calendar`, the project title is **reMarkable Calendar**, and the AppLoad display name is **Calendar**. The following identifiers retain their original names so existing installations continue working:

| Item                  | Value                                                   |
| --------------------- | ------------------------------------------------------- |
| AppLoad ID            | `org.remarkablecalendar.move`                           |
| Tablet install folder | `/home/root/xovi/exthome/appload/remarkable-calendar`   |
| Database              | `$HOME/.local/share/remarkable-calendar/events.sqlite3` |
| Google credentials    | `$HOME/.config/remarkable-calendar/google.json`         |
| Database override     | `REMARKABLE_CALENDAR_DB`                                |
| Credentials override  | `REMARKABLE_CALENDAR_GOOGLE_CREDENTIALS`                |
| HTTP mutation header  | `X-RemarkableCalendar-Request: sync`                    |

Credentials must remain outside version control. The authorization helper creates its output with private permissions and refuses to overwrite an existing file.

For a full database backup, close Calendar and any manual backend first, then copy the database:

```sh
scp root@10.11.99.1:/home/root/.local/share/remarkable-calendar/events.sqlite3 ./calendar-backup.sqlite3
```

That database includes local events, cached Google events, settings, and pending edits. The Google credentials file is separate. Keep backups private.

### Local event CLI

```sh
cargo run -- import examples/events.json
cargo run -- export > local-events.json
cargo run -- delete planning-2026-10-26
cargo run -- 2026-10-26
```

Import atomically upserts local events by ID; removing an entry from an import file does not delete it. Export includes local events only, not Google cache or queued Google edits, so it is not a full backup. Never import sample events into a user's database implicitly.

Required import fields are `id`, `title`, `day` (`YYYY-MM-DD`), `start`, `end` (24-hour `HH:MM`), and `color` (`#RRGGBB`). Optional `end_day` supports overnight/multi-day events. `all_day: true` requires midnight start/end and a later exclusive `end_day`. After an external import, change weeks or reopen the app to refresh.

## Local HTTP interface

For host debugging, start `cargo run -- serve` and inspect `http://127.0.0.1:38765/health` or `/week?date=2026-10-26` from another terminal. Do not run a manual server alongside an AppLoad-launched backend.

| Endpoint                                | Purpose                                                       |
| --------------------------------------- | ------------------------------------------------------------- |
| `GET /health`                           | Health check                                                  |
| `GET /week?date=YYYY-MM-DD`             | Weekly events, Google cache metadata, and display preferences |
| `GET /google/status`                    | Cached sync metadata and pending count                        |
| `GET /google/sync`, `POST /google/sync` | Read job status or start sync                                 |
| `POST /google/calendars/refresh`        | Refresh the calendar catalog                                  |
| `GET /settings`, `POST /settings`       | Read or save preferences and calendar selection               |
| `GET /events/item?id=...`               | Original event details and pending/error metadata             |
| `GET /events/pending`                   | Pending changes                                               |
| `POST /events/change`                   | Create, update, delete, or discard a local/queued change      |

Mutation requests require `X-RemarkableCalendar-Request: sync`. JSON requests use `Content-Type: application/json`; bodies are limited to 64 KiB. The header blocks simple cross-origin browser submissions; it is not authentication against other local programs. Request deadlines and navigation generation guards prevent stale responses from replacing newer views.

## Restoring the last calendar view

Month, week, and day are primary screens selected by `Main.qml`'s `primaryView`. Event details, editing, and Settings are overlays; opening them does not replace the primary view. `CalendarToolbar.qml` is shared by all primary screens and leaves the top 12 pixels without input handlers, matching the original week screen so AppLoad can handle pull-down gestures.

`GET /navigation` returns `{"navigation":null}` on a fresh database, or a saved `{view,date}` record. `POST /navigation` validates and saves that record with the usual mutation header. Navigation is stored in its own `navigation_state` table; Settings saves and calendar sync do not modify it. Month dates identify the first of the displayed month, week dates identify the displayed Monday, and day dates identify the displayed day. The frontend restores navigation before starting its initial calendar loads and serializes subsequent writes to preserve their order. Only successfully displayed dates are saved, rather than targets of failed requests. Closing from an overlay restores the underlying primary screen on the next launch.

The navigation harness (`node tests/navigation.cjs`) checks restoration and ordered writes; HTTP tests verify validation, settings isolation, and persistence across process restart. AppLoad pull-down access still needs a physical tablet check after deployment.

## Month view

`MonthView.qml` uses the shared toolbar and computes a Monday-first grid with four to six rows. ISO week numbers use UTC date arithmetic to stay stable across daylight-saving transitions and ISO week-year boundaries. Day-cell and week-gutter taps resolve directly to dates; horizontal swipes change the month without triggering a tap. Month navigation always constructs the first day of the target month, avoiding month-end rollover from dates such as January 31. The grid loads cached events with `GET /month?date=YYYY-MM-DD`, which returns all daily segments across its four-to-six-week visible range, including adjacent-month days. The endpoint reuses weekly clipping and pending-change overlays. A complete response replaces the displayed month and its events together; stale or failed requests retain the previous grid. Event names are premeasured at 20px, wrap to at most two lines, and display beside a colored line without times. Only complete entries fit; an overflow count reserves footer space only when needed. `tests/month.cjs` covers grid geometry, leap years, ISO week numbering, month navigation, and hit testing. `tests/month-data.cjs` covers response ordering, failures, measured event fitting, and overflow.

### Month performance

Month responses contain only event IDs, dates, titles, and colors. The month endpoint now projects these fields directly from date-filtered local/Google records, with a JSON date-range index on the Google cache. It avoids parsing every cached event into full details or creating detailed week segments for month previews. Full details are loaded through day/event requests. The frontend keeps an LRU cache of three month responses, invalidated after acknowledged edits, Settings saves, and completed syncs (including partial failures). Invalidation also cancels an in-flight month request so older previews cannot repopulate the cache.

Text heights are cached for up to 512 titles at the current cell width. Layout uses `FontMetrics.advanceWidth` and font height to reserve one or two lines, without forced hidden-Text layouts. It measures only the prefix that can fit in a day, then trims complete entries if an overflow footer is needed. Month publication suppresses intermediate geometry reflows, and event rows use the simpler event-data model. The crowded-day regression case verifies that 1,000 events require only two text layouts at the tested cell height, with no extra text layouts for a repeat render. These checks measure work avoided on the host; actual switching latency must be checked on the tablet.

In a host debug-build benchmark with 3,600 synthetic Google events and 350 visible segments, the same compact month response decreased from a median 234.03ms to 30.29ms over five requests. This is endpoint timing on the computer, not tablet rendering latency. `Calendar month load` and `Calendar month layout` log messages report request, parse, publication, and layout durations without logging event contents; inspect them in the tablet's application logs when investigating further delays.

Startup and post-sync refreshes now load only the active primary calendar view, avoiding a hidden full-week fetch before month display.

### Canvas month previews

`MonthEventsCanvas.qml` draws all event color lines, wrapped titles, and overflow labels into one transparent image layer. The existing grid/date items and gesture hit testing remain separate. This avoids constructing a QML Text/Rectangle subtree for every visible event. Wrapped lines are cached (up to 512 entries) and clipped to each day's preview area. `tests/month-paint.cjs` checks wrapping, ellipsis, line caching, colors, overflow labels, and paint bounds using the actual drawing helpers with a recording context.

The temporary performance readout has been removed from Settings. Timing messages remain available in application logs; they exclude the final display refresh and should not be presented as measured eInk latency. The user confirmed that the single-layer month renderer is substantially faster on the tablet.

## Automated releases

See [Releases and Vellum packaging](packaging.md) for the GitHub Actions workflow, signing-key setup, version tags, local package builds, and tablet validation. The workflow builds the backend and QML from source, produces a signed ARM64 Vellum package and app bundle, and creates a draft release for version tags. It does not submit to the Vellum catalog automatically.
