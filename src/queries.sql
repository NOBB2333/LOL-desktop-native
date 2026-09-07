-- name: configGet
SELECT json FROM app_config WHERE id = 1;

-- name: configSet :exec
INSERT INTO app_config(id, json, updated_at) VALUES (1, :json, :updated_at)
ON CONFLICT(id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at;

-- name: encountersRecent
SELECT json FROM encounters ORDER BY encountered_at DESC LIMIT :limit;

-- name: bpHistoryRecent
SELECT json FROM bp_history ORDER BY created_at DESC LIMIT :limit;

-- name: snapshotGet
SELECT value FROM snapshots WHERE kind = :kind AND key = :key;

-- name: snapshotSet :exec
INSERT INTO snapshots(kind, key, value, updated_at) VALUES (:kind, :key, :value, :updated_at)
ON CONFLICT(kind, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
