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
SELECT current_setting('server_version_num')::int >= 140000 AS has_read_all_data \gset

\if :has_read_all_data
    -- All read-only predefined roles we can grant. Granting every read
    -- privilege means the only remaining source of `permission denied` is
    -- an attempt to *write* — which is exactly what we want to detect.
    GRANT pg_read_all_data TO pgc_runner;
    GRANT pg_read_all_stats TO pgc_runner;
    GRANT pg_read_all_settings TO pgc_runner;
    GRANT pg_read_server_files TO pgc_runner;
    GRANT pg_monitor TO pgc_runner;
    -- These functions default to superuser-only EXECUTE in recent PG; they
    -- are read-only and PG Collector calls them directly.
    DO $$
    BEGIN
        EXECUTE 'GRANT EXECUTE ON FUNCTION pg_hba_file_rules() TO pgc_runner';
    EXCEPTION WHEN OTHERS THEN NULL;
    END $$;
    DO $$
    BEGIN
        EXECUTE 'GRANT EXECUTE ON FUNCTION pg_config() TO pgc_runner';
    EXCEPTION WHEN OTHERS THEN NULL;
    END $$;
\else
    GRANT SELECT ON ALL TABLES IN SCHEMA pgc_fixture TO pgc_runner;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA pgc_fixture
        GRANT SELECT ON TABLES TO pgc_runner;
    ALTER DEFAULT PRIVILEGES FOR ROLE pgc_admin IN SCHEMA public
        GRANT SELECT ON TABLES TO pgc_runner;
\endif

-- pg_stat_statements requires explicit grant on its functions for non-superusers
-- in some PG versions. No-op if the extension isn't installed.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        EXECUTE 'GRANT pg_read_all_stats TO pgc_runner';
    END IF;
EXCEPTION WHEN OTHERS THEN
    -- pg_read_all_stats doesn't exist on PG<14; ignore.
    NULL;
END
$$;

\echo Seeded pgc_fixture with baseline schema, 50 accounts, 500 events.
