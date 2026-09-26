CREATE TABLE station_reports (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    report_type TEXT NOT NULL CHECK (report_type IN ('missing', 'correction')),
    station_name TEXT NOT NULL,
    station_code TEXT,
    suggested_code TEXT,
    lines TEXT,
    operator TEXT,
    city TEXT,
    country TEXT,
    notes TEXT,
    latitude REAL,
    longitude REAL,
    accuracy_meters REAL,
    card_family TEXT,
    card_id_hash TEXT,
    app_version TEXT NOT NULL,
    device_id TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('web', 'ios', 'android')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'rejected'))
);

CREATE INDEX station_reports_status_created_at ON station_reports(status, created_at);
CREATE INDEX station_reports_station_code ON station_reports(station_code);
