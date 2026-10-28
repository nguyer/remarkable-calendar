//! Read-only bounded snapshots. Network work finishes before the cache transaction begins.
use crate::{date, validate, Event, EventDetails, Result};
use chrono::{DateTime, Duration, Utc};
use chrono_tz::Tz;
use reqwest::blocking::Client;
use rusqlite::{params, Connection};
use serde::Deserialize;
use serde_json::Value;
use std::{env, fs, os::unix::fs::PermissionsExt, path::PathBuf, time::Duration as Timeout};

const API: &str = "https://www.googleapis.com/calendar/v3/";
#[derive(Deserialize)]
struct Credentials {
    client_id: String,
    client_secret: String,
    refresh_token: String,
}
fn credentials() -> Result<Credentials> {
    let path = env::var_os("REMARKABLE_CALENDAR_GOOGLE_CREDENTIALS")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_else(|| ".".into()))
                .join(".config/remarkable-calendar/google.json")
        });
    let metadata = fs::metadata(&path).map_err(|_| "Google sign-in credentials are unavailable. Complete browser login and copy google.json to the tablet")?;
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err("Google credentials must be private: chmod 600 <credentials file>".into());
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
pub(crate) fn client_and_token() -> Result<(Client, String)> {
    let c = credentials()?;
    let client = Client::builder()
        .timeout(Timeout::from_secs(30))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let response = client
        .post("https://oauth2.googleapis.com/token")
        .form(&[
            ("client_id", c.client_id.as_str()),
            ("client_secret", c.client_secret.as_str()),
            ("refresh_token", c.refresh_token.as_str()),
            ("grant_type", "refresh_token"),
        ])
        .send()?;
    if !response.status().is_success() {
        return Err(format!("Google token refresh failed (HTTP {}); repeat browser login if access expired or was revoked", response.status()).into());
    }
    let body: Value = response.json()?;
    Ok((client, required(&body, "access_token")?.to_owned()))
}
fn required<'a>(v: &'a Value, field: &str) -> Result<&'a str> {
    v.get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Google response missing {field}").into())
}
fn get(client: &Client, token: &str, path: &str, query: &[(String, String)]) -> Result<Value> {
    let response = client
        .get(format!("{API}{path}"))
        .bearer_auth(token)
        .query(query)
        .send()?;
    if !response.status().is_success() {
        return Err(format!(
            "Google Calendar request failed (HTTP {}); cached events kept",
            response.status()
        )
        .into());
    }
    Ok(response.json()?)
}
fn pages(
    client: &Client,
    token: &str,
    path: &str,
    query: Vec<(String, String)>,
) -> Result<Vec<Value>> {
    fetch_pages(query, |query| get(client, token, path, query))
}
fn fetch_pages(
    mut query: Vec<(String, String)>,
    mut fetch: impl FnMut(&[(String, String)]) -> Result<Value>,
) -> Result<Vec<Value>> {
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    loop {
        let body = fetch(&query)?;
        // Google may omit items for an empty page.
        if let Some(page) = body.get("items") {
            items.extend(
                page.as_array()
                    .ok_or("invalid Google items array")?
                    .iter()
                    .cloned(),
            );
        }
        match body.get("nextPageToken").and_then(Value::as_str) {
            Some(next) if !next.is_empty() => {
                if !seen.insert(next.to_owned()) {
                    return Err("Google repeated a page token".into());
                }
                query.retain(|(k, _)| k != "pageToken");
                query.push(("pageToken".into(), next.into()));
            }
            _ => return Ok(items),
        }
    }
}
pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS google_cache (calendar_id TEXT NOT NULL, event_id TEXT NOT NULL, event_json TEXT NOT NULL, PRIMARY KEY(calendar_id,event_id));
        CREATE TABLE IF NOT EXISTS google_sync (calendar_id TEXT PRIMARY KEY, time_min TEXT NOT NULL, time_max TEXT NOT NULL, timezone TEXT NOT NULL, synced_at TEXT NOT NULL);")?;
    crate::settings::init(db)?;
    crate::edits::init(db)?;
    Ok(())
}
pub fn cached(db: &Connection) -> Result<Vec<Event>> {
    let mut stmt =
        db.prepare("SELECT event_json FROM google_cache WHERE NOT EXISTS (SELECT 1 FROM calendar_preferences p WHERE p.id=google_cache.calendar_id AND p.enabled=0) ORDER BY calendar_id,event_id")?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    rows.into_iter()
        .map(|row| Ok(serde_json::from_str(&row)?))
        .collect()
}
pub fn status(db: &Connection) -> Result<Value> {
    let mut stmt = db.prepare("SELECT calendar_id,time_min,time_max,timezone,synced_at FROM google_sync WHERE NOT EXISTS (SELECT 1 FROM calendar_preferences p WHERE p.id=google_sync.calendar_id AND p.enabled=0) ORDER BY calendar_id")?;
    let rows = stmt
        .query_map([], |r| {
            Ok(serde_json::json!({"calendar_id":r.get::<_,String>(0)?,
        "time_min":r.get::<_,String>(1)?,"time_max":r.get::<_,String>(2)?,
        "timezone":r.get::<_,String>(3)?,"synced_at":r.get::<_,String>(4)?}))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(serde_json::json!({"calendars":rows,"pending_count":crate::edits::count(db)?}))
}
pub fn refresh_catalog(db: &mut Connection) -> Result<()> {
    let (client, token) = client_and_token()?;
    let calendars = pages(&client, &token, "users/me/calendarList", vec![])?;
    crate::settings::catalog(db, &calendars)
}
pub fn calendars() -> Result<()> {
    let (client, token) = client_and_token()?;
    let calendars = pages(&client, &token, "users/me/calendarList", vec![])?;
    for c in calendars {
        println!(
            "{}\t{}",
            required(&c, "id")?,
            c["summary"].as_str().unwrap_or("Untitled")
        );
    }
    Ok(())
}
pub(crate) fn encode_segment(id: &str) -> String {
    id.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub(crate) fn calendar_path(id: &str) -> String {
    format!("calendars/{}", encode_segment(id))
}

pub(crate) fn convert(
    raw: &Value,
    calendar_id: &str,
    color: &str,
    tz: Tz,
) -> Result<Option<Event>> {
    if raw["status"] == "cancelled" {
        return Ok(None);
    }
    let start = &raw["start"];
    let end = &raw["end"];
    let (day, start_time, end_day, end_time, all_day) = if let Some(first) = start["date"].as_str()
    {
        let first = date(first)?;
        let last = date(required(end, "date")?)?;
        if last <= first {
            return Err("invalid all-day event interval".into());
        }
        (
            first.to_string(),
            "00:00".into(),
            last.to_string(),
            "00:00".into(),
            true,
        )
    } else {
        let a = DateTime::parse_from_rfc3339(required(start, "dateTime")?)?;
        let b = DateTime::parse_from_rfc3339(required(end, "dateTime")?)?;
        if b <= a {
            return Err("invalid Google event interval".into());
        }
        let a = a.with_timezone(&tz);
        let b = b.with_timezone(&tz);
        // Keep sub-minute events visible in a minute-resolution calendar.
        let mut finish = b.naive_local();
        if finish.date() == a.date_naive()
            && finish.format("%H:%M").to_string() <= a.format("%H:%M").to_string()
        {
            finish = a.naive_local() + Duration::minutes(1);
        }
        (
            a.date_naive().to_string(),
            a.format("%H:%M").to_string(),
            finish.date().to_string(),
            finish.format("%H:%M").to_string(),
            false,
        )
    };
    let e = Event {
        id: format!("google:{}:{}", calendar_id.len(), calendar_id) + ":" + required(raw, "id")?,
        title: raw["summary"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or("(Untitled)")
            .into(),
        day,
        start: start_time,
        end: end_time,
        end_day: Some(end_day),
        color: color.into(),
        all_day,
        details: Some(EventDetails {
            location: raw["location"].as_str().unwrap_or("").into(),
            description: raw["description"].as_str().unwrap_or("").into(),
            calendar_name: calendar_id.into(),
            timezone: tz.to_string(),
            calendar_id: calendar_id.into(),
            event_id: required(raw, "id")?.into(),
            etag: raw["etag"].as_str().unwrap_or("").into(),
            recurring: raw["recurringEventId"].is_string(),
            ..Default::default()
        }),
    };
    validate(&e)?;
    Ok(Some(e))
}
pub(crate) fn store(
    db: &mut Connection,
    calendar: &str,
    events: &[Event],
    min: &str,
    max: &str,
    tz: &str,
) -> Result<()> {
    let tx = db.transaction()?;
    tx.execute("DELETE FROM google_cache WHERE calendar_id=?1 AND NOT EXISTS (SELECT 1 FROM event_outbox o WHERE o.id=google_cache.event_id)", [calendar])?;
    for e in events {
        let pending: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM event_outbox WHERE id=?1)",
            [&e.id],
            |r| r.get(0),
        )?;
        if pending {
            continue;
        }
        tx.execute(
            "INSERT INTO google_cache VALUES (?1,?2,?3)",
            params![calendar, e.id, serde_json::to_string(e)?],
        )?;
    }
    tx.execute("INSERT INTO google_sync VALUES (?1,?2,?3,?4,?5) ON CONFLICT(calendar_id) DO UPDATE SET time_min=excluded.time_min,time_max=excluded.time_max,timezone=excluded.timezone,synced_at=excluded.synced_at",
        params![calendar,min,max,tz,Utc::now().to_rfc3339()])?;
    tx.execute("INSERT INTO calendar_preferences (id,name,color,enabled) VALUES (?1,?1,'#55778b',1) ON CONFLICT(id) DO UPDATE SET enabled=1",[calendar])?;
    tx.commit()?;
    Ok(())
}
pub fn sync(db: &mut Connection, args: &[String]) -> Result<()> {
    sync_with_progress(db, args, |_| {})
}
pub fn sync_with_progress(
    db: &mut Connection,
    args: &[String],
    mut progress: impl FnMut(&str),
) -> Result<()> {
    if args.len() < 3 {
        return Err(
            "usage: google-sync START-DATE END-DATE TIMEZONE [CALENDAR-ID ...] (end exclusive)"
                .into(),
        );
    }
    let min_day = date(&args[0])?;
    let max_day = date(&args[1])?;
    if max_day <= min_day || (max_day - min_day).num_days() > 1130 {
        return Err("sync window must be 1–1130 days".into());
    }
    let tz: Tz = args[2].parse()?;
    let midnight = |day: chrono::NaiveDate| -> Result<String> {
        use chrono::TimeZone;
        Ok(tz
            .from_local_datetime(&day.and_hms_opt(0, 0, 0).unwrap())
            .single()
            .ok_or("ambiguous/nonexistent midnight; choose another date")?
            .to_rfc3339())
    };
    let min = midnight(min_day)?;
    let max = midnight(max_day)?;
    progress("Connecting to Google…");
    let (client, token) = client_and_token()?;
    progress("Reading calendars…");
    let colors = get(&client, &token, "colors", &[])?;
    let calendars = pages(&client, &token, "users/me/calendarList", vec![])?;
    let ids: Vec<String> = if args.len() > 3 {
        args[3..].to_vec()
    } else {
        vec!["primary".into()]
    };
    for requested in ids {
        let calendar = calendars
            .iter()
            .find(|c| c["id"] == requested || (requested == "primary" && c["primary"] == true))
            .ok_or("requested calendar not found in Google calendar list")?;
        let id = required(calendar, "id")?;
        let fallback = calendar["backgroundColor"].as_str().unwrap_or("#55778b");
        progress("Downloading calendar events…");
        let raw = pages(
            &client,
            &token,
            &format!("{}/events", calendar_path(id)),
            vec![
                ("timeMin".into(), min.clone()),
                ("timeMax".into(), max.clone()),
                ("timeZone".into(), tz.to_string()),
                ("singleEvents".into(), "true".into()),
                ("maxResults".into(), "2500".into()),
            ],
        )?;
        let mut events = Vec::new();
        for item in raw {
            let color = item["colorId"]
                .as_str()
                .and_then(|id| colors["event"][id]["background"].as_str())
                .unwrap_or(fallback);
            if let Some(mut e) = convert(&item, id, color, tz)? {
                if let Some(details) = e.details.as_mut() {
                    details.writable = ["owner", "writer"]
                        .contains(&calendar["accessRole"].as_str().unwrap_or(""));
                    details.calendar_name = calendar["summaryOverride"]
                        .as_str()
                        .or_else(|| calendar["summary"].as_str())
                        .unwrap_or(id)
                        .into();
                }
                events.push(e);
            }
        }
        progress("Saving calendar events…");
        store(db, id, &events, &min, &max, &tz.to_string())?;
        eprintln!(
            "Cached {} events for {}",
            events.len(),
            calendar["summary"].as_str().unwrap_or(id)
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pagination_and_failure() -> Result<()> {
        let mut calls = 0;
        let items = fetch_pages(vec![], |query| {
            calls += 1;
            if calls == 1 {
                Ok(serde_json::json!({"items":[{"id":"one"}],"nextPageToken":"next"}))
            } else {
                assert_eq!(query, &[("pageToken".into(), "next".into())]);
                Ok(serde_json::json!({"items":[{"id":"two"}]}))
            }
        })?;
        assert_eq!(items.len(), 2);
        assert_eq!(calls, 2);
        let result = fetch_pages(vec![], |_| {
            Ok(serde_json::json!({"nextPageToken":"repeated"}))
        });
        assert!(result.is_err());
        assert!(fetch_pages(vec![], |_| Err("offline".into())).is_err());
        assert_eq!(
            calendar_path("a+b@example.com"),
            "calendars/a%2Bb%40example.com"
        );
        Ok(())
    }
    #[test]
    fn dst_and_cache_rollback() -> Result<()> {
        let tz: Tz = "America/New_York".parse()?;
        let raw = serde_json::json!({"id":"dst", "start":{"dateTime":"2026-03-08T06:30:00Z"}, "end":{"dateTime":"2026-03-08T07:30:00Z"}});
        let e = convert(&raw, "work", "#112233", tz)?.unwrap();
        assert_eq!((&*e.start, &*e.end), ("01:30", "03:30"));
        let mut db = crate::database(std::path::Path::new(":memory:"))?;
        store(
            &mut db,
            "work",
            std::slice::from_ref(&e),
            "min",
            "max",
            "America/New_York",
        )?;
        // A failure after deleting old rows must roll back the entire snapshot.
        assert!(store(
            &mut db,
            "work",
            &[e.clone(), e],
            "new-min",
            "new-max",
            "UTC"
        )
        .is_err());
        assert_eq!(cached(&db)?.len(), 1);
        assert_eq!(status(&db)?["calendars"][0]["time_min"], "min");
        assert_eq!(crate::week(&db, date("2026-03-08")?)?.events.len(), 1);
        Ok(())
    }
    #[test]
    fn timezone_all_day_cancelled_and_cache() -> Result<()> {
        let tz: Tz = "America/Guatemala".parse()?;
        let raw = serde_json::json!({"id":"a", "summary":"Trip", "location":"Studio", "description":"Bring notes", "start":{"dateTime":"2026-11-02T03:00:00Z"}, "end":{"dateTime":"2026-11-02T09:00:00Z"}});
        let e = convert(&raw, "work", "#112233", tz)?.unwrap();
        assert_eq!(
            (&*e.day, &*e.start, &*e.end),
            ("2026-11-01", "21:00", "03:00")
        );
        assert_eq!(e.end_day.as_deref(), Some("2026-11-02"));
        let details = e.details.as_ref().unwrap();
        assert_eq!(
            (
                &*details.location,
                &*details.description,
                &*details.timezone
            ),
            ("Studio", "Bring notes", "America/Guatemala")
        );
        let all = serde_json::json!({"id":"b", "start":{"date":"2026-11-01"},"end":{"date":"2026-11-03"}});
        let a = convert(&all, "work", "#112233", tz)?.unwrap();
        assert!(a.all_day);
        assert!(convert(
            &serde_json::json!({"status":"cancelled"}),
            "work",
            "#112233",
            tz
        )?
        .is_none());
        let mut db = crate::database(std::path::Path::new(":memory:"))?;
        store(&mut db, "work", &[e, a], "min", "max", "America/Guatemala")?;
        let next_week = crate::week(&db, date("2026-11-02")?)?;
        let all_days: Vec<_> = next_week.events.iter().filter(|e| e.all_day).collect();
        assert_eq!(all_days.len(), 1);
        assert_eq!(all_days[0].day, "2026-11-02");
        db.execute("INSERT INTO events (id,title,day,start,end,color) VALUES ('local','Local','2026-11-02','09:00','10:00','#111111')", [])?;
        assert_eq!(cached(&db)?.len(), 2);
        store(&mut db, "other", &[], "min", "max", "UTC")?;
        assert_eq!(cached(&db)?.len(), 2);
        store(&mut db, "work", &[], "min", "max", "UTC")?;
        assert!(cached(&db)?.is_empty());
        assert_eq!(crate::week(&db, date("2026-11-02")?)?.events[0].id, "local");
        Ok(())
    }
}
