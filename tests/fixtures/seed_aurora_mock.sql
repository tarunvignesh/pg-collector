-- seed_aurora_mock.sql — make community Postgres look like Amazon Aurora
-- to PG Collector's detection logic.
--
-- PG Collector decides "this is Aurora" by checking
--     pg_settings.setting LIKE '%aurora_stat_utils%' WHERE name = 'rds.extensions'
-- and then calls a dozen `aurora_*()` functions. On community Postgres those
-- functions don't exist, so the Aurora branch errors out section-by-section.
--
-- This fixture:
--   1. Sets rds.extensions so `\if :isaurora` evaluates true.
--   2. Defines stub implementations of every `aurora_*` function PG Collector
--      calls. Stubs return plausible, usually-empty result sets with column
--      names matching what the script SELECTs. Column name/type mismatches
--      in rarely-executed branches are acceptable — the goal is to prove
--      the Aurora code path runs without crashing `psql`, not to produce a
--      faithful Aurora report.
--
-- Run as superuser. Depends on nothing.

\set ON_ERROR_STOP on

-- Functions live in a dedicated schema so we don't shadow anything.
CREATE SCHEMA IF NOT EXISTS pgc_aurora_mock;
GRANT USAGE ON SCHEMA pgc_aurora_mock TO PUBLIC;

-- Shadow pg_catalog.pg_settings so the script's detection query
--   SELECT ... FROM pg_settings WHERE name='rds.extensions' AND setting LIKE ...
-- returns a row. Custom GUCs on unreserved prefixes (e.g. "rds.") don't
-- appear in pg_catalog.pg_settings on modern Postgres unless a C extension
-- registers them via DefineCustomStringVariable. A view in an earlier
-- search_path entry is the lightest mock that makes the Aurora branch fire.
-- The injected row lives in a real table rather than a constant SELECT.
-- A `SELECT 'aurora_stat_utils'::text ...` with no FROM plans as a Result
-- node, so the planner constant-folds any cast applied to it — and the
-- script casts settings to bigint (e.g. the autovacuum_freeze_max_age
-- health check does `setting::bigint > 200000000`). Folding runs at plan
-- time, before the `name = '...'` qual can exclude this row, so the whole
-- statement aborts with `invalid input syntax for type bigint`. Reading
-- from a table makes it a scan whose quals are ordered by cost, matching
-- how pg_catalog.pg_settings (a set-returning-function view) behaves.
CREATE TABLE IF NOT EXISTS pgc_aurora_mock.injected_settings (
    LIKE pg_catalog.pg_settings
);

TRUNCATE pgc_aurora_mock.injected_settings;
INSERT INTO pgc_aurora_mock.injected_settings
    (name, setting, unit, category, short_desc, extra_desc, context,
     vartype, source, min_val, max_val, enumvals, boot_val, reset_val,
     sourcefile, sourceline, pending_restart)
VALUES
    ('rds.extensions', 'aurora_stat_utils', 'kB', 'Customized Options',
     'Mock for Aurora detection', NULL, 'user', 'string', 'default',
     NULL, NULL, NULL, 'aurora_stat_utils', 'aurora_stat_utils',
     NULL, NULL, false);

GRANT SELECT ON pgc_aurora_mock.injected_settings TO PUBLIC;

CREATE OR REPLACE VIEW pgc_aurora_mock.pg_settings AS
SELECT * FROM pg_catalog.pg_settings
UNION ALL
SELECT * FROM pgc_aurora_mock.injected_settings;

GRANT SELECT ON pgc_aurora_mock.pg_settings TO PUBLIC;

-- Put the mock schema at the front of search_path — BEFORE pg_catalog, so
-- unqualified references to pg_settings and aurora_* functions resolve
-- here. pg_catalog is implicitly first by default; naming it explicitly
-- after pgc_aurora_mock overrides that.
ALTER DATABASE :"DBNAME" SET search_path = pgc_aurora_mock, pg_catalog, public;

-- ---------- aurora_version ----------
-- Returns a scalar. Script selects `aurora_version()` as text and also does
--   FROM aurora_version() WHERE substring(aurora_version,1,5) ...
-- Both shapes work because a single-column table-valued function has an
-- implicit column named after the function.
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_version()
RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT '13.15.00'::text $$;

-- ---------- aurora_list_builtins ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_list_builtins()
RETURNS TABLE (name text, description text) LANGUAGE sql AS
$$ SELECT NULL::text, NULL::text WHERE false $$;

-- ---------- aurora_db_instance_identifier ----------
-- Returns a scalar, matching real Aurora. Declaring it RETURNS TABLE
-- (server_id text) gave the result a column of its own named server_id, so
-- the replica-status join `FROM aurora_replica_status() rt,
-- aurora_db_instance_identifier() di WHERE rt.server_id = di` failed with
-- "column reference server_id is ambiguous".
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_db_instance_identifier()
RETURNS text LANGUAGE sql AS
$$ SELECT 'mock-aurora-instance-1'::text $$;

