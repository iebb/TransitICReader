CREATE TABLE IF NOT EXISTS korean_trip_records (
    dedup_hash TEXT PRIMARY KEY,
    hashed_card_id TEXT NOT NULL,
    card_id_last4 TEXT NOT NULL,
    bytes_05_08 TEXT NOT NULL,
    bytes_09_0a TEXT NOT NULL,
    all_bytes TEXT NOT NULL,
    card_family TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_korean_trip_records_hashed_card_id
ON korean_trip_records (hashed_card_id);

CREATE INDEX IF NOT EXISTS idx_korean_trip_records_card_family
ON korean_trip_records (card_family);
