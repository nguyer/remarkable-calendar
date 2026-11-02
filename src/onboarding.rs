//! Private pairing state stays in the backend; QML receives only display data.
use crate::{google, Result};
use qrcode::{Color, QrCode};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

pub const ORIGIN: &str = "https://auth.opendev.stream";
#[derive(Debug)]
struct UserMessage(&'static str);
impl std::fmt::Display for UserMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for UserMessage {}
#[derive(Clone, Default, Serialize)]
pub struct Status {
    pub state: String,
    pub message: String,
    pub verification_uri: String,
    pub user_code: String,
    pub qr: Vec<String>,
    pub email: String,
    pub expires_at: i64,
    pub connected: bool,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Relay {
    #[serde(rename = "type")]
    pub kind: String,
    pub service_url: String,
    pub grant: String,
}
#[derive(Default)]
struct Inner {
    revision: u64,
    status: Status,
    credentials: Option<Relay>,
}
#[derive(Clone, Default)]
pub struct Onboarding(Arc<Mutex<Inner>>);
fn client() -> Result<Client> {
    Ok(Client::builder()
        .user_agent("remarkable-calendar/0.8")
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}
fn read_json(response: reqwest::blocking::Response) -> Result<Value> {
    let mut bytes = Vec::new();
    response.take(32769).read_to_end(&mut bytes)?;
    if bytes.len() > 32768 {
        return Err("Oversized sign-in response".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn opaque(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn qr_rows(uri: &str) -> Result<Vec<String>> {
    let code = QrCode::new(uri.as_bytes())?;
    Ok((0..code.width())
        .map(|y| {
            (0..code.width())
                .map(|x| {
                    if code[(x, y)] == Color::Dark {
                        '1'
                    } else {
                        '0'
                    }
                })
                .collect()
        })
        .collect())
}
impl Onboarding {
    pub fn status(&self) -> Status {
        let mut inner = self.0.lock().unwrap();
        if inner.status.expires_at > 0
            && inner.status.expires_at <= chrono::Utc::now().timestamp()
            && matches!(
                inner.status.state.as_str(),
                "pending" | "authorizing" | "confirm"
            )
        {
            inner.revision += 1;
            inner.credentials = None;
            inner.status = Status {
                state: "expired".into(),
                message: "Sign-in expired. Start again.".into(),
                ..Default::default()
            };
        }
        let mut status = inner.status.clone();
        if status.state.is_empty() {
            status.state = "idle".into();
        }
        status.connected = google::credentials_path().is_file();
        status
    }
    pub fn active(&self) -> bool {
        matches!(
            self.status().state.as_str(),
            "connecting" | "pending" | "authorizing" | "confirm"
        )
    }
    fn update(&self, revision: u64, f: impl FnOnce(&mut Inner)) -> bool {
        let mut inner = self.0.lock().unwrap();
        if inner.revision != revision {
            return false;
        }
        f(&mut inner);
        true
    }
    pub fn cancel(&self) {
        let mut inner = self.0.lock().unwrap();
        inner.revision += 1;
        inner.credentials = None;
        inner.status = Status {
            state: "idle".into(),
            ..Default::default()
        };
    }
    pub fn start(&self) -> bool {
        if self.active() {
            return false;
        }
        let revision = {
            let mut inner = self.0.lock().unwrap();
            inner.revision += 1;
            inner.credentials = None;
            inner.status = Status {
                state: "connecting".into(),
                message: "Creating a secure sign-in link…".into(),
                ..Default::default()
            };
            inner.revision
        };
        let job = self.clone();
        thread::spawn(move || {
            if let Err(error) = job.run_with(revision, ORIGIN, Duration::from_millis(100)) {
                let message = error.downcast_ref::<UserMessage>().map(|e| e.0)
                    .unwrap_or("Could not connect Google. Check Wi-Fi and try again. Existing credentials are unchanged.");
                job.update(revision, |inner| {
                    inner.credentials = None;
                    inner.status = Status {
                        state: "error".into(),
                        message: message.into(),
                        ..Default::default()
                    };
                });
            }
        });
        true
    }
    fn run_with(&self, revision: u64, base: &str, tick: Duration) -> Result<()> {
        let client = client()?;
        let response = client
            .post(format!("{base}/v1/pairings"))
            .json(&json!({"provider":"google"}))
            .send()?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            if status == 503 {
                if let Ok(body) = read_json(response) {
                    if body["error"] == "service_not_configured" {
                        return Err(UserMessage("The Google sign-in service setup is incomplete. Check its Google client, encryption key, and Cloudflare bindings.").into());
                    }
                }
            }
            if status == 429 {
                return Err(UserMessage(
                    "Too many sign-in attempts. Wait a minute, then try again.",
                )
                .into());
            }
            return Err("Sign-in unavailable".into());
        }
        let data = read_json(response)?;
        let id = data["id"].as_str().ok_or("Missing pairing ID")?;
        let secret = data["poll_secret"]
            .as_str()
            .ok_or("Missing polling secret")?;
        let uri = data["verification_uri"]
            .as_str()
            .ok_or("Missing verification URL")?;
        let code = data["user_code"]
            .as_str()
            .ok_or("Missing comparison code")?;
        let ttl = data["expires_in"]
            .as_u64()
            .filter(|n| (30..=600).contains(n))
            .ok_or("Invalid expiration")?;
        if !opaque(id)
            || !opaque(secret)
            || uri != format!("{ORIGIN}/connect/{id}")
            || code.len() != 6
            || !code.bytes().all(|c| c.is_ascii_digit())
        {
            return Err("Invalid sign-in response".into());
        }
        let url = format!("{base}/v1/pairings/{id}");
        let qr = qr_rows(uri)?;
        let expires_at = chrono::Utc::now().timestamp() + ttl as i64;
        let published = self.update(revision, |inner| {
            inner.status = Status {
                state: "pending".into(),
                message: "Scan with your phone, check the code, and sign in to Google.".into(),
                verification_uri: uri.into(),
                user_code: code.into(),
                qr,
                expires_at,
                ..Default::default()
            }
        });
        if !published {
            let _ = client.delete(&url).bearer_auth(secret).send();
            return Ok(());
        }
        let deadline = Instant::now() + Duration::from_secs(ttl);
        let mut interval = data["interval"].as_u64().unwrap_or(5).clamp(5, 60);
        loop {
            for _ in 0..interval * 10 {
                if !self.update(revision, |_| {}) {
                    let _ = client.delete(&url).bearer_auth(secret).send();
                    return Ok(());
                }
                thread::sleep(tick);
                if Instant::now() >= deadline {
                    self.update(revision, |inner| {
                        inner.status = Status {
                            state: "expired".into(),
                            message: "Sign-in expired. Start again.".into(),
                            ..Default::default()
                        }
                    });
                    let _ = client.delete(&url).bearer_auth(secret).send();
                    return Ok(());
                }
            }
            let response = match client.get(&url).bearer_auth(secret).send() {
                Ok(r) => r,
                Err(_) => continue,
            };
            if response.status().as_u16() == 429 {
                interval = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(60)
                    .clamp(5, 120);
                continue;
            }
            if response.status().is_server_error() {
                continue;
            }
            if !response.status().is_success() {
                return Err("Pairing expired or unavailable; start again".into());
            }
            let result = read_json(response)?;
            match result["status"].as_str().unwrap_or("") {
                "pending" | "authorizing" => {
                    self.update(revision, |inner| {
                        inner.status.state = result["status"].as_str().unwrap().into();
                    });
                }
                "complete" => {
                    let credentials: Relay = serde_json::from_value(result["credentials"].clone())?;
                    validate_relay(&credentials)?;
                    let email = result["account"]["email"]
                        .as_str()
                        .filter(|s| {
                            !s.is_empty() && s.len() <= 320 && !s.chars().any(char::is_control)
                        })
                        .ok_or("Invalid account")?;
                    self.update(revision, |inner| {
                        inner.credentials = Some(credentials);
                        inner.status = Status {
                            state: "confirm".into(),
                            email: email.into(),
                            expires_at,
                            message: "Confirm this account to finish connecting.".into(),
                            ..Default::default()
                        };
                    });
                    return Ok(());
                }
                "denied" | "error" => return Err("Google sign-in was not completed".into()),
                _ => return Err("Invalid sign-in state".into()),
            }
        }
    }
    pub fn accept(&self, db: &rusqlite::Connection) -> Result<()> {
        self.accept_at(db, &google::credentials_path())
    }
    fn accept_at(&self, db: &rusqlite::Connection, path: &std::path::Path) -> Result<()> {
        let _ = self.status();
        let mut inner = self.0.lock().unwrap();
        let credentials = inner
            .credentials
            .as_ref()
            .ok_or("Complete phone sign-in first")?;
        if crate::edits::count(db)? != 0 {
            return Err(
                "Sync or discard pending Google edits before replacing the connection".into(),
            );
        }
        // Clear account-specific cache before replacing credentials. A crash can force
        // a re-download, but cannot expose the previous account under the new sign-in.
        let tx = db.unchecked_transaction()?;
        tx.execute_batch("DELETE FROM google_cache; DELETE FROM google_sync; DELETE FROM calendar_preferences; DELETE FROM editor_preferences;")?;
        tx.commit()?;
        save_credentials(path, credentials)?;
        inner.credentials = None;
        inner.status = Status {
            state: "connected".into(),
            message: "Google connected. Refresh the calendar list and choose calendars to sync."
                .into(),
            ..Default::default()
        };
        Ok(())
    }
}
fn validate_relay(value: &Relay) -> Result<()> {
    if value.kind != "google-relay-v1"
        || value.service_url != ORIGIN
        || !value.grant.starts_with("v1.")
        || value.grant.len() > 12000
    {
        return Err("Unrecognized sign-in credentials".into());
    }
    Ok(())
}
fn save_credentials(path: &std::path::Path, value: &Relay) -> Result<()> {
    validate_relay(value)?;
    let parent = path.parent().ok_or("Invalid credential path")?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let temporary = parent.join(format!(".google-onboarding-{}.tmp", std::process::id()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| -> Result<()> {
        file.write_all(&serde_json::to_vec(value)?)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader},
        net::TcpListener,
    };
    fn relay() -> Relay {
        Relay {
            kind: "google-relay-v1".into(),
            service_url: ORIGIN.into(),
            grant: "v1.encrypted.test".into(),
        }
    }
    fn temp() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "calendar-onboarding-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    #[test]
    fn private_atomic_credentials_and_origin_validation() {
        let dir = temp();
        let path = dir.join("google.json");
        save_credentials(&path, &relay()).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let original = fs::read(&path).unwrap();
        let mut bad = relay();
        bad.service_url = "https://untrusted.example".into();
        assert!(save_credentials(&path, &bad).is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
        save_credentials(&path, &relay()).unwrap();
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn expiry_and_cancel_drop_credentials() {
        let flow = Onboarding::default();
        {
            let mut i = flow.0.lock().unwrap();
            i.status.state = "confirm".into();
            i.status.expires_at = 1;
            i.credentials = Some(relay());
        }
        assert_eq!(flow.status().state, "expired");
        assert!(flow.0.lock().unwrap().credentials.is_none());
        flow.cancel();
        assert_eq!(flow.status().state, "idle");
    }
    #[test]
    fn confirmation_preserves_local_data_and_blocks_pending_google_edits() {
        let dir = temp();
        let path = dir.join("google.json");
        let db = crate::database(&dir.join("events.sqlite3")).unwrap();
        db.execute("INSERT INTO events(id,title,day,start,end,color) VALUES('local','Keep','2026-11-01','09:00','10:00','#112233')",[]).unwrap();
        db.execute(
            "INSERT INTO google_sync VALUES('old','2026-01-01','2027-01-01','UTC','old')",
            [],
        )
        .unwrap();
        db.execute("INSERT INTO event_outbox(id,calendar_id,event_id,operation,event_json,etag) VALUES('pending','old','remote','delete','{}','')",[]).unwrap();
        let flow = Onboarding::default();
        {
            let mut i = flow.0.lock().unwrap();
            i.status.state = "confirm".into();
            i.credentials = Some(relay());
        }
        let (code, body) = crate::sync_route(
            &db,
            &crate::sync_job::SyncJob::default(),
            &flow,
            "POST",
            "/google/connect",
            true,
            br#"{"action":"start"}"#,
        );
        assert_eq!(code, "200 OK");
        let rejected: Value = serde_json::from_str(&body).unwrap();
        assert!(rejected["error"]
            .as_str()
            .unwrap()
            .contains("pending Google edits"));
        assert!(rejected.get("grant").is_none());
        assert!(flow.accept_at(&db, &path).is_err());
        assert!(!path.exists());
        assert_eq!(
            db.query_row("SELECT count(*) FROM google_sync", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        db.execute("DELETE FROM event_outbox", []).unwrap();
        flow.accept_at(&db, &path).unwrap();
        assert!(path.exists());
        assert_eq!(flow.status().state, "connected");
        assert_eq!(
            db.query_row("SELECT count(*) FROM google_sync", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            db.query_row("SELECT title FROM events WHERE id='local'", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "Keep"
        );
        drop(db);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn pairing_protocol_keeps_secrets_out_of_frontend_status() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let peer = thread::spawn(move || {
            for n in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut headers = String::new();
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    headers.push_str(&line);
                    if line == "\r\n" {
                        break;
                    }
                }
                if n == 1 {
                    assert!(headers
                        .to_lowercase()
                        .contains(&format!("authorization: bearer {}", "s".repeat(43))));
                }
                let body=if n==0 {json!({"id":"i".repeat(43),"poll_secret":"s".repeat(43),"verification_uri":format!("{ORIGIN}/connect/{}","i".repeat(43)),"user_code":"123456","expires_in":600,"interval":5})}
                    else {json!({"status":"complete","account":{"email":"person@example.test"},"credentials":relay()})}.to_string();
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
            }
        });
        let flow = Onboarding::default();
        flow.0.lock().unwrap().revision = 1;
        flow.run_with(1, &format!("http://{address}"), Duration::ZERO)
            .unwrap();
        peer.join().unwrap();
        let status = serde_json::to_string(&flow.status()).unwrap();
        assert!(status.contains("person@example.test"));
        assert!(!status.contains("encrypted.test"));
        assert!(!status.contains(&"s".repeat(43)));
        assert_eq!(flow.status().state, "confirm");
        let rows = qr_rows(&format!("{ORIGIN}/connect/{}", "i".repeat(43))).unwrap();
        assert!(rows.len() >= 21);
        assert!(rows.iter().all(|r| r.len() == rows.len()));
        assert!(flow.0.lock().unwrap().credentials.is_some());
        flow.cancel();
        assert!(flow.0.lock().unwrap().credentials.is_none());
    }
}
