-- seed_health_checks.sql — trigger each PG Collector Observations check.
--
-- Runs as a superuser; manipulates `pg_catalog` rows and GUCs to force every
-- check in the health-check list into the "warn" state. Checks that cannot be
-- reliably tripped in a CI-speed window are documented inline as
-- `unreachable in CI`.
--
-- Scope matters here. `ALTER SYSTEM` writes postgresql.auto.conf, which is
-- cluster-wide and survives `dropdb` -- so it leaks out of run.sh --isolate's
-- temporary database and permanently reconfigures the caller's cluster. Worse,
-- a leaked `track_counts = off` silently breaks the *next* run: no tuple stats
-- accumulate, so the dead-rows check can never fire again.
--
-- Every GUC whose context is `user` or `superuser` is therefore set with
-- `ALTER DATABASE`, which dropdb removes with the database. Only `autovacuum`
-- (context `sighup`) genuinely needs `ALTER SYSTEM`; run.sh resets that one
-- explicitly on exit.
--
-- `ALTER DATABASE ... SET` applies to *new* sessions, not this one, so the
-- seeding below still runs with counters enabled.
--
-- Depends on seed_common.sql.

\set ON_ERROR_STOP on

SET client_min_messages TO WARNING;

-- ---------- 1. Duplicate indexes ----------
-- Create two indexes with identical keys on the same table.
CREATE INDEX IF NOT EXISTS events_kind_dup_a ON pgc_fixture.events(kind);
CREATE INDEX IF NOT EXISTS events_kind_dup_b ON pgc_fixture.events(kind);

-- ---------- 2. Invalid indexes ----------
-- Build an index, then mark it invalid via catalog update. This is a superuser
-- operation and only happens once at fixture load — production never does it.
CREATE INDEX IF NOT EXISTS events_invalid_idx ON pgc_fixture.events(id);
UPDATE pg_index
   SET indisvalid = false
 WHERE indexrelid = 'pgc_fixture.events_invalid_idx'::regclass;

-- ---------- 3. Unused indexes ----------
-- The v3.2 check looks for idx_scan = 0. `events_invalid_idx` just created
-- above has zero scans; so does `events_kind_dup_b`. No extra action needed.

-- ---------- 4. autovacuum disabled ----------
-- context 'sighup': ALTER DATABASE cannot set it, so this one is cluster-wide.
-- run.sh's --isolate trap runs `ALTER SYSTEM RESET autovacuum` on exit.
ALTER SYSTEM SET autovacuum = 'off';

-- ---------- 5. Sequences with <10% remaining ----------
CREATE SEQUENCE IF NOT EXISTS pgc_fixture.near_wrap MAXVALUE 100;
SELECT setval('pgc_fixture.near_wrap', 95);
-- Grant here, not in seed_common.sql: that file runs first, and GRANT ON ALL
-- SEQUENCES only covers sequences that already exist. Before PG14 there is no
-- pg_read_all_data to fall back on, and pg_sequences.last_value reads NULL --
-- not an error -- for a sequence the caller cannot SELECT, so without this the
-- check silently reports "OK" on PG13 instead of firing.
GRANT SELECT ON SEQUENCE pgc_fixture.near_wrap TO pgc_runner;

-- ---------- 6. Orphaned prepared transactions ----------
-- The check uses `interval '5 minute'`; we can't wait that long in CI.
-- UNREACHABLE IN CI. Presence of the \if branch is asserted by the
-- report_assertions tests instead.

-- ---------- 7. Connections without SSL ----------
-- Default in the CI Postgres container (no SSL configured). Always trips.

-- ---------- 8. enable_indexonlyscan disabled ----------
ALTER DATABASE :"DBNAME" SET enable_indexonlyscan = 'off';

-- ---------- 9. Excessive logging parameters ----------
ALTER DATABASE :"DBNAME" SET log_statement = 'all';
ALTER DATABASE :"DBNAME" SET log_min_duration_statement = 0;

-- ---------- 10. track_counts disabled ----------
-- Deliberately deferred to after #14 (dead rows). Disabling track_counts
-- freezes pg_stat_all_tables counters, so any live/dead tuple seeding must
-- happen first. See end of this file.

-- ---------- 11. enable_indexscan disabled ----------
ALTER DATABASE :"DBNAME" SET enable_indexscan = 'off';

-- ---------- 12. synchronous_commit off ----------
ALTER DATABASE :"DBNAME" SET synchronous_commit = 'off';

-- ---------- 13. Invalid databases ----------
-- Marking a database invalid requires datconnlimit manipulation on recent PG
-- or a failed DROP, neither reliably fabricable. UNREACHABLE IN CI.

-- ---------- 14. Tables with >20% dead rows ----------
-- Disable autovacuum on the target so the dead tuples don't get reclaimed
-- between INSERT/DELETE and the pg_collector run.
CREATE TABLE IF NOT EXISTS pgc_fixture.dead_rows (id serial PRIMARY KEY, v text);
ALTER TABLE pgc_fixture.dead_rows SET (autovacuum_enabled = false);
-- v3.2 check requires (n_live_tup > 1000 OR n_dead_tup > 1000) AND
-- dead_pct > 20%. Populate with 2500 rows, delete 1000 -> 40% dead, both
-- tuple counts clearly above the 1000 threshold.
INSERT INTO pgc_fixture.dead_rows (v)
SELECT md5(g::text) FROM generate_series(1, 2500) g;
DELETE FROM pgc_fixture.dead_rows WHERE id <= 1000;
ANALYZE pgc_fixture.dead_rows;

