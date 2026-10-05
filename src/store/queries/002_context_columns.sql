-- ============================================================================
-- 002: Add context columns (route, environment, release, user info, request)
-- ============================================================================
-- Run after 001_create_error_tables.sql
--
-- Adds:
--   error_groups: environment, release, route (denormalized for filtering)
--   error_reports: route, url, session_id, user_agent, environment, release,
--                  user_id, request_method, request_url, request_status_code,
--                  request_body, request_elapsed_ms
-- ============================================================================

-- Denormalized onto groups for filtering/display without joining reports
ALTER TABLE error_groups
    ADD COLUMN IF NOT EXISTS environment TEXT,
    ADD COLUMN IF NOT EXISTS release     TEXT,
    ADD COLUMN IF NOT EXISTS route       TEXT;

-- Full context on each individual report
ALTER TABLE error_reports
    ADD COLUMN IF NOT EXISTS url                  TEXT,
    ADD COLUMN IF NOT EXISTS user_agent            TEXT,
    ADD COLUMN IF NOT EXISTS environment           TEXT,
    ADD COLUMN IF NOT EXISTS release               TEXT,
    ADD COLUMN IF NOT EXISTS user_id               TEXT,
    ADD COLUMN IF NOT EXISTS request_method        TEXT,
    ADD COLUMN IF NOT EXISTS request_url           TEXT,
    ADD COLUMN IF NOT EXISTS request_status_code   INTEGER,
    ADD COLUMN IF NOT EXISTS request_body          TEXT,
    ADD COLUMN IF NOT EXISTS request_elapsed_ms    BIGINT;

-- Note: route and session_id already exist on error_reports from 001

-- Indexes for common filters
CREATE INDEX IF NOT EXISTS idx_error_groups_environment ON error_groups (environment);
CREATE INDEX IF NOT EXISTS idx_error_groups_release     ON error_groups (release);
CREATE INDEX IF NOT EXISTS idx_error_reports_session    ON error_reports (session_id);
CREATE INDEX IF NOT EXISTS idx_error_reports_user       ON error_reports (user_id);
CREATE INDEX IF NOT EXISTS idx_error_reports_route      ON error_reports (route);
