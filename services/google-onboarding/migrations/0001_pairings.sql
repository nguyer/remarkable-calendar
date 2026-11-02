CREATE TABLE pairings (
    id TEXT PRIMARY KEY,
    poll_hash TEXT NOT NULL,
    user_code TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending','authorizing','exchanging','ready','denied','error')),
    expires_at INTEGER NOT NULL,
    oauth_hash TEXT UNIQUE,
    verifier TEXT,
    grant TEXT,
    email TEXT
);
CREATE INDEX pairings_expiry ON pairings(expires_at);