-- ---------- aurora_replica_status ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_replica_status()
RETURNS TABLE (
    server_id text,
    session_id text,
    highest_lsn_rcvd text,
    current_read_lsn text,
    last_update_timestamp timestamptz,
    replica_lag_in_msec double precision,
    durability_lag_in_msec bigint,
    feedback_xmin text,
    feedback_epoch bigint,
    cur_replay_latency_in_usec bigint,
    active_lsn text
) LANGUAGE sql AS
$$ SELECT NULL::text, NULL::text, NULL::text, NULL::text, NULL::timestamptz,
         NULL::double precision,
         NULL::bigint, NULL::text, NULL::bigint, NULL::bigint, NULL::text
   WHERE false $$;

-- ---------- aurora_global_db_status ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_global_db_status()
RETURNS TABLE (
    server_id text,
    durability_lag_in_msec text,
    feedback_xmin text,
    visibility_lag_in_msec bigint
) LANGUAGE sql AS
$$ SELECT NULL::text, NULL::text, NULL::text, NULL::bigint WHERE false $$;

-- ---------- aurora_ccm_status ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_ccm_status()
RETURNS TABLE (
    buffers_sent_last_minute bigint,
    buffers_sent_last_scan bigint,
    buffers_found_last_scan bigint,
    current_buffer_usage_pct numeric
) LANGUAGE sql AS
$$ SELECT NULL::bigint, NULL::bigint, NULL::bigint, NULL::numeric WHERE false $$;

-- ---------- aurora_stat_system_waits / wait_event / wait_type ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_system_waits()
RETURNS TABLE (type_id int, event_id int, waits bigint, wait_time bigint)
LANGUAGE sql AS
$$ SELECT NULL::int, NULL::int, NULL::bigint, NULL::bigint WHERE false $$;

CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_wait_event()
RETURNS TABLE (event_id int, event_name text)
LANGUAGE sql AS
$$ SELECT NULL::int, NULL::text WHERE false $$;

CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_wait_type()
RETURNS TABLE (type_id int, type_name text)
LANGUAGE sql AS
$$ SELECT NULL::int, NULL::text WHERE false $$;

-- ---------- aurora_stat_dml_activity ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_dml_activity(oid)
RETURNS TABLE (
    inserts bigint,
    updates bigint,
    deletes bigint,
    hot_updates bigint
) LANGUAGE sql AS
$$ SELECT 0::bigint, 0::bigint, 0::bigint, 0::bigint WHERE false $$;

-- ---------- aurora_stat_memctx_usage ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_memctx_usage()
RETURNS TABLE (
    pid int,
    name text,
    allocated bigint,
    used bigint,
    instances int
) LANGUAGE sql AS
$$ SELECT NULL::int, NULL::text, NULL::bigint, NULL::bigint, NULL::int WHERE false $$;

-- ---------- aurora_stat_logical_wal_cache ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_logical_wal_cache()
RETURNS TABLE (
    cache_size bigint,
    cache_hits bigint,
    cache_misses bigint
) LANGUAGE sql AS
$$ SELECT NULL::bigint, NULL::bigint, NULL::bigint WHERE false $$;

-- ---------- aurora_stat_statements ----------
-- Added upstream in the 2026-06 release ("Aurora pg_stat_statements"
-- section). Same shape as pg_stat_statements plus Aurora's storage-layer
-- counters (storage_blks_read, orcache_blks_hit).
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_statements()
RETURNS TABLE (
    queryid bigint,
    query text,
    calls bigint,
    rows bigint,
    total_exec_time double precision,
    mean_exec_time double precision,
    stddev_exec_time double precision,
    shared_blks_read bigint,
    storage_blks_read bigint,
    orcache_blks_hit bigint
) LANGUAGE sql AS
$$ SELECT NULL::bigint, NULL::text, NULL::bigint, NULL::bigint,
          NULL::double precision, NULL::double precision,
          NULL::double precision,
          NULL::bigint, NULL::bigint, NULL::bigint
   WHERE false $$;

-- ---------- aurora_stat_plans ----------
-- Added upstream in the 2026-06 release ("Aurora stat plans" section).
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_stat_plans()
RETURNS TABLE (
    queryid bigint,
    planid bigint,
    dbid oid,
    query text,
    explain_plan text,
    plan_type text,
    plan_captured_time timestamptz,
    calls bigint,
    rows bigint,
    total_exec_time double precision,
    mean_exec_time double precision,
    stddev_exec_time double precision,
    shared_blks_read bigint,
    storage_blks_read bigint,
    orcache_blks_hit bigint
) LANGUAGE sql AS
$$ SELECT NULL::bigint, NULL::bigint, NULL::oid, NULL::text, NULL::text,
          NULL::text, NULL::timestamptz, NULL::bigint, NULL::bigint,
          NULL::double precision, NULL::double precision,
          NULL::double precision,
          NULL::bigint, NULL::bigint, NULL::bigint
   WHERE false $$;

-- ---------- Grants ----------
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgc_aurora_mock TO PUBLIC;

\echo Aurora mock installed. Reconnect for the new search_path to apply.
