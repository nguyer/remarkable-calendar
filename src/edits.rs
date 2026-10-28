//! Offline-first event edits. Cached Google changes stay overlaid until an acknowledged write.
use crate::{date, google, import, settings, validate, Event, EventDetails, Result};
use chrono::{NaiveTime, TimeZone};
use chrono_tz::Tz;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Read;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub operation: String,
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub calendar_id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub start_day: String,
    #[serde(default)]
    pub start_time: String,
    #[serde(default)]
    pub end_day: String,
    #[serde(default)]
    pub end_time: String,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub description: String,
}
pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS event_outbox (id TEXT PRIMARY KEY,calendar_id TEXT NOT NULL,event_id TEXT NOT NULL,operation TEXT NOT NULL,event_json TEXT NOT NULL,base_json TEXT,etag TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',attempted INTEGER NOT NULL DEFAULT 0);")?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS editor_preferences (id INTEGER PRIMARY KEY CHECK(id=1),last_calendar TEXT NOT NULL);")?;
    Ok(())
}
pub fn last_calendar(db: &Connection) -> Result<Option<String>> {
    Ok(db
        .query_row(
            "SELECT last_calendar FROM editor_preferences WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional()?)
}
pub fn count(db: &Connection) -> Result<i64> {
    Ok(db.query_row("SELECT count(*) FROM event_outbox", [], |r| r.get(0))?)
}
pub fn pending(db: &Connection) -> Result<Value> {
    let mut stmt =
        db.prepare("SELECT id,operation,event_json,error FROM event_outbox ORDER BY rowid")?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let items = rows
        .into_iter()
        .map(|(id, operation, json, error)| {
            let event: Event = serde_json::from_str(&json)?;
            Ok(serde_json::json!({"id":id,"operation":operation,"title":event.title,"error":error}))
        })
        .collect::<Result<Vec<Value>>>()?;
    Ok(Value::Array(items))
}
pub fn random_id() -> Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(format!(
        "r{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ))
}
fn cached(db: &Connection, id: &str) -> Result<Option<(String, Event)>> {
    let row = db
        .query_row(
            "SELECT calendar_id,event_json FROM google_cache WHERE event_id=?1",
            [id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()?;
    row.map(|(calendar, json)| Ok((calendar, serde_json::from_str(&json)?)))
        .transpose()
}
fn local(db: &Connection, id: &str) -> Result<Option<Event>> {
    db.query_row(
        "SELECT id,title,day,start,end,color,end_day,all_day,details FROM events WHERE id=?1",
        [id],
        crate::event_row,
    )
    .optional()
    .map_err(Into::into)
}
pub fn item(db: &Connection, id: &str) -> Result<Event> {
    let mut e = if let Some((_, event)) = cached(db, id)? {
        event
    } else {
        local(db, id)?.ok_or("Event not found")?
    };
    let mut d = e.details.take().unwrap_or_default();
    d.start_day = e.day.clone();
    d.start_time = e.start.clone();
    d.end_day = e.end_day.as_ref().unwrap_or(&e.day).clone();
    d.end_time = e.end.clone();
    if !id.starts_with("google:") {
        d.local_event = true;
        d.writable = true;
        d.calendar_name = "Local events".into();
    }
    let pending = db
        .query_row("SELECT error FROM event_outbox WHERE id=?1", [id], |r| {
            r.get::<_, String>(0)
        })
        .optional()?;
    d.pending = pending.is_some();
    d.sync_error = pending.unwrap_or_default();
    e.details = Some(d);
    Ok(e)
}
fn role(db: &Connection, calendar: &str) -> Result<(String, String)> {
    let data = db
        .query_row(
            "SELECT name,color,access_role FROM calendar_preferences WHERE id=?1 AND available=1",
            [calendar],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?
        .ok_or("Calendar unavailable; Refresh list in Settings first")?;
    if !["owner", "writer"].contains(&data.2.as_str()) {
        return Err("Calendar is read-only or its permission is unknown. Refresh list online before editing".into());
    }
    Ok((data.0, data.1))
}
fn make_event(c: &Change, id: String, color: String, mut details: EventDetails) -> Result<Event> {
    details.location = c.location.clone();
    details.description = c.description.clone();
    details.start_day = c.start_day.clone();
    details.end_day = c.end_day.clone();
    details.start_time = if c.all_day {
        "00:00".into()
    } else {
        c.start_time.clone()
    };
    details.end_time = if c.all_day {
        "00:00".into()
    } else {
        c.end_time.clone()
    };
    let e = Event {
        id,
        title: c.title.clone(),
        day: c.start_day.clone(),
        start: details.start_time.clone(),
        end: details.end_time.clone(),
        color,
        end_day: Some(c.end_day.clone()),
        all_day: c.all_day,
        details: Some(details),
    };
    validate(&e)?;
    if c.location.len() > 8192 || c.description.len() > 32000 {
        return Err("Location or description is too long".into());
    }
    // Validate IANA/DST boundaries now, before accepting a Google edit offline.
    if !e.details.as_ref().unwrap().local_event {
        payload(&e)?;
    }
    Ok(e)
}
pub fn apply(db: &mut Connection, c: &Change) -> Result<Value> {
    let result = apply_change(db, c)?;
    if ["create", "update"].contains(&c.operation.as_str()) {
        if let Some(event) = result.get("event") {
            let calendar = if event["details"]["local_event"] == true {
                "local"
            } else {
                event["details"]["calendar_id"]
                    .as_str()
                    .unwrap_or(&c.calendar_id)
            };
            if !calendar.is_empty() {
                // The event is already committed: preference failure must not misreport its save.
                if let Err(error)=db.execute("INSERT INTO editor_preferences VALUES (1,?1) ON CONFLICT(id) DO UPDATE SET last_calendar=excluded.last_calendar",[calendar]) {eprintln!("Could not remember editor calendar: {error}");}
            }
        }
    }
    Ok(result)
}
fn apply_change(db: &mut Connection, c: &Change) -> Result<Value> {
    if c.operation == "discard" {
        discard(db, &c.id)?;
        return Ok(serde_json::json!({"ok":true}));
    }
    if !["create", "update", "delete"].contains(&c.operation.as_str()) {
        return Err("Unknown event action".into());
    }
    if c.operation != "create" && c.id.is_empty() {
        return Err("Event id required".into());
    }
    let existing = if c.operation == "create" {
        None
    } else {
        cached(db, &c.id)?
    };
    if c.operation == "create" && !c.id.is_empty() {
        if c.id.len() != 33
            || !c.id.starts_with('r')
            || !c.id[1..]
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err("Invalid new-event identifier".into());
        }
        let full = if c.calendar_id == "local" {
            c.id.clone()
        } else {
            format!("google:{}:{}:{}", c.calendar_id.len(), c.calendar_id, c.id)
        };
        if let Ok(event) = item(db, &full) {
            let d = event.details.as_ref().unwrap();
            if event.title != c.title
                || event.day != c.start_day
                || event.end_day.as_deref().unwrap_or(&event.day) != c.end_day
                || event.all_day != c.all_day
                || d.location != c.location
                || d.description != c.description
                || (!c.all_day && (event.start != c.start_time || event.end != c.end_time))
            {
                return Err(
                    "This creation was already saved. Reopen the event before changing it".into(),
                );
            }
            return Ok(serde_json::json!({"event":event,"queued":d.pending}));
        }
        let pending: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM event_outbox WHERE id=?1)",
            [&full],
            |r| r.get(0),
        )?;
        if pending {
            return Err("A deletion of this event is pending. Reopen the calendar before creating another event".into());
        }
    }
    if c.operation == "create" && c.calendar_id == "local"
        || existing.is_none() && c.operation != "create"
    {
        let old = if c.operation == "create" {
            None
        } else {
            Some(local(db, &c.id)?.ok_or("Event not found; refresh the view")?)
        };
        if c.operation == "delete" {
            db.execute("DELETE FROM events WHERE id=?1", [&c.id])?;
            return Ok(serde_json::json!({"ok":true,"queued":false}));
        }
        let id = if let Some(event) = &old {
            event.id.clone()
        } else if !c.id.is_empty() {
            c.id.clone()
        } else {
            random_id()?
        };
        let mut details = old
            .as_ref()
            .and_then(|e| e.details.clone())
            .unwrap_or_default();
        details.calendar_name = "Local events".into();
        details.local_event = true;
        details.writable = true;
        let event = make_event(
            c,
            id,
            old.map(|e| e.color).unwrap_or_else(|| "#55778b".into()),
            details,
        )?;
        import(db, std::slice::from_ref(&event))?;
        return Ok(serde_json::json!({"event":event,"queued":false}));
    }
    let calendar = existing
        .as_ref()
        .map(|e| e.0.as_str())
        .unwrap_or(&c.calendar_id)
        .to_owned();
    let (name, color) = role(db, &calendar)?;
    let prior = db
        .query_row(
            "SELECT operation,base_json,etag,attempted FROM event_outbox WHERE id=?1",
            [&c.id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, bool>(3)?,
                ))
            },
        )
        .optional()?;
    let event_id = if let Some((_, old)) = &existing {
        old.id
            .strip_prefix(&format!("google:{}:{}:", calendar.len(), calendar))
            .ok_or("Invalid Google event id")?
            .to_owned()
    } else if !c.id.is_empty() {
        c.id.clone()
    } else {
        random_id()?
    };
    let id = format!("google:{}:{}:{}", calendar.len(), calendar, event_id);
    let base = existing
        .as_ref()
        .map(|e| serde_json::to_string(&e.1))
        .transpose()?;
    let mut details = existing
        .as_ref()
        .and_then(|e| e.1.details.clone())
        .unwrap_or_default();
    let is_new = prior.as_ref().is_some_and(|p| p.0 == "create") || c.operation == "create";
    if !is_new && details.etag.is_empty() {
        return Err("Sync once online to fetch the event version before editing offline".into());
    }
    let etag = prior
        .as_ref()
        .map(|p| p.2.clone())
        .unwrap_or_else(|| details.etag.clone());
    details.calendar_id = calendar.clone();
    details.event_id = event_id.clone();
    details.calendar_name = name;
    details.timezone = settings::read(db)?.timezone;
    details.writable = true;
    details.pending = true;
    let event = if c.operation == "delete" {
        existing.as_ref().unwrap().1.clone()
    } else {
        make_event(
            c,
            id.clone(),
            existing
                .as_ref()
                .map(|e| e.1.color.clone())
                .unwrap_or(color),
            details,
        )?
    };
    let tx = db.transaction()?;
    if c.operation == "delete" && is_new && !prior.as_ref().is_some_and(|p| p.3) {
        tx.execute("DELETE FROM event_outbox WHERE id=?1", [&id])?;
    } else {
        let operation = if c.operation == "delete" {
            "delete"
        } else if is_new {
            "create"
        } else {
            "update"
        };
        let original = prior.as_ref().map(|p| p.1.clone()).unwrap_or(base);
        tx.execute("INSERT INTO event_outbox (id,calendar_id,event_id,operation,event_json,base_json,etag) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET operation=excluded.operation,event_json=excluded.event_json,error=''",params![id,calendar,event_id,operation,serde_json::to_string(&event)?,original,etag])?;
    }
    if c.operation == "delete" {
        tx.execute("DELETE FROM google_cache WHERE event_id=?1", [&id])?;
    } else {
        tx.execute("INSERT INTO google_cache VALUES (?1,?2,?3) ON CONFLICT(calendar_id,event_id) DO UPDATE SET event_json=excluded.event_json",params![calendar,id,serde_json::to_string(&event)?])?;
    }
    tx.commit()?;
    Ok(if c.operation == "delete" {
        serde_json::json!({"ok":true,"queued":!is_new})
    } else {
        serde_json::json!({"event":event,"queued":true})
    })
}
fn discard(db: &mut Connection, id: &str) -> Result<()> {
    let tx = db.transaction()?;
    let (calendar, base) = tx.query_row(
        "SELECT calendar_id,base_json FROM event_outbox WHERE id=?1",
        [id],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
    )?;
    tx.execute("DELETE FROM google_cache WHERE event_id=?1", [id])?;
    if let Some(base) = base {
        tx.execute(
            "INSERT INTO google_cache VALUES (?1,?2,?3)",
            params![calendar, id, base],
        )?;
    }
    tx.execute("DELETE FROM event_outbox WHERE id=?1", [id])?;
    tx.commit()?;
    Ok(())
}
fn payload(event: &Event) -> Result<Value> {
    let d = event.details.as_ref().ok_or("Missing event details")?;
    let start = date(&event.day)?;
    let end = date(event.end_day.as_deref().unwrap_or(&event.day))?;
    let (a, b) = if event.all_day {
        (
            serde_json::json!({"date":start.to_string()}),
            serde_json::json!({"date":end.to_string()}),
        )
    } else {
        let tz: Tz = d.timezone.parse()?;
        let datetime = |date: chrono::NaiveDate, time: &str| -> Result<String> {
            let time = NaiveTime::parse_from_str(time, "%H:%M")?;
            Ok(tz.from_local_datetime(&date.and_time(time)).single().ok_or("This time is ambiguous or does not exist due to daylight saving; choose another time")?.to_rfc3339())
        };
        (
            serde_json::json!({"dateTime":datetime(start,&event.start)?,"timeZone":d.timezone}),
            serde_json::json!({"dateTime":datetime(end,&event.end)?,"timeZone":d.timezone}),
        )
    };
    Ok(
        serde_json::json!({"summary":event.title,"start":a,"end":b,"location":d.location,"description":d.description}),
    )
}
pub fn flush(db: &mut Connection, progress: impl FnMut(&str)) -> Result<()> {
    if count(db)? == 0 {
        return Ok(());
    }
    let (client, token) = google::client_and_token()?;
    flush_with(
        db,
        &client,
        &token,
        "https://www.googleapis.com/calendar/v3",
        progress,
    )
}
fn confirm_calendar_access(
    client: &reqwest::blocking::Client,
    token: &str,
    api: &str,
    calendar: &str,
) -> Result<()> {
    let check = client
        .get(format!("{api}/{}", google::calendar_path(calendar)))
        .bearer_auth(token)
        .send()?;
    if !check.status().is_success() {
        return Err(
            "Calendar is unavailable; the deletion remains queued until access can be confirmed"
                .into(),
        );
    }
    Ok(())
}
fn flush_with(
    db: &mut Connection,
    client: &reqwest::blocking::Client,
    token: &str,
    api: &str,
    mut progress: impl FnMut(&str),
) -> Result<()> {
    let mut stmt=db.prepare("SELECT id,calendar_id,event_id,operation,event_json,base_json,etag FROM event_outbox ORDER BY rowid")?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, Option<String>>(5)?,
                r.get::<_, String>(6)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    drop(stmt);
    if rows.is_empty() {
        return Ok(());
    }
    for (id, calendar, remote, operation, json, base, etag) in rows {
        progress("Sending saved event changes…");
        let event: Event = serde_json::from_str(&json)?;
        db.execute("UPDATE event_outbox SET attempted=1 WHERE id=?1", [&id])?;
        let result = (|| -> Result<Option<Value>> {
            let path = format!("{}/events", google::calendar_path(&calendar));
            let mut request = match operation.as_str() {
                "create" => {
                    let mut body = payload(&event)?;
                    body["id"] = Value::String(remote.clone());
                    client.post(format!("{api}/{path}")).json(&body)
                }
                "update" => {
                    let body = payload(&event)?;
                    // Only patch changed fields; retain attendees, recurrence, colors and rich descriptions when unchanged.
                    let mut patch = serde_json::Map::new();
                    let original = base
                        .as_deref()
                        .map(serde_json::from_str::<Event>)
                        .transpose()?
                        .map(|e| payload(&e))
                        .transpose()?;
                    for (key, value) in body.as_object().unwrap() {
                        if original.as_ref().and_then(|v| v.get(key)) != Some(value) {
                            patch.insert(key.clone(), value.clone());
                        }
                    }
                    client
                        .patch(format!("{api}/{path}/{}", google::encode_segment(&remote)))
                        .header("If-Match", &etag)
                        .json(&patch)
                }
                "delete" => {
                    let url = format!("{api}/{path}/{}", google::encode_segment(&remote));
                    let mut version = etag.clone();
                    if version.is_empty() {
                        let check = client.get(&url).bearer_auth(token).send()?;
                        if [404, 410].contains(&check.status().as_u16()) {
                            if check.status().as_u16() == 404 {
                                confirm_calendar_access(client, token, api, &calendar)?;
                            }
                            return Ok(None);
                        }
                        if !check.status().is_success() {
                            return Err("Could not verify the pending created event before deleting; retry sync".into());
                        }
                        let raw: Value = check.json()?;
                        version = raw["etag"]
                            .as_str()
                            .ok_or("Google event version unavailable")?
                            .into();
                    }
                    client.delete(url).header("If-Match", version)
                }
                _ => return Err("Invalid saved change".into()),
            };
            request = request.bearer_auth(token).query(&[("sendUpdates", "none")]);
            let response = request.send().map_err(|_|"Cannot reach Google. This change remains saved on the tablet; retry Sync when connected")?;
            let status = response.status();
            if operation == "delete"
                && (status.is_success() || status.as_u16() == 404 || status.as_u16() == 410)
            {
                if status.as_u16() == 404 {
                    confirm_calendar_access(client, token, api, &calendar)?;
                }
                return Ok(None);
            }
            if !status.is_success() {
                return Err(match status.as_u16(){
                412=>"Conflict: Google has a newer version. Review Pending changes in Settings; discard this local change and sync before editing again".to_owned(),
                409=>"The event ID already exists, possibly from a previously completed save. Review Pending changes and sync; no duplicate event was created".to_owned(),
                401|403=>"Google rejected this change. Upgrade sign-in to Calendar event editing permission and check calendar access".to_owned(),
                _=>format!("Google save failed (HTTP {status}); local change remains pending"),
            }.into());
            }
            Ok(Some(response.json()?))
        })();
        match result {
            Ok(raw) => {
                let tx = db.transaction()?;
                if let Some(raw) = raw {
                    let tz: Tz = event.details.as_ref().unwrap().timezone.parse()?;
                    let mut confirmed = google::convert(&raw, &calendar, &event.color, tz)?
                        .ok_or("Google returned a cancelled saved event")?;
                    if let Some(d) = confirmed.details.as_mut() {
                        d.writable = true;
                        d.calendar_name = event.details.as_ref().unwrap().calendar_name.clone();
                    }
                    tx.execute("INSERT INTO google_cache VALUES (?1,?2,?3) ON CONFLICT(calendar_id,event_id) DO UPDATE SET event_json=excluded.event_json",params![calendar,id,serde_json::to_string(&confirmed)?])?;
                }
                tx.execute("DELETE FROM event_outbox WHERE id=?1", [&id])?;
                tx.commit()?;
            }
            Err(error) => {
                db.execute(
                    "UPDATE event_outbox SET error=?1 WHERE id=?2",
                    params![error.to_string(), id],
                )?;
                return Err(error);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn mock(status: u16, echo: bool) -> std::io::Result<(String, std::thread::JoinHandle<String>)> {
        use std::{
            io::Write,
            net::TcpListener,
            time::{Duration, Instant},
        };
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = format!("http://{}", listener.local_addr()?);
        listener.set_nonblocking(true)?;
        let task = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(4);
            let mut stream = loop {
                match listener.accept() {
                    Ok((s, _)) => break s,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "mock request timed out");
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("{e}"),
                }
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut bytes = vec![];
            let mut byte = [0u8; 1];
            while !bytes.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                bytes.push(byte[0]);
            }
            let headers = String::from_utf8(bytes).unwrap();
            let length = headers
                .lines()
                .filter_map(|l| l.split_once(':'))
                .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                .map(|(_, v)| v.trim().parse::<usize>().unwrap())
                .unwrap_or(0);
            let mut body = vec![0u8; length];
            stream.read_exact(&mut body).unwrap();
            let mut response = if echo {
                serde_json::from_slice::<Value>(&body).unwrap()
            } else {
                serde_json::json!({})
            };
            if echo {
                response["etag"] = Value::String("\"v2\"".into());
            }
            let response = response.to_string();
            write!(stream,"HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",response.len()).unwrap();
            format!("{headers}{}", String::from_utf8(body).unwrap())
        });
        Ok((address, task))
    }
    #[test]
    fn conditional_patch_conflict_keeps_local_change() -> Result<()> {
        let (api, server) = match mock(412, false) {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                eprintln!("SKIP: host blocks local mock HTTP");
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };
        let mut db = fixture()?;
        let raw = serde_json::json!({"id":"remote","etag":"\"v1\"","summary":"Original","start":{"dateTime":"2026-11-01T09:00:00-06:00"},"end":{"dateTime":"2026-11-01T10:00:00-06:00"}});
        let original =
            google::convert(&raw, "work", "#112233", "America/Guatemala".parse()?)?.unwrap();
        google::store(
            &mut db,
            "work",
            std::slice::from_ref(&original),
            "min",
            "max",
            "America/Guatemala",
        )?;
        let mut c = change("update");
        c.id = original.id.clone();
        apply(&mut db, &c)?;
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(2))
            .build()?;
        assert!(flush_with(&mut db, &client, "test-only", &api, |_| {})
            .unwrap_err()
            .to_string()
            .contains("Conflict"));
        let request = server.join().unwrap();
        assert!(request.starts_with("PATCH /calendars/work/events/remote?"));
        assert!(request.to_ascii_lowercase().contains("if-match: \"v1\""));
        let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap())?;
        assert_eq!(body["summary"], "Draft");
        assert!(body.get("start").is_none());
        assert!(body.get("attendees").is_none());
        assert!(body.get("colorId").is_none());
        assert_eq!(count(&db)?, 1);
        assert_eq!(item(&db, &c.id)?.title, "Draft");
        assert!(pending(&db)?[0]["error"]
            .as_str()
            .unwrap()
            .contains("Conflict"));
        Ok(())
    }
    #[test]
    fn acknowledged_create_and_delete_clear_queue() -> Result<()> {
        let (api, server) = match mock(200, true) {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                eprintln!("SKIP: host blocks local mock HTTP");
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };
        let mut db = fixture()?;
        let mut c = change("create");
        c.id = random_id()?;
        let creation = c.clone();
        let created = apply(&mut db, &c)?;
        let replay = apply(&mut db, &creation)?;
        assert_eq!(created["event"]["id"], replay["event"]["id"]);
        let mut changed_retry = creation;
        changed_retry.title = "Different retry".into();
        assert!(apply(&mut db, &changed_retry).is_err());
        c.id = created["event"]["id"].as_str().unwrap().into();
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(2))
            .build()?;
        flush_with(&mut db, &client, "test-only", &api, |_| {})?;
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /calendars/work/events?"));
        let body: Value = serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap())?;
        assert!(body["id"].as_str().unwrap().starts_with('r'));
        assert_eq!(count(&db)?, 0);
        assert!(!item(&db, &c.id)?.details.unwrap().pending);
        c.operation = "delete".into();
        apply(&mut db, &c)?;
        let (api, server) = mock(204, false)?;
        flush_with(&mut db, &client, "test-only", &api, |_| {})?;
        let request = server.join().unwrap();
        assert!(request.starts_with("DELETE /calendars/work/events/"));
        assert!(request.to_ascii_lowercase().contains("if-match: \"v2\""));
        assert_eq!(count(&db)?, 0);
        assert!(cached(&db, &c.id)?.is_none());
        Ok(())
    }
    fn change(operation: &str) -> Change {
        Change {
            operation: operation.into(),
            id: String::new(),
            calendar_id: "work".into(),
            title: "Draft".into(),
            start_day: "2026-11-01".into(),
            start_time: "09:00".into(),
            end_day: "2026-11-01".into(),
            end_time: "10:00".into(),
            all_day: false,
            location: "Studio".into(),
            description: "Notes".into(),
        }
    }
    fn fixture() -> Result<Connection> {
        let db = crate::database(std::path::Path::new(":memory:"))?;
        db.execute("INSERT INTO calendar_preferences (id,name,color,enabled,access_role) VALUES ('work','Work','#112233',1,'writer')",[])?;
        let mut settings = settings::read(&db)?;
        settings.timezone = "America/Guatemala".into();
        settings::save(&db, &settings)?;
        Ok(db)
    }
    #[test]
    fn remembered_calendar_persists_only_successful_saves() -> Result<()> {
        let path = std::env::temp_dir().join(format!(
            "remarkablecalendar-last-calendar-{}.sqlite",
            std::process::id()
        ));
        let mut db = crate::database(&path)?;
        assert!(last_calendar(&db)?.is_none());
        let mut local_change = change("create");
        local_change.calendar_id = "local".into();
        let local_saved = apply(&mut db, &local_change)?;
        assert_eq!(last_calendar(&db)?.as_deref(), Some("local"));
        db.execute("INSERT INTO calendar_preferences (id,name,color,enabled,access_role) VALUES ('work','Work','#112233',1,'writer')",[])?;
        let google_saved = apply(&mut db, &change("create"))?;
        assert_eq!(last_calendar(&db)?.as_deref(), Some("work"));
        drop(db);
        let mut db = crate::database(&path)?;
        assert_eq!(last_calendar(&db)?.as_deref(), Some("work"));
        local_change.operation = "update".into();
        local_change.id = local_saved["event"]["id"].as_str().unwrap().into();
        apply(&mut db, &local_change)?;
        assert_eq!(last_calendar(&db)?.as_deref(), Some("local"));
        let mut invalid = change("create");
        invalid.title = "".into();
        assert!(apply(&mut db, &invalid).is_err());
        let mut delete = change("delete");
        delete.id = google_saved["event"]["id"].as_str().unwrap().into();
        apply(&mut db, &delete)?;
        assert_eq!(last_calendar(&db)?.as_deref(), Some("local"));
        drop(db);
        std::fs::remove_file(path)?;
        Ok(())
    }
    #[test]
    fn offline_create_update_delete_and_local() -> Result<()> {
        let mut db = fixture()?;
        let mut c = change("create");
        let created = apply(&mut db, &c)?;
        c.id = created["event"]["id"].as_str().unwrap().into();
        assert_eq!(count(&db)?, 1);
        assert!(item(&db, &c.id)?.details.unwrap().pending);
        c.operation = "update".into();
        c.title = "Changed offline".into();
        apply(&mut db, &c)?;
        assert_eq!(count(&db)?, 1);
        assert_eq!(item(&db, &c.id)?.title, "Changed offline");
        let operation: String =
            db.query_row("SELECT operation FROM event_outbox", [], |r| r.get(0))?;
        assert_eq!(operation, "create");
        c.operation = "delete".into();
        apply(&mut db, &c)?;
        assert_eq!(count(&db)?, 0);
        assert!(cached(&db, &c.id)?.is_none());
        c = change("create");
        c.calendar_id = "local".into();
        let local = apply(&mut db, &c)?;
        c.id = local["event"]["id"].as_str().unwrap().into();
        c.operation = "update".into();
        c.title = "Local edit".into();
        apply(&mut db, &c)?;
        assert_eq!(count(&db)?, 0);
        assert_eq!(item(&db, &c.id)?.title, "Local edit");
        c.operation = "delete".into();
        apply(&mut db, &c)?;
        assert!(local_event_missing(&db, &c.id));
        Ok(())
    }
    fn local_event_missing(db: &Connection, id: &str) -> bool {
        local(db, id).unwrap().is_none()
    }
    #[test]
    fn pending_overlay_discard_and_remote_base() -> Result<()> {
        let mut db = fixture()?;
        let raw = serde_json::json!({"id":"remote","etag":"\"v1\"","summary":"Original","start":{"dateTime":"2026-11-01T09:00:00-06:00"},"end":{"dateTime":"2026-11-01T10:00:00-06:00"}});
        let original =
            google::convert(&raw, "work", "#112233", "America/Guatemala".parse()?)?.unwrap();
        google::store(
            &mut db,
            "work",
            std::slice::from_ref(&original),
            "2026-10-01",
            "2027-01-01",
            "America/Guatemala",
        )?;
        let mut c = change("update");
        c.id = original.id.clone();
        apply(&mut db, &c)?;
        c.title = "Second offline edit".into();
        apply(&mut db, &c)?;
        let base: String = db.query_row("SELECT base_json FROM event_outbox", [], |r| r.get(0))?;
        assert_eq!(serde_json::from_str::<Event>(&base)?.title, "Original");
        google::store(
            &mut db,
            "work",
            std::slice::from_ref(&original),
            "2026-10-01",
            "2027-01-01",
            "America/Guatemala",
        )?;
        assert_eq!(item(&db, &c.id)?.title, "Second offline edit");
        discard(&mut db, &c.id)?;
        assert_eq!(item(&db, &c.id)?.title, "Original");
        c.operation = "delete".into();
        apply(&mut db, &c)?;
        google::store(
            &mut db,
            "work",
            std::slice::from_ref(&original),
            "2026-10-01",
            "2027-01-01",
            "America/Guatemala",
        )?;
        assert!(cached(&db, &c.id)?.is_none());
        assert_eq!(count(&db)?, 1);
        discard(&mut db, &c.id)?;
        assert_eq!(item(&db, &c.id)?.title, "Original");
        Ok(())
    }
    #[test]
    fn attempted_create_deletion_and_permission_validation() -> Result<()> {
        let mut db = fixture()?;
        let mut c = change("create");
        let result = apply(&mut db, &c)?;
        c.id = result["event"]["id"].as_str().unwrap().into();
        db.execute("UPDATE event_outbox SET attempted=1", [])?;
        c.operation = "delete".into();
        apply(&mut db, &c)?;
        assert_eq!(count(&db)?, 1);
        assert_eq!(
            db.query_row("SELECT operation FROM event_outbox", [], |r| r
                .get::<_, String>(0))?,
            "delete"
        );
        db.execute("UPDATE calendar_preferences SET access_role='reader'", [])?;
        assert!(apply(&mut db, &change("create")).is_err());
        assert_eq!(count(&db)?, 1);
        db.execute("UPDATE calendar_preferences SET access_role='writer'", [])?;
        let mut invalid = change("create");
        invalid.start_time = "bad".into();
        assert!(apply(&mut db, &invalid).is_err());
        assert_eq!(count(&db)?, 1);
        let mut all = change("create");
        all.all_day = true;
        all.end_day = "2026-11-03".into();
        let saved = apply(&mut db, &all)?;
        let event: Event = serde_json::from_value(saved["event"].clone())?;
        assert_eq!(payload(&event)?["end"]["date"], "2026-11-03");
        Ok(())
    }
}
