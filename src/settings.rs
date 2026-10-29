//! Persistent calendar choices and rolling-window policy, independent of cached events.
use crate::Result;
use chrono::{DateTime, Duration, Months, NaiveDate, Utc};
use chrono_tz::Tz;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub timezone: String,
    pub months_before: u32,
    pub months_after: u32,
    pub auto_sync: bool,
    pub stale_minutes: i64,
    pub selected_ids: Vec<String>,
    #[serde(default = "default_time_format")]
    pub time_format: String,
    #[serde(default)]
    pub day_scroll: bool,
    #[serde(default = "default_day_start")]
    pub day_start: u32,
    #[serde(default = "default_day_end")]
    pub day_end: u32,
}
fn default_time_format() -> String {
    "12h".into()
}
fn default_day_start() -> u32 {
    420
}
fn default_day_end() -> u32 {
    1260
}
pub fn display(db: &Connection) -> Result<Value> {
    let s = read(db)?;
    Ok(
        serde_json::json!({"time_format":s.time_format,"day_scroll":s.day_scroll,"day_start":s.day_start,"day_end":s.day_end}),
    )
}
pub fn init(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS calendar_preferences (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, enabled INTEGER NOT NULL, available INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS navigation_state (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS app_settings (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL);
        INSERT OR IGNORE INTO calendar_preferences (id,name,color,enabled) SELECT calendar_id,calendar_id,'#55778b',1 FROM google_sync;")?;
    let has_role: bool = {
        let mut stmt = db.prepare("PRAGMA table_info(calendar_preferences)")?;
        let names = stmt
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        names.iter().any(|n| n == "access_role")
    };
    if !has_role {
        db.execute_batch("ALTER TABLE calendar_preferences ADD COLUMN access_role TEXT NOT NULL DEFAULT 'unknown';")?;
    }
    Ok(())
}
pub fn read(db: &Connection) -> Result<Settings> {
    use rusqlite::OptionalExtension;
    let json: Option<String> = db
        .query_row("SELECT json FROM app_settings WHERE id=1", [], |r| r.get(0))
        .optional()?;
    let mut settings = if let Some(json) = json {
        serde_json::from_str(&json)?
    } else {
        let timezone = db
            .query_row(
                "SELECT timezone FROM google_sync ORDER BY calendar_id LIMIT 1",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .unwrap_or_else(|| "UTC".into());
        Settings {
            timezone,
            months_before: 1,
            months_after: 6,
            auto_sync: true,
            stale_minutes: 60,
            selected_ids: vec![],
            time_format: default_time_format(),
            day_scroll: false,
            day_start: default_day_start(),
            day_end: default_day_end(),
        }
    };
    let mut stmt = db.prepare("SELECT id FROM calendar_preferences WHERE enabled=1 ORDER BY id")?;
    settings.selected_ids = stmt
        .query_map([], |r| r.get(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(settings)
}
pub fn response(db: &Connection) -> Result<Value> {
    let mut stmt = db.prepare(
        "SELECT id,name,color,enabled,available,access_role FROM calendar_preferences ORDER BY name,id",
    )?;
    let calendars = stmt.query_map([],|r| Ok(serde_json::json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"color":r.get::<_,String>(2)?,"enabled":r.get::<_,bool>(3)?,"available":r.get::<_,bool>(4)?,"access_role":r.get::<_,String>(5)?})))?
        .collect::<std::result::Result<Vec<_>,_>>()?;
    Ok(
        serde_json::json!({"settings":read(db)?,"calendars":calendars,"pending":crate::edits::pending(db)?,"new_event_id":crate::edits::random_id()?,"last_calendar_id":crate::edits::last_calendar(db)?}),
    )
}
pub fn save(db: &Connection, s: &Settings) -> Result<()> {
    s.timezone.parse::<Tz>()?;
    if s.months_before > 12
        || !(1..=18).contains(&s.months_after)
        || !(15..=1440).contains(&s.stale_minutes)
    {
        return Err(
            "use 0–12 months back, 1–18 months ahead, and a refresh interval of 15–1440 minutes"
                .into(),
        );
    }
    if !["12h", "24h"].contains(&s.time_format.as_str())
        || s.day_start >= s.day_end
        || s.day_end > 1440
        || !s.day_start.is_multiple_of(60)
        || !s.day_end.is_multiple_of(60)
    {
        return Err(
            "Choose 12h or 24h time and whole-hour day bounds with start before end (00:00–24:00)"
                .into(),
        );
    }
    let tx = db.unchecked_transaction()?;
    for id in &s.selected_ids {
        let known: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM calendar_preferences WHERE id=?1)",
            [id],
            |r| r.get(0),
        )?;
        if !known {
            return Err("unknown calendar; refresh the calendar list first".into());
        }
    }
    tx.execute("UPDATE calendar_preferences SET enabled=0", [])?;
    for id in &s.selected_ids {
        tx.execute(
            "UPDATE calendar_preferences SET enabled=1 WHERE id=?1",
            [id],
        )?;
    }
    tx.execute(
        "INSERT INTO app_settings VALUES (1,?1) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        [serde_json::to_string(s)?],
    )?;
    tx.commit()?;
    Ok(())
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Navigation {
    pub view: String,
    pub date: String,
}
pub fn navigation(db: &Connection) -> Result<Option<Navigation>> {
    use rusqlite::OptionalExtension;
    let json: Option<String> = db
        .query_row("SELECT json FROM navigation_state WHERE id=1", [], |r| {
            r.get(0)
        })
        .optional()?;
    json.map(|json| serde_json::from_str(&json).map_err(Into::into))
        .transpose()
}
pub fn save_navigation(db: &Connection, state: &Navigation) -> Result<()> {
    if !["week", "day"].contains(&state.view.as_str()) {
        return Err("Choose a supported calendar view".into());
    }
    if crate::date(&state.date)?.to_string() != state.date {
        return Err("Use a YYYY-MM-DD navigation date".into());
    }
    db.execute("INSERT INTO navigation_state VALUES (1,?1) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        [serde_json::to_string(state)?])?;
    Ok(())
}
pub fn window(s: &Settings, today: NaiveDate) -> Result<(String, String)> {
    let start = today
        .checked_sub_months(Months::new(s.months_before))
        .ok_or("invalid window start")?;
    let end = today
        .checked_add_months(Months::new(s.months_after))
        .and_then(|d| d.checked_add_signed(Duration::days(1)))
        .ok_or("invalid window end")?;
    Ok((start.to_string(), end.to_string()))
}
pub fn plans(db: &Connection, now: DateTime<Utc>) -> Result<Vec<Vec<String>>> {
    let s = read(db)?;
    let tz: Tz = s.timezone.parse()?;
    let (start, end) = window(&s, now.with_timezone(&tz).date_naive())?;
    let mut stmt = db.prepare(
        "SELECT id FROM calendar_preferences WHERE enabled=1 AND available=1 ORDER BY id",
    )?;
    let ids = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if ids.is_empty() {
        return Err("Choose at least one available calendar in Settings".into());
    }
    Ok(ids
        .into_iter()
        .map(|id| vec![start.clone(), end.clone(), s.timezone.clone(), id])
        .collect())
}
pub fn should_auto_sync(db: &Connection, now: DateTime<Utc>) -> Result<bool> {
    use rusqlite::OptionalExtension;
    let s = read(db)?;
    if !s.auto_sync {
        return Ok(false);
    }
    if crate::edits::count(db)? > 0 {
        return Ok(true);
    }
    let plans = match plans(db, now) {
        Ok(p) => p,
        Err(_) => return Ok(false),
    };
    for plan in plans {
        let saved = db
            .query_row(
                "SELECT time_min,time_max,timezone,synced_at FROM google_sync WHERE calendar_id=?1",
                [&plan[3]],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((min, max, tz, stamp)) = saved else {
            return Ok(true);
        };
        let stamp = match DateTime::parse_from_rfc3339(&stamp) {
            Ok(s) => s,
            Err(_) => return Ok(true),
        };
        if min.get(..10).unwrap_or("") > plan[0].as_str()
            || max.get(..10).unwrap_or("") < plan[1].as_str()
            || tz != plan[2]
            || now.signed_duration_since(stamp).num_minutes() >= s.stale_minutes
            || stamp > now
        {
            return Ok(true);
        }
    }
    Ok(false)
}
pub fn catalog(db: &mut Connection, calendars: &[Value]) -> Result<()> {
    let tx = db.transaction()?;
    tx.execute("UPDATE calendar_preferences SET available=0", [])?;
    for c in calendars {
        if c["deleted"] == true {
            continue;
        }
        let id = c["id"].as_str().ok_or("Google calendar missing id")?;
        let name = c["summaryOverride"]
            .as_str()
            .or_else(|| c["summary"].as_str())
            .unwrap_or(id);
        let color = c["backgroundColor"].as_str().unwrap_or("#55778b");
        tx.execute("INSERT INTO calendar_preferences (id,name,color,enabled,available,access_role) VALUES (?1,?2,?3,0,1,?4) ON CONFLICT(id) DO UPDATE SET name=excluded.name,color=excluded.color,available=1,access_role=excluded.access_role",params![id,name,color,c["accessRole"].as_str().unwrap_or("reader")])?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn display_defaults_and_validation() -> Result<()> {
        let legacy = r#"{"timezone":"UTC","months_before":1,"months_after":6,"auto_sync":false,"stale_minutes":60,"selected_ids":[]}"#;
        let mut s: Settings = serde_json::from_str(legacy)?;
        assert_eq!(
            (&*s.time_format, s.day_scroll, s.day_start, s.day_end),
            ("12h", false, 420, 1260)
        );
        let db = crate::database(std::path::Path::new(":memory:"))?;
        save(&db, &s)?;
        s.time_format = "24h".into();
        s.day_scroll = true;
        save(&db, &s)?;
        assert_eq!(display(&db)?["time_format"], "24h");
        s.day_start = s.day_end;
        assert!(save(&db, &s).is_err());
        assert_eq!(read(&db)?.day_start, 420);
        s.day_start = 450;
        assert!(save(&db, &s).is_err());
        s.day_start = 420;
        s.time_format = "invalid".into();
        assert!(save(&db, &s).is_err());
        Ok(())
    }
    #[test]
    fn selection_windows_and_staleness() -> Result<()> {
        let mut db = crate::database(std::path::Path::new(":memory:"))?;
        db.execute("INSERT INTO google_sync VALUES ('work','2026-01-01T00:00:00Z','2027-12-01T00:00:00Z','America/Guatemala','2026-10-26T12:00:00Z')",[])?;
        init(&db)?;
        let now = DateTime::parse_from_rfc3339("2026-10-26T12:30:00Z")?.with_timezone(&Utc);
        assert!(!should_auto_sync(&db, now)?);
        assert!(should_auto_sync(&db, now + Duration::hours(2))?);
        let mut s = read(&db)?;
        assert_eq!(s.selected_ids, vec!["work"]);
        assert_eq!(
            window(&s, crate::date("2024-03-31")?)?,
            ("2024-02-29".into(), "2024-10-01".into())
        );
        catalog(
            &mut db,
            &[
                serde_json::json!({"id":"work","summary":"Work","backgroundColor":"#112233"}),
                serde_json::json!({"id":"other","summary":"Other"}),
            ],
        )?;
        assert_eq!(read(&db)?.selected_ids, vec!["work"]);
        s.selected_ids = vec![];
        save(&db, &s)?;
        assert!(!should_auto_sync(&db, now)?);
        assert!(plans(&db, now).is_err());
        s.selected_ids = vec!["missing".into()];
        assert!(save(&db, &s).is_err());
        assert!(read(&db)?.selected_ids.is_empty());
        // IANA timezone determines today's date even when UTC is already next month.
        let near_midnight =
            DateTime::parse_from_rfc3339("2026-11-01T03:00:00Z")?.with_timezone(&Utc);
        s.selected_ids = vec!["work".into()];
        save(&db, &s)?;
        let plan = plans(&db, near_midnight)?;
        assert_eq!((&*plan[0][0], &*plan[0][1]), ("2026-09-30", "2027-05-01"));
        s.months_after = 99;
        assert!(save(&db, &s).is_err());
        assert_eq!(read(&db)?.months_after, 6);
        s.months_after = 6;
        s.selected_ids = vec!["other".into()];
        save(&db, &s)?;
        assert!(should_auto_sync(&db, now)?);
        s.auto_sync = false;
        save(&db, &s)?;
        assert!(!should_auto_sync(&db, now)?);
        Ok(())
    }
}
