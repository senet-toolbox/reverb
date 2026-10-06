-- ============================================================================
-- Error Tracking Schema
-- ============================================================================
-- Run this once to create the required tables.
-- The error_groups table uses a SHA-256 fingerprint for deduplication.
-- Timestamps are stored as timestamptz; the Zig code sends microseconds
-- since epoch as i64 and pg.zig binds them natively.
-- ============================================================================

CREATE TABLE IF NOT EXISTS error_groups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint     TEXT NOT NULL UNIQUE,
    error_type      TEXT NOT NULL,
    message         TEXT NOT NULL,
    crash_function  TEXT,
    crash_file      TEXT,
    crash_line      INTEGER,
    is_wasm_trap    BOOLEAN NOT NULL DEFAULT false,
    occurrence_count INTEGER NOT NULL DEFAULT 1,
    first_seen      TIMESTAMPTZ NOT NULL,
    last_seen       TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'unresolved',
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_error_groups_status    ON error_groups (status);
CREATE INDEX IF NOT EXISTS idx_error_groups_last_seen ON error_groups (last_seen DESC);

CREATE TABLE IF NOT EXISTS error_reports (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id          UUID NOT NULL REFERENCES error_groups(id) ON DELETE CASCADE,
    error_id          TEXT NOT NULL,
    error_type        TEXT NOT NULL,
    message           TEXT NOT NULL,
    is_wasm_trap      BOOLEAN NOT NULL DEFAULT false,
    callback_args     JSONB,
    element_type      TEXT,
    route             TEXT,
    session_id        TEXT,
    timestamp         TIMESTAMPTZ NOT NULL,
    crash_function    TEXT,
    crash_file        TEXT,
    crash_line        INTEGER,
    crash_column      INTEGER,
    crash_wasm_index  INTEGER,
    crash_wasm_offset TEXT,
    crash_frame_type  TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_error_reports_group_id  ON error_reports (group_id);
CREATE INDEX IF NOT EXISTS idx_error_reports_timestamp ON error_reports (timestamp DESC);

CREATE TABLE IF NOT EXISTS stack_frames (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_report_id   UUID NOT NULL REFERENCES error_reports(id) ON DELETE CASCADE,
    position          INTEGER NOT NULL,
    function_name     TEXT,
    file              TEXT,
    line              INTEGER,
    col               INTEGER,
    wasm_function_index INTEGER,
    wasm_offset       TEXT,
    frame_type        TEXT
);

CREATE INDEX IF NOT EXISTS idx_stack_frames_report ON stack_frames (error_report_id);

CREATE TABLE IF NOT EXISTS trace_events (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    error_report_id   UUID NOT NULL REFERENCES error_reports(id) ON DELETE CASCADE,
    event_type        TEXT NOT NULL,
    element_id        TEXT,
    serialized_args   JSONB,
    timestamp         TIMESTAMPTZ NOT NULL,
    delta_ms          INTEGER
);

CREATE INDEX IF NOT EXISTS idx_trace_events_report ON trace_events (error_report_id);
