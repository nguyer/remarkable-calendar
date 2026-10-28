//! One background sync per app process; the HTTP reader keeps its own SQLite connection.
use crate::{google, settings, Result};
use rusqlite::Connection;
use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
};

#[derive(Clone, Serialize)]
pub struct Status {
    pub state: &'static str,
    pub kind: &'static str,
    pub message: String,
    pub completed: usize,
    pub total: usize,
}
#[derive(Clone)]
pub struct SyncJob(Arc<Mutex<Status>>);
impl Default for SyncJob {
    fn default() -> Self {
        Self(Arc::new(Mutex::new(Status {
            state: "idle",
            kind: "sync",
            message: String::new(),
            completed: 0,
            total: 0,
        })))
    }
}
impl SyncJob {
    pub fn status(&self) -> Status {
        self.0.lock().unwrap().clone()
    }
    fn update(&self, message: &str) {
        self.0.lock().unwrap().message = message.into();
    }
    fn reserve(&self, total: usize) -> bool {
        let mut status = self.0.lock().unwrap();
        if status.state == "running" {
            return false;
        }
        *status = Status {
            state: "running",
            kind: "sync",
            message: "Connecting to Google…".into(),
            completed: 0,
            total,
        };
        true
    }
    fn finish(&self, error: Option<String>) {
        let mut s = self.0.lock().unwrap();
        if let Some(error) = error {
            s.state = "failed";
            s.message = format!("Sync failed ({}/{} calendars updated): {error}. Previous cache kept for calendars that did not finish.",s.completed,s.total);
            if s.kind == "calendars" {
                s.message =
                    format!("Calendar list refresh failed: {error}. Cached events unchanged.");
            }
        } else {
            s.state = "succeeded";
            s.message = if s.kind == "calendars" {
                "Calendar list updated"
            } else {
                "Sync complete"
            }
            .into();
        }
    }
    pub fn start(&self, db: &Connection) -> Result<bool> {
        self.start_mode(db, false)
    }
    pub fn discover(&self, db: &Connection) -> Result<bool> {
        self.start_mode(db, true)
    }
    fn start_mode(&self, db: &Connection, discovery: bool) -> Result<bool> {
        if self.status().state == "running" {
            return Ok(false);
        }
        let plans = if discovery {
            vec![]
        } else {
            match settings::plans(db, chrono::Utc::now()) {
                Ok(plans) => plans,
                Err(_) if crate::edits::count(db)? > 0 => vec![],
                Err(e) => return Err(e),
            }
        };
        let path = PathBuf::from(db.path().ok_or("cannot locate calendar database")?);
        if !self.reserve(if discovery { 1 } else { plans.len().max(1) }) {
            return Ok(false);
        }
        if discovery {
            self.0.lock().unwrap().kind = "calendars";
        }
        let job = self.clone();
        if let Err(e) = thread::Builder::new()
            .name("google-sync".into())
            .spawn(move || {
                // Recover the job status even if the worker panics; another tap can retry.
                let outcome =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
                        let mut db = crate::database(&path)?;
                        if !discovery {
                            crate::edits::flush(&mut db, |message| job.update(message))?;
                        }
                        job.update("Refreshing calendar list…");
                        google::refresh_catalog(&mut db)?;
                        if discovery {
                            job.0.lock().unwrap().completed = 1;
                        }
                        for args in plans {
                            google::sync_with_progress(&mut db, &args, |message| {
                                job.update(message)
                            })?;
                            job.0.lock().unwrap().completed += 1;
                        }
                        Ok(())
                    }));
                let error = match outcome {
                    Ok(Ok(())) => None,
                    Ok(Err(e)) => Some(e.to_string()),
                    Err(_) => Some("sync stopped unexpectedly; tap Sync to retry".into()),
                };
                job.finish(error);
            })
        {
            self.finish(Some("could not start background sync".into()));
            return Err(e.into());
        }
        Ok(true)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn single_flight_progress_and_retry() {
        let job = SyncJob::default();
        assert!(job.reserve(2));
        let other = job.clone();
        assert!(!other.reserve(2));
        job.update("Fetching events…");
        assert_eq!(other.status().message, "Fetching events…");
        job.0.lock().unwrap().completed = 1;
        job.finish(Some("offline".into()));
        assert_eq!(other.status().state, "failed");
        assert_eq!(other.status().completed, 1);
        assert!(other.reserve(1));
        other.finish(None);
        assert_eq!(job.status().state, "succeeded");
    }
}
