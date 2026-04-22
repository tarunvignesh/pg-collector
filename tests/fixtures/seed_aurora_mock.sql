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
CREATE OR REPLACE VIEW pgc_aurora_mock.pg_settings AS
SELECT * FROM pg_catalog.pg_settings
UNION ALL
SELECT
    'rds.extensions'::text                        AS name,
    'aurora_stat_utils'::text                     AS setting,
    'kB'::text                                    AS unit,
    'Customized Options'::text                    AS category,
    'Mock for Aurora detection'::text             AS short_desc,
    NULL::text                                    AS extra_desc,
    'user'::text                                  AS context,
    'string'::text                                AS vartype,
    'default'::text                               AS source,
    NULL::text                                    AS min_val,
    NULL::text                                    AS max_val,
    NULL::text[]                                  AS enumvals,
    'aurora_stat_utils'::text                     AS boot_val,
    'aurora_stat_utils'::text                     AS reset_val,
    NULL::text                                    AS sourcefile,
    NULL::int                                     AS sourceline,
    false                                         AS pending_restart;

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
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_db_instance_identifier()
RETURNS TABLE (server_id text) LANGUAGE sql AS
$$ SELECT 'mock-aurora-instance-1'::text $$;

-- ---------- aurora_replica_status ----------
CREATE OR REPLACE FUNCTION pgc_aurora_mock.aurora_replica_status()
RETURNS TABLE (
    server_id text,
    session_id text,
    highest_lsn_rcvd text,
    current_read_lsn text,
    last_update_timestamp timestamptz,
    durability_lag_in_msec bigint,
    feedback_xmin text,
    feedback_epoch bigint,
    cur_replay_latency_in_usec bigint,
    active_lsn text
) LANGUAGE sql AS
$$ SELECT NULL::text, NULL::text, NULL::text, NULL::text, NULL::timestamptz,
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

-- ---------- Grants ----------
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgc_aurora_mock TO PUBLIC;

\echo Aurora mock installed. Reconnect for the new search_path to apply.
