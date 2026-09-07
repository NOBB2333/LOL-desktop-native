CREATE TABLE IF NOT EXISTS snapshots (
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(kind, key)
) STRICT;
