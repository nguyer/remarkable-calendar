use chrono::{Datelike, Duration, Local, NaiveDate, NaiveTime};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    env,
    error::Error,
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
};
mod edits;
mod google;
mod lifecycle;
mod settings;
mod sync_job;
type Result<T> = std::result::Result<T, Box<dyn Error>>;
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct EventDetails {
    location: String,
    description: String,
    calendar_name: String,
    timezone: String,
    start_day: String,
    start_time: String,
    end_day: String,
    end_time: String,
    calendar_id: String,
    event_id: String,
    etag: String,
    writable: bool,
    local_event: bool,
    recurring: bool,
    pending: bool,
    sync_error: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Event {
    id: String,
    title: String,
    day: String,
    start: String,
    end: String,
    color: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    end_day: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    all_day: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    details: Option<EventDetails>,
}
#[derive(Serialize)]
struct Week {
    start: String,
    events: Vec<Event>,
    google: serde_json::Value,
    display: serde_json::Value,
}
fn monday(date: NaiveDate) -> NaiveDate {
    date - Duration::days(date.weekday().num_days_from_monday() as i64)
}
fn date(s: &str) -> Result<NaiveDate> {
    let d = NaiveDate::parse_from_str(s, "%Y-%m-%d")?;
    if d.to_string() != s || !(1..=9998).contains(&d.year()) {
        return Err("date must be YYYY-MM-DD, year 0001–9998".into());
    }
    Ok(d)
}
fn database(path: &std::path::Path) -> Result<Connection> {
    if let Some(p) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(p)?;
    }
    let db = Connection::open(path)?;
    db.busy_timeout(std::time::Duration::from_secs(3))?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,day TEXT NOT NULL,start TEXT NOT NULL,end TEXT NOT NULL,color TEXT NOT NULL); CREATE INDEX IF NOT EXISTS events_day ON events(day);")?;
    let columns = {
        let mut stmt = db.prepare("PRAGMA table_info(events)")?;
        let names = stmt
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        names
    };
    if !columns.iter().any(|name| name == "end_day") {
        db.execute_batch("ALTER TABLE events ADD COLUMN end_day TEXT;")?;
    }
    if !columns.iter().any(|name| name == "all_day") {
        db.execute_batch("ALTER TABLE events ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0;")?;
    }
    if !columns.iter().any(|name| name == "details") {
        db.execute_batch("ALTER TABLE events ADD COLUMN details TEXT;")?;
    }
    db.pragma_update(None, "user_version", 6)?;
    google::init(&db)?;
    Ok(db)
}
fn validate(e: &Event) -> Result<()> {
    let first = date(&e.day)?;
    let last = date(e.end_day.as_deref().unwrap_or(&e.day))?;
    let a = NaiveTime::parse_from_str(&e.start, "%H:%M")?;
    let b = NaiveTime::parse_from_str(&e.end, "%H:%M")?;
    if a.format("%H:%M").to_string() != e.start
        || b.format("%H:%M").to_string() != e.end
        || last < first
        || (last == first && a >= b)
    {
        return Err("require HH:MM times and an end date/time later than start".into());
    }
    if e.all_day && (e.start != "00:00" || e.end != "00:00" || last <= first) {
        return Err(
            "all-day events require midnight boundaries and an exclusive later end_day".into(),
        );
    }
    if e.id.trim().is_empty() || e.title.trim().is_empty() || e.title.len() > 4096 {
        return Err("nonempty id/title required; title max 4096 bytes".into());
    }
    if e.color.len() != 7
        || !e.color.starts_with('#')
        || !e.color[1..].bytes().all(|c| c.is_ascii_hexdigit())
    {
        return Err("color must be #RRGGBB".into());
    }
    Ok(())
}
fn import(db: &mut Connection, events: &[Event]) -> Result<()> {
    for e in events {
        validate(e)?;
    }
    let tx = db.transaction()?;
    for e in events {
        tx.execute("INSERT INTO events (id,title,day,start,end,color,end_day,all_day,details) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(id) DO UPDATE SET title=excluded.title,day=excluded.day,start=excluded.start,end=excluded.end,color=excluded.color,end_day=excluded.end_day,all_day=excluded.all_day,details=excluded.details",params![e.id,e.title,e.day,e.start,e.end,e.color,e.end_day,e.all_day,e.details.as_ref().map(serde_json::to_string).transpose()?])?;
    }
    tx.commit()?;
    Ok(())
}
fn event_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Event> {
    Ok(Event {
        id: r.get(0)?,
        title: r.get(1)?,
        day: r.get(2)?,
        start: r.get(3)?,
        end: r.get(4)?,
        color: r.get(5)?,
        end_day: r.get(6)?,
        all_day: r.get(7)?,
        details: r
            .get::<_, Option<String>>(8)?
            .map(|s| serde_json::from_str(&s))
            .transpose()
            .map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    8,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?,
    })
}
fn week(db: &Connection, d: NaiveDate) -> Result<Week> {
    let start = monday(d);
    let end = start + Duration::days(7);
    event_range(db, start, end)
}
fn event_range(db: &Connection, start: NaiveDate, end: NaiveDate) -> Result<Week> {
    let mut stmt=db.prepare("SELECT id,title,day,start,end,color,end_day,all_day,details FROM events WHERE COALESCE(end_day,day)>=?1 AND day<?2 ORDER BY day,start,id")?;
    let events = stmt
        .query_map(params![start.to_string(), end.to_string()], event_row)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    // Preserve the day/time API: clip each overlapping event into visible daily segments.
    let mut segments = Vec::new();
    let mut events = events;
    events.extend(google::cached(db)?);
    for event in events {
        let first = date(&event.day)?;
        let last = date(event.end_day.as_deref().unwrap_or(&event.day))?;
        let mut day = first.max(start);
        while day <= last && day < end {
            // An end at midnight belongs to the previous day only.
            if day == last && day > first && event.end == "00:00" {
                break;
            }
            let mut segment = event.clone();
            let mut details = event.details.clone().unwrap_or_default();
            details.start_day = event.day.clone();
            details.start_time = event.start.clone();
            details.end_day = event.end_day.as_ref().unwrap_or(&event.day).clone();
            details.end_time = event.end.clone();
            if details.calendar_name.is_empty() {
                details.calendar_name = if event.id.starts_with("google:") {
                    "Google Calendar"
                } else {
                    "Local events"
                }
                .into();
            }
            if !event.id.starts_with("google:") {
                details.local_event = true;
                details.writable = true;
            }
            segment.details = Some(details);
            segment.day = day.to_string();
            if day > first {
                segment.start = "00:00".into();
            }
            if day < last {
                segment.end = "24:00".into();
            }
            segment.end_day = None;
            segments.push(segment);
            day += Duration::days(1);
        }
    }
    segments.sort_by(|a, b| (&a.day, &a.start, &a.id).cmp(&(&b.day, &b.start, &b.id)));
    Ok(Week {
        start: start.to_string(),
        events: segments,
        google: google::status(db)?,
        display: settings::display(db)?,
    })
}
#[derive(Serialize)]
struct MonthEvent {
    id: String,
    day: String,
    title: String,
    color: String,
}
// Month previews deliberately bypass EventDetails and the full-cache weekly path.
struct MonthSource {
    id: String,
    title: String,
    day: String,
    start: String,
    end: String,
    color: String,
    end_day: Option<String>,
}
fn month_source_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<MonthSource> {
    Ok(MonthSource {
        id: row.get(0)?,
        title: row.get(1)?,
        day: row.get(2)?,
        start: row.get(3)?,
        end: row.get(4)?,
        color: row.get(5)?,
        end_day: row.get(6)?,
    })
}
fn month(db: &Connection, d: NaiveDate) -> Result<serde_json::Value> {
    let first = d.with_day(1).ok_or("invalid month")?;
    let next = first
        .checked_add_months(chrono::Months::new(1))
        .ok_or("invalid month end")?;
    let start = monday(first);
    let end = monday(next - Duration::days(1)) + Duration::days(7);
    let range = [start.to_string(), end.to_string()];
    let mut local=db.prepare_cached("SELECT id,title,day,start,end,color,end_day FROM events WHERE COALESCE(end_day,day)>=?1 AND day<?2")?;
    let mut sources = local
        .query_map(params![range[0], range[1]], month_source_row)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut google=db.prepare_cached("SELECT json_extract(event_json,'$.id'),json_extract(event_json,'$.title'),
        json_extract(event_json,'$.day'),json_extract(event_json,'$.start'),json_extract(event_json,'$.end'),
        json_extract(event_json,'$.color'),json_extract(event_json,'$.end_day')
        FROM google_cache WHERE json_extract(event_json,'$.day')<?2
        AND COALESCE(json_extract(event_json,'$.end_day'),json_extract(event_json,'$.day'))>=?1
        AND NOT EXISTS (SELECT 1 FROM calendar_preferences p WHERE p.id=google_cache.calendar_id AND p.enabled=0)")?;
    sources.extend(
        google
            .query_map(params![range[0], range[1]], month_source_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?,
    );
    let mut segments = Vec::new();
    for source in sources {
        let first_day = date(&source.day)?;
        let last_day = date(source.end_day.as_deref().unwrap_or(&source.day))?;
        let mut day = first_day.max(start);
        while day <= last_day && day < end {
            if day == last_day && day > first_day && source.end == "00:00" {
                break;
            }
            let time = if day > first_day {
                "00:00".to_string()
            } else {
                source.start.clone()
            };
            segments.push((
                time,
                MonthEvent {
                    id: source.id.clone(),
                    day: day.to_string(),
                    title: source.title.clone(),
                    color: source.color.clone(),
                },
            ));
            day += Duration::days(1);
        }
    }
    segments.sort_by(|a, b| (&a.1.day, &a.0, &a.1.id).cmp(&(&b.1.day, &b.0, &b.1.id)));
    let events: Vec<_> = segments.into_iter().map(|(_, event)| event).collect();
    Ok(
        serde_json::json!({"month":first.to_string(),"start":range[0],"end":range[1],
        "events":events,"display":settings::display(db)?}),
    )
}
fn route(db: &Connection, method: &str, path: &str) -> (&'static str, String) {
    if method != "GET" {
        return ("405 Method Not Allowed", r#"{"error":"GET only"}"#.into());
    }
    if path == "/google/status" {
        return match google::status(db) {
            Ok(status) => ("200 OK", status.to_string()),
            Err(_) => (
                "500 Internal Server Error",
                r#"{"error":"cannot read sync status"}"#.into(),
            ),
        };
    }
    if path == "/health" {
        return ("200 OK", r#"{"ok":true}"#.into());
    }
    if let Some(s) = path.strip_prefix("/month?date=") {
        return match date(s).and_then(|d| month(db, d)) {
            Ok(value) => ("200 OK", value.to_string()),
            Err(e) => (
                "400 Bad Request",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        };
    }
    if let Some(s) = path.strip_prefix("/week?date=") {
        return match date(s).and_then(|d| week(db, d)) {
            Ok(w) => ("200 OK", serde_json::to_string(&w).unwrap()),
            Err(e) => (
                "400 Bad Request",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        };
    }
    ("404 Not Found", r#"{"error":"not found"}"#.into())
}
fn respond(db: &Connection, job: &sync_job::SyncJob, mut stream: TcpStream) -> Result<()> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(std::time::Duration::from_secs(2)))?;
    let mut req = Vec::new();
    let mut b = [0; 1];
    while req.len() < 4096 && !req.ends_with(b"\r\n\r\n") {
        if stream.read(&mut b)? == 0 {
            break;
        }
        req.push(b[0]);
    }
    let req = String::from_utf8_lossy(&req);
    let mut line = req.lines().next().unwrap_or("").split_whitespace();
    let method = line.next().unwrap_or("");
    let path = line.next().unwrap_or("");
    // The custom header prevents web pages from triggering sync through a simple cross-origin POST.
    // OPTIONS/preflight is intentionally not allowed; QML's native XHR can set this header.
    let authorized = req.lines().skip(1).any(|line| {
        line.split_once(':').is_some_and(|(k, v)| {
            k.eq_ignore_ascii_case("X-RemarkableCalendar-Request") && v.trim() == "sync"
        })
    });
    let length = req
        .lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(k, _)| k.eq_ignore_ascii_case("Content-Length"))
        .map(|(_, v)| v.trim().parse::<usize>())
        .transpose();
    let (status, body) = match length {
        Ok(length) if length.unwrap_or(0) <= 65536 && req.ends_with("\r\n\r\n") => {
            let mut body = vec![0; length.unwrap_or(0)];
            stream.read_exact(&mut body)?;
            sync_route(db, job, method, path, authorized, &body)
        }
        _ => (
            "400 Bad Request",
            serde_json::json!({"error":"Invalid or oversized request"}).to_string(),
        ),
    };
    write!(stream,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len())?;
    Ok(())
}
fn sync_route(
    db: &Connection,
    job: &sync_job::SyncJob,
    method: &str,
    path: &str,
    authorized: bool,
    body: &[u8],
) -> (&'static str, String) {
    if path == "/navigation" {
        return match method {
            "GET" => match settings::navigation(db) {
                Ok(state) => (
                    "200 OK",
                    serde_json::json!({"navigation":state}).to_string(),
                ),
                Err(e) => (
                    "500 Internal Server Error",
                    serde_json::json!({"error":e.to_string()}).to_string(),
                ),
            },
            "POST" if !authorized => (
                "403 Forbidden",
                serde_json::json!({"error":"Request header required"}).to_string(),
            ),
            "POST" => match serde_json::from_slice::<settings::Navigation>(body)
                .map_err(Into::into)
                .and_then(|state| settings::save_navigation(db, &state))
            {
                Ok(()) => ("200 OK", r#"{"ok":true}"#.into()),
                Err(e) => (
                    "400 Bad Request",
                    serde_json::json!({"error":e.to_string()}).to_string(),
                ),
            },
            _ => (
                "405 Method Not Allowed",
                serde_json::json!({"error":"GET or POST only"}).to_string(),
            ),
        };
    }
    if method == "GET" && path.starts_with("/events/item?") {
        let result = reqwest::Url::parse(&format!("http://localhost{path}"))
            .map_err(|e| e.into())
            .and_then(|url| {
                let id = url
                    .query_pairs()
                    .find(|(k, _)| k == "id")
                    .map(|(_, v)| v.into_owned())
                    .ok_or("Event id required")?;
                edits::item(db, &id)
            });
        return match result {
            Ok(event) => ("200 OK", serde_json::to_string(&event).unwrap()),
            Err(e) => (
                "404 Not Found",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        };
    }
    if path == "/events/pending" && method == "GET" {
        return match edits::pending(db) {
            Ok(items) => ("200 OK", items.to_string()),
            Err(e) => (
                "500 Internal Server Error",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        };
    }
    if path == "/events/change" {
        if method != "POST" {
            return (
                "405 Method Not Allowed",
                serde_json::json!({"error":"POST only"}).to_string(),
            );
        }
        if !authorized {
            return (
                "403 Forbidden",
                serde_json::json!({"error":"Request header required"}).to_string(),
            );
        }
        if job.status().state == "running" {
            return (
                "409 Conflict",
                serde_json::json!({"error":"Wait for sync to finish before changing events"})
                    .to_string(),
            );
        }
        let result = serde_json::from_slice::<edits::Change>(body)
            .map_err(|e| e.into())
            .and_then(|c| {
                let mut writer = database(std::path::Path::new(
                    db.path().ok_or("Database unavailable")?,
                ))?;
                edits::apply(&mut writer, &c)
            });
        return match result {
            Ok(value) => ("200 OK", value.to_string()),
            Err(e) => (
                "400 Bad Request",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        };
    }
    if path == "/settings" {
        return match method {
            "GET" => match settings::response(db) {
                Ok(value) => ("200 OK", value.to_string()),
                Err(_) => (
                    "500 Internal Server Error",
                    serde_json::json!({"error":"Could not read settings"}).to_string(),
                ),
            },
            "POST" if !authorized => (
                "403 Forbidden",
                serde_json::json!({"error":"Request header required"}).to_string(),
            ),
            "POST" if job.status().state == "running" => (
                "409 Conflict",
                serde_json::json!({"error":"Wait for sync to finish before saving settings"})
                    .to_string(),
            ),
            "POST" => match serde_json::from_slice::<settings::Settings>(body)
                .map_err(|e| e.into())
                .and_then(|s| settings::save(db, &s))
            {
                Ok(()) => ("200 OK", serde_json::json!({"ok":true}).to_string()),
                Err(e) => (
                    "400 Bad Request",
                    serde_json::json!({"error":e.to_string()}).to_string(),
                ),
            },
            _ => (
                "405 Method Not Allowed",
                serde_json::json!({"error":"GET or POST only"}).to_string(),
            ),
        };
    }
    if path == "/google/calendars/refresh" {
        return match method {
            "POST" if authorized => match job.discover(db) {
                Ok(_) => (
                    "202 Accepted",
                    serde_json::to_string(&job.status()).unwrap(),
                ),
                Err(e) => (
                    "409 Conflict",
                    serde_json::json!({"error":e.to_string()}).to_string(),
                ),
            },
            "POST" => (
                "403 Forbidden",
                serde_json::json!({"error":"Request header required"}).to_string(),
            ),
            _ => (
                "405 Method Not Allowed",
                serde_json::json!({"error":"POST only"}).to_string(),
            ),
        };
    }
    if path != "/google/sync" {
        return route(db, method, path);
    }
    match method {
        "GET" => ("200 OK", serde_json::to_string(&job.status()).unwrap()),
        "POST" if !authorized => (
            "403 Forbidden",
            serde_json::json!({"error":"Sync request header required"}).to_string(),
        ),
        "POST" => match job.start(db) {
            Ok(started) => (
                if started { "202 Accepted" } else { "200 OK" },
                serde_json::to_string(&job.status()).unwrap(),
            ),
            Err(e) => (
                "409 Conflict",
                serde_json::json!({"error":e.to_string()}).to_string(),
            ),
        },
        _ => (
            "405 Method Not Allowed",
            serde_json::json!({"error":"GET or POST only"}).to_string(),
        ),
    }
}
fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let path = env::var_os("REMARKABLE_CALENDAR_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_else(|| ".".into()))
                .join(".local/share/remarkable-calendar/events.sqlite3")
        });
    let mut db = database(&path)?;
    let cmd = args.first().map(String::as_str).unwrap_or("");
    match cmd {
        "google-calendars" => google::calendars()?,
        "google-sync" => {
            edits::flush(&mut db, |_| {})?;
            google::sync(&mut db, &args[1..])?;
        }
        "google-status" => println!("{}", google::status(&db)?),
        "import" => {
            let events: Vec<Event> =
                serde_json::from_slice(&fs::read(args.get(1).ok_or("import needs JSON file")?)?)?;
            import(&mut db, &events)?;
            eprintln!("Imported {} events into {}", events.len(), path.display());
        }
        "delete" => {
            let id = args.get(1).ok_or("delete needs id")?;
            eprintln!(
                "Deleted {}",
                db.execute("DELETE FROM events WHERE id=?1", [id])?
            );
        }
        "export" => {
            let mut stmt = db.prepare(
                "SELECT id,title,day,start,end,color,end_day,all_day,details FROM events ORDER BY day,start,id",
            )?;
            let events = stmt
                .query_map([], event_row)?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            println!("{}", serde_json::to_string_pretty(&events)?);
        }
        "serve" => serve(db, None)?,
        s if s.starts_with('/') => serve(db, Some(s))?,
        _ => {
            let d = if cmd.is_empty() {
                Local::now().date_naive()
            } else {
                date(cmd)?
            };
            println!("{}", serde_json::to_string_pretty(&week(&db, d)?)?);
        }
    }
    Ok(())
}
fn serve(db: Connection, socket: Option<&str>) -> Result<()> {
    // Bind before announcing readiness to AppLoad. A duplicate must fail, never adopt/kill another server.
    let listener = TcpListener::bind("127.0.0.1:38765")?;
    let _lifecycle = socket.map(lifecycle::connect).transpose()?;
    let sync_job = sync_job::SyncJob::default();
    if settings::should_auto_sync(&db, chrono::Utc::now()).unwrap_or(false) {
        if let Err(e) = sync_job.start(&db) {
            eprintln!("Automatic sync: {e}");
        }
    }
    eprintln!("reMarkable Calendar ready; loopback HTTP on 38765");
    for conn in listener.incoming() {
        match conn {
            Ok(s) => {
                if let Err(e) = respond(&db, &sync_job, s) {
                    eprintln!("request: {e}");
                }
            }
            Err(e) => eprintln!("accept: {e}"),
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn month_grid_and_event_segments() -> Result<()> {
        let mut db = database(std::path::Path::new(":memory:"))?;
        let events: Vec<Event> = serde_json::from_value(serde_json::json!([
            {"id":"overnight","title":"Overnight","day":"2026-10-31","start":"23:00","end":"00:00","end_day":"2026-11-02","color":"#123456"},
            {"id":"all-day","title":"Trip","day":"2026-11-02","start":"00:00","end":"00:00","end_day":"2026-11-04","all_day":true,"color":"#654321"},
            {"id":"last","title":"Last grid day","day":"2026-12-06","start":"09:00","end":"10:00","color":"#123456"},
            {"id":"outside","title":"Outside","day":"2026-12-07","start":"09:00","end":"10:00","color":"#123456"}
        ]))?;
        import(&mut db, &events)?;
        let result = month(&db, date("2026-11-20")?)?;
        assert_eq!(result["month"], "2026-11-01");
        assert_eq!(result["start"], "2026-10-26");
        assert_eq!(result["end"], "2026-12-07");
        let rows = result["events"].as_array().unwrap();
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0]["day"], "2026-10-31");
        assert_eq!(rows[1]["day"], "2026-11-01");
        assert!(rows.iter().all(|row| row.as_object().unwrap().len() == 4));
        assert!(rows[1].get("details").is_none());
        assert_eq!(rows[2]["title"], "Trip");
        assert_eq!(rows[4]["id"], "last");
        let february = month(&db, date("2021-02-01")?)?;
        assert_eq!(february["start"], "2021-02-01");
        assert_eq!(february["end"], "2021-03-01");
        assert!(february["events"].as_array().unwrap().is_empty());
        // Compact Google previews must match the full weekly segmentation and visibility rules.
        let mut cached = events[0].clone();
        cached.id = "google:work:overnight".into();
        cached.details = Some(EventDetails {
            description: "Large description".repeat(4096),
            pending: true,
            ..Default::default()
        });
        db.execute(
            "INSERT INTO google_cache VALUES ('work',?1,?2)",
            params![cached.id, serde_json::to_string(&cached)?],
        )?;
        db.execute("INSERT INTO calendar_preferences (id,name,color,enabled) VALUES ('work','Work','#123456',1)",[])?;
        for enabled in [1, 0] {
            db.execute(
                "UPDATE calendar_preferences SET enabled=?1 WHERE id='work'",
                [enabled],
            )?;
            let compact = month(&db, date("2026-11-01")?)?;
            let expected: Vec<_> = event_range(&db, date("2026-10-26")?, date("2026-12-07")?)?
                .events
                .into_iter()
                .map(|e| serde_json::json!({"id":e.id,"day":e.day,"title":e.title,"color":e.color}))
                .collect();
            assert_eq!(compact["events"], serde_json::json!(expected));
            assert!(serde_json::to_vec(&compact)?.len() < 8192);
        }

        assert_eq!(
            route(&db, "GET", "/month?date=2026-02-30").0,
            "400 Bad Request"
        );
        Ok(())
    }
    #[test]
    fn boundaries_and_persistence() -> Result<()> {
        let p = env::temp_dir().join(format!(
            "remarkable-calendar-test-{}.sqlite",
            std::process::id()
        ));
        // Open a pre-upgrade database through the actual migration path.
        let legacy = Connection::open(&p)?;
        legacy.execute_batch("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,day TEXT NOT NULL,start TEXT NOT NULL,end TEXT NOT NULL,color TEXT NOT NULL);")?;
        drop(legacy);
        let mut db = database(&p)?;
        let events: Vec<Event> = ["2025-12-28", "2025-12-29", "2026-01-04", "2026-01-05"]
            .iter()
            .enumerate()
            .map(|(i, d)| Event {
                id: i.to_string(),
                title: "Test".into(),
                day: d.to_string(),
                start: "09:00".into(),
                end: "10:00".into(),
                color: "#111111".into(),
                end_day: None,
                all_day: false,
                details: None,
            })
            .collect();
        import(&mut db, &events)?;
        drop(db);
        let mut db = database(&p)?;
        assert_eq!(monday(date("2026-01-04")?).to_string(), "2025-12-29");
        assert_eq!(monday(date("2026-10-26")?).to_string(), "2026-10-26");
        let w = week(&db, date("2026-01-01")?)?;
        assert_eq!(
            w.events.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            vec!["1", "2"]
        );
        assert_eq!(week(&db, date("2026-01-05")?)?.events.len(), 1);
        assert!(week(&db, date("2026-02-01")?)?.events.is_empty());
        import(&mut db, &events)?;
        assert_eq!(week(&db, date("2026-01-01")?)?.events.len(), 2);
        let mut bad = events;
        bad[1].day = "invalid".into();
        assert!(import(&mut db, &bad).is_err());
        assert_eq!(route(&db, "GET", "/week?date=bad").0, "400 Bad Request");
        assert_eq!(route(&db, "POST", "/health").0, "405 Method Not Allowed");
        drop(db);
        fs::remove_file(p)?;
        Ok(())
    }
    #[test]
    fn multi_day_overlap_and_midnight() -> Result<()> {
        let mut db = Connection::open_in_memory()?;
        db.execute_batch("CREATE TABLE events (id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,day TEXT NOT NULL,start TEXT NOT NULL,end TEXT NOT NULL,color TEXT NOT NULL);
            INSERT INTO events VALUES ('legacy','Legacy','2026-12-29','09:00','10:00','#111111');
            ALTER TABLE events ADD COLUMN end_day TEXT;")?;
        db.execute_batch("ALTER TABLE events ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0;")?;
        db.execute_batch("ALTER TABLE events ADD COLUMN details TEXT;")?;
        google::init(&db)?;
        let mut event = Event {
            id: "trip".into(),
            title: "Trip".into(),
            day: "2026-12-27".into(),
            start: "22:00".into(),
            end: "10:00".into(),
            color: "#111111".into(),
            end_day: Some("2027-01-05".into()),
            all_day: false,
            details: None,
        };
        import(&mut db, &[event.clone()])?;
        let current = week(&db, date("2027-01-01")?)?;
        assert_eq!(current.events.iter().filter(|e| e.id == "trip").count(), 7);
        assert!(current.events.iter().any(|e| e.id == "legacy"));
        assert_eq!(current.events[0].start, "00:00");
        assert_eq!(current.events[0].end, "24:00");
        let next = week(&db, date("2027-01-04")?)?;
        assert_eq!(next.events.len(), 2);
        assert_eq!(next.events[1].end, "10:00");
        event.end_day = Some("2027-01-04".into());
        event.end = "00:00".into();
        import(&mut db, &[event.clone()])?;
        assert!(week(&db, date("2027-01-04")?)?.events.is_empty());
        event.end_day = Some("2026-12-26".into());
        assert!(import(&mut db, &[event]).is_err());
        Ok(())
    }
    #[test]
    fn offline_details_and_original_span() -> Result<()> {
        let path = env::temp_dir().join(format!(
            "remarkable-calendar-details-{}.sqlite",
            std::process::id()
        ));
        let mut db = database(&path)?;
        let event = Event {
            id: "trip".into(),
            title: "Trip".into(),
            day: "2026-11-01".into(),
            start: "22:00".into(),
            end: "02:00".into(),
            end_day: Some("2026-11-02".into()),
            all_day: false,
            color: "#112233".into(),
            details: Some(EventDetails {
                location: "Room A".into(),
                description: "Offline notes".into(),
                calendar_name: "Travel".into(),
                ..Default::default()
            }),
        };
        import(&mut db, &[event])?;
        drop(db);
        let db = database(&path)?;
        let w = week(&db, date("2026-11-02")?)?;
        assert_eq!(w.events[0].start, "00:00");
        let d = w.events[0].details.as_ref().unwrap();
        assert_eq!(
            (&*d.start_day, &*d.start_time, &*d.end_day, &*d.end_time),
            ("2026-11-01", "22:00", "2026-11-02", "02:00")
        );
        assert_eq!(
            (&*d.location, &*d.description, &*d.calendar_name),
            ("Room A", "Offline notes", "Travel")
        );
        drop(db);
        fs::remove_file(path)?;
        Ok(())
    }
    #[test]
    fn leap_and_sunday() -> Result<()> {
        assert_eq!(monday(date("2024-03-03")?).to_string(), "2024-02-26");
        assert!(date("2026-02-29").is_err());
        Ok(())
    }
}