-- ---------- 15. TXID wraparound ----------
-- Requires consuming ~2^31 transaction IDs. UNREACHABLE IN CI.

-- ---------- 16. Per-table autovacuum_enabled=off ----------
-- Already done for pgc_fixture.dead_rows above (#14). Re-assert on a
-- distinct table so the count isn't conflated.
CREATE TABLE IF NOT EXISTS pgc_fixture.autovac_off (id int);
ALTER TABLE pgc_fixture.autovac_off SET (autovacuum_enabled = false);

-- ---------- 17. Inactive replication slots ----------
-- Use a physical slot (works with wal_level=replica, the default).
-- If the slot already exists from a prior run, drop-and-recreate to ensure
-- it's idle.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'pgc_idle_slot') THEN
        PERFORM pg_drop_replication_slot('pgc_idle_slot');
    END IF;
    PERFORM pg_create_physical_replication_slot('pgc_idle_slot');
END
$$;

-- ---------- 18. Logical replication spill files ----------
-- Requires wal_level=logical + a large, abandoned logical slot transaction.
-- UNREACHABLE IN CI without a multi-minute setup.

-- ---------- 19. Outdated extensions ----------
-- Best-effort: install pg_trgm (or similar contrib) at whatever default
-- version the server offers. Whether it registers as "outdated" depends on
-- distribution packaging. If the contrib package isn't installed, skip —
-- this check becomes presence-only for that run.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_trgm not available on this server; skipping outdated-ext seed';
END
$$;

-- ---------- #21 Collation version mismatch (glibc 2.28 / RHEL 7 -> 8) ----------
-- Simulates an in-place OS upgrade: a collation recorded under glibc 2.17
-- (RHEL 7) running on whatever glibc this host actually provides. The locale
-- is taken from the current database so this works wherever the suite runs.
-- Collations are database-scoped, so --isolate drops this with the temp DB.
DO $$
DECLARE loc text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_collation WHERE collname = 'pgc_rhel7_collation') THEN
        RETURN;
    END IF;
    SELECT datcollate INTO loc FROM pg_database WHERE datname = current_database();
    BEGIN
        EXECUTE format(
            'CREATE COLLATION pgc_rhel7_collation (provider = libc, locale = %L, version = %L)',
            loc, '2.17');
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'versioned collation not supported here (%); skipping glibc fixture', SQLERRM;
    END;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_collation WHERE collname = 'pgc_rhel7_collation') THEN
        RAISE NOTICE 'no versioned collation; skipping affected-index fixture';
        RETURN;
    END IF;
    CREATE TABLE IF NOT EXISTS pgc_fixture.collation_victim (
        id     int primary key,
        label  text COLLATE pgc_rhel7_collation,
        plain  text
    );
    -- An affected non-unique index and an affected UNIQUE index: the UNIQUE one
    -- is the dangerous case, since a broken ordering means uniqueness was not
    -- actually enforced while the mismatch existed.
    CREATE INDEX IF NOT EXISTS collation_victim_label_idx
        ON pgc_fixture.collation_victim (label);
    CREATE UNIQUE INDEX IF NOT EXISTS collation_victim_label_uq
        ON pgc_fixture.collation_victim (label, id);
END
$$;

-- ---------- #22 Materialized views needing attention ----------
-- mv_healthy      : populated + unique index  -> can REFRESH CONCURRENTLY
-- mv_no_unique    : populated, no unique index -> refresh blocks readers
-- mv_unpopulated  : created WITH NO DATA       -> querying it errors
-- mv_stacked      : built on another matview   -> refresh ordering matters
DROP MATERIALIZED VIEW IF EXISTS pgc_fixture.mv_stacked;
DROP MATERIALIZED VIEW IF EXISTS pgc_fixture.mv_healthy;
DROP MATERIALIZED VIEW IF EXISTS pgc_fixture.mv_no_unique;
DROP MATERIALIZED VIEW IF EXISTS pgc_fixture.mv_unpopulated;

CREATE MATERIALIZED VIEW pgc_fixture.mv_healthy AS
    SELECT id, email FROM pgc_fixture.accounts;
CREATE UNIQUE INDEX mv_healthy_id_uq ON pgc_fixture.mv_healthy (id);

CREATE MATERIALIZED VIEW pgc_fixture.mv_no_unique AS
    SELECT kind, count(*) AS events FROM pgc_fixture.events GROUP BY kind;

CREATE MATERIALIZED VIEW pgc_fixture.mv_unpopulated AS
    SELECT id, email FROM pgc_fixture.accounts WITH NO DATA;

CREATE MATERIALIZED VIEW pgc_fixture.mv_stacked AS
    SELECT id FROM pgc_fixture.mv_healthy;

GRANT SELECT ON pgc_fixture.mv_healthy, pgc_fixture.mv_no_unique,
                pgc_fixture.mv_stacked TO pgc_runner;

-- ---------- Apply first round of SIGHUP-reloadable params ----------
-- track_counts is still ON here, so the dead-rows counters above persist.
SELECT pg_reload_conf();

-- Give the stats subsystem a moment to flush counters from #14.
SELECT pg_sleep(1);

-- ---------- Now disable track_counts (observation #10) ----------
-- Existing pg_stat_* values survive; new updates stop incrementing. Database
-- scope, so this takes effect for the pg_collector session that connects next
-- -- no reload needed -- and goes away with the database.
ALTER DATABASE :"DBNAME" SET track_counts = 'off';

\echo Applied health-check triggers. Some settings need a new session to take effect.
