import sqlite3
from contextlib import closing
from pathlib import Path


SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
  verified INTEGER NOT NULL DEFAULT 0, verification_hash TEXT,
  mailbox_verification_version INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'suspended')),
  created_at TEXT NOT NULL, last_active_at TEXT,
  matching_paused INTEGER NOT NULL DEFAULT 0 CHECK(matching_paused IN (0, 1))
);
CREATE TABLE IF NOT EXISTS auth_sessions (
  token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_sessions_user_id ON auth_sessions(user_id);
CREATE TABLE IF NOT EXISTS pending_registrations (
  email TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_attempts (
  id INTEGER PRIMARY KEY, bucket TEXT NOT NULL, attempted_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_attempts_bucket_time ON auth_attempts(bucket, attempted_at);
CREATE INDEX IF NOT EXISTS auth_attempts_time ON auth_attempts(attempted_at);
CREATE TABLE IF NOT EXISTS profiles (
  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS preferences (
  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  data TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS answers (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  question_id INTEGER NOT NULL CHECK(question_id BETWEEN 1 AND 64),
  value INTEGER NOT NULL CHECK(value BETWEEN 1 AND 5),
  PRIMARY KEY(user_id, question_id)
);
CREATE TABLE IF NOT EXISTS photos (
  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  image BLOB NOT NULL, approved INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS cycles (
  id TEXT PRIMARY KEY, generated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS weekly_matches (
  cycle_id TEXT NOT NULL REFERENCES cycles(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  candidate_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rank INTEGER NOT NULL CHECK(rank BETWEEN 1 AND 3),
  score REAL NOT NULL, breakdown TEXT NOT NULL,
  PRIMARY KEY(cycle_id, user_id, candidate_id), UNIQUE(cycle_id, user_id, rank)
);
CREATE TABLE IF NOT EXISTS reactions (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  candidate_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('like', 'pass')),
  created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, candidate_id)
);
CREATE TABLE IF NOT EXISTS blocks (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY(user_id, target_id)
);
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY, reporter_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  target_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT NOT NULL, created_at TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open'
);
CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY, user_low INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL, UNIQUE(user_low, user_high)
);
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT
);
CREATE TABLE IF NOT EXISTS moderation_actions (
  id INTEGER PRIMARY KEY, target_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL, created_at TEXT NOT NULL
);
"""


def connect(path):
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA busy_timeout = 30000")
    return db


def initialize(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with closing(connect(path)) as db:
        db.executescript(SCHEMA)
        with db:
            db.execute("BEGIN IMMEDIATE")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(users)")}
            if "last_active_at" not in columns:
                db.execute("ALTER TABLE users ADD COLUMN last_active_at TEXT")
            if "matching_paused" not in columns:
                db.execute("ALTER TABLE users ADD COLUMN matching_paused INTEGER NOT NULL DEFAULT 0 CHECK(matching_paused IN (0, 1))")
            if "mailbox_verification_version" not in columns:
                db.execute("ALTER TABLE users ADD COLUMN mailbox_verification_version INTEGER NOT NULL DEFAULT 1")
                db.execute("UPDATE users SET verified=0, verification_hash=NULL")
