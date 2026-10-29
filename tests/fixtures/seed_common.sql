-- seed_common.sql — minimal baseline for running pg_collector in CI
--
-- Creates:
--   - pgc_admin: owns the fixture, can mutate system settings
--   - pgc_runner: read-only role that runs pg_collector.sql against the DB.
--                 On PG14+ this is `pg_read_all_data`; on older PG, explicit
--                 SELECT grants.
--   - a small schema (tables, indexes, rows) so the report has content
--     beyond empty system catalogs.
--
-- Run as a superuser (the CI container's `postgres` user).

\set ON_ERROR_STOP on

-- ---------- Roles ----------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgc_admin') THEN
        CREATE ROLE pgc_admin WITH LOGIN PASSWORD 'admin';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgc_runner') THEN
        CREATE ROLE pgc_runner WITH LOGIN PASSWORD 'runner';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE :"DBNAME" TO pgc_runner;
GRANT CONNECT ON DATABASE :"DBNAME" TO pgc_admin;

-- ---------- Schema owned by pgc_admin ----------
CREATE SCHEMA IF NOT EXISTS pgc_fixture AUTHORIZATION pgc_admin;
GRANT USAGE ON SCHEMA pgc_fixture TO pgc_runner;
GRANT USAGE ON SCHEMA public TO pgc_runner;

SET ROLE pgc_admin;

CREATE TABLE IF NOT EXISTS pgc_fixture.accounts (
    id bigserial PRIMARY KEY,
    email text NOT NULL UNIQUE,
    display_name text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pgc_fixture.events (
    id bigserial PRIMARY KEY,
    account_id bigint NOT NULL REFERENCES pgc_fixture.accounts(id),
    kind text NOT NULL,
    payload jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS events_account_id_idx
    ON pgc_fixture.events(account_id);
CREATE INDEX IF NOT EXISTS events_kind_idx
    ON pgc_fixture.events(kind);

-- Enough rows for pg_stat_user_tables to show meaningful numbers.
INSERT INTO pgc_fixture.accounts (email, display_name)
SELECT 'user' || g || '@example.test', 'User ' || g
FROM generate_series(1, 50) g
ON CONFLICT (email) DO NOTHING;

INSERT INTO pgc_fixture.events (account_id, kind, payload)
SELECT
    (random() * 49 + 1)::bigint,
    (ARRAY['login', 'view', 'click', 'logout'])[1 + (random() * 3)::int],
    jsonb_build_object('seed', g)
FROM generate_series(1, 500) g;

ANALYZE pgc_fixture.accounts;
ANALYZE pgc_fixture.events;

RESET ROLE;

-- ---------- Read-only grants for pgc_runner ----------
-- Granting every read privilege means the only remaining source of
-- `permission denied` is an attempt to *write* -- which is exactly what the
-- runner wants to detect. Getting the version split wrong therefore does not
-- just weaken the fixture, it manufactures false write accusations.
--
-- pg_read_all_stats, pg_read_all_settings, pg_read_server_files and pg_monitor
-- are all PG10+. Only pg_read_all_data is PG14+, so only that one is gated.
-- Gating the whole block on PG14 left a PG13 runner with none of them, and the
-- resulting `must be superuser or a member of pg_read_all_settings to examine
-- "data_directory"` was reported as an attempted write.
GRANT pg_read_all_stats TO pgc_runner;
GRANT pg_read_all_settings TO pgc_runner;
GRANT pg_read_server_files TO pgc_runner;
GRANT pg_monitor TO pgc_runner;

-- These default to superuser-only EXECUTE in recent PG; they are read-only and
-- PG Collector calls them directly. Not grantable on every major, hence the
-- swallowed exception.
DO $$
BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_hba_file_rules() TO pgc_runner';
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
-- On PG13 pg_hba_file_rules is a view whose SELECT privilege is separate from
-- EXECUTE on the backing function; granting only the function still leaves
-- `permission denied for view pg_hba_file_rules`.
DO $$
BEGIN
    EXECUTE 'GRANT SELECT ON pg_hba_file_rules TO pgc_runner';
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_config() TO pgc_runner';
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_ls_tmpdir() TO pgc_runner';
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_ls_tmpdir(oid) TO pgc_runner';
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT current_setting('server_version_num')::int >= 140000 AS has_read_all_data \gset

\if :has_read_all_data
    GRANT pg_read_all_data TO pgc_runner;
\else
    -- No blanket read role before PG14; grant object-by-object instead.
    GRANT SELECT ON ALL TABLES IN SCHEMA pgc_fixture TO pgc_runner;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgc_runner;
    -- Sequences are not tables. pg_sequences.last_value reads NULL for a
    -- sequence the caller cannot SELECT, which silently defeats the
    -- "sequence near max" health check rather than erroring.
    GRANT SELECT ON ALL SEQUENCES IN SCHEMA pgc_fixture TO pgc_runner;
    GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA pgc_fixture
        GRANT SELECT ON TABLES TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA public
        GRANT SELECT ON TABLES TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA pgc_fixture
        GRANT SELECT ON SEQUENCES TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA public
        GRANT SELECT ON SEQUENCES TO pgc_runner;
\endif

-- pg_stat_statements requires explicit grant on its functions for non-superusers
-- in some PG versions. No-op if the extension isn't installed.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        EXECUTE 'GRANT pg_read_all_stats TO pgc_runner';
    END IF;
EXCEPTION WHEN OTHERS THEN
    -- Already granted above on every supported major; ignore a re-grant error.
    NULL;
END
$$;

\echo Seeded pgc_fixture with baseline schema, 50 accounts, 500 events.
