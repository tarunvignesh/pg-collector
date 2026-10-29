# Changelog

All notable changes to pg collector will be documented in this file.


#  V1

```
1- V1 version created from pg-collector-for-postgresQL-18 branch.

2- Add generic_plan_calls and custom_plan_calls columns to all Top SQL queries in pg_stat_statements.

3- Added Selective Section Execution feature:
   - Run specific sections instead of the full report using -v fullmod=f -v <section>=t
   - Help mode with -v help=t lists all available section variables with descriptions
   - Terminal output lists included sections when running in selective mode
   - HTML report shows a "Partial Report" banner with clickable links to included sections
   - DB INFO header always runs regardless of mode
   - All Aurora and Limitless sub-sections individually selectable

4- Added configurable report output directory:
   - Default output location remains /tmp (backward compatible)
   - Users can override with -v outdir=/path/to/dir to save the report anywhere
   - Example: psql -v outdir=/home/user/reports -f pg_collector.sql

5- Fixed bug in obsrv_less_remaining_sequences health check:
   - Changed count(1) to count(1) > 0 to always return a boolean
   - Previously would cause psql error when 2 or more sequences had less than 10% remaining values

6- Added Collation / glibc index risk section (-v collation_risk=t):
   - Compares pg_collation.collversion and pg_database.datcollversion against
     the version the operating system currently provides
   - Lists every index whose key columns use an affected collation, including
     those using the database default collation, with PRIMARY KEY and UNIQUE
     entries called out as the urgent cases
   - Flags a jump across glibc 2.28 as CRITICAL - the RHEL 7 to RHEL 8 boundary
   - Also reports RANGE/LIST partitioned tables whose partition key is affected,
     where rows may now route to the wrong partition
   - New health check: collation version mismatch
   - Requires PostgreSQL 15 or later for the database-default checks

7- Added Partitioning candidates section (-v part_candidates=t):
   - Ranks unpartitioned tables by total size with the signals that justify
     declarative partitioning: date/timestamp range keys, dead rows, bulk
     deletes and sequential scans
   - Reports legacy inheritance-based partition parents as conversion candidates
   - Size threshold configurable with -v part_min_gb=<n> (default 50)
   - New health check: large tables that are not partitioned

8- Extended the Materialized Views section with health checks:
   - Refresh readiness - flags views that cannot REFRESH CONCURRENTLY because
     they have no unique index, and views created WITH NO DATA
   - Refresh dependency order - shows views built on other materialized views
   - Staleness and bloat indicators
   - Unused indexes on materialized views
   - New health check: materialized views unpopulated or unable to refresh
     concurrently

9- Added sample_reports/pg_collector_pg19_sample-2026-10-22.html, a full report
   generated against PostgreSQL 19.

10- Fixed issue #13 - removed an ORDER BY from the column_data_type CTE in the
    PK or FK using numeric or integer data type section. The outer query sorts
    the result anyway, so the inner sort was pure cost: the reporter measured
    11 minutes (sometimes over 90) with it against 53 seconds without.

11- Fixed issue #10 - division by zero no longer aborts sections. Every divisor
    that is a live statistics counter is now wrapped in nullif(..., 0), so a
    counter of zero yields an empty cell instead of an error. This affected all
    pg_stat_statements Top SQL queries (rows per execution, percent of total DB
    time, per-call block IO) when pg_stat_statements_reset() ran during
    collection, and also covers the instance-wide cache hit ratio on an idle
    cluster, vacuum progress on an empty table, Aurora CCM before its first
    cache scan, and the Aurora Limitless single-shard call ratio.
    tests/lint/check_div_by_zero.py now fails the build on any new occurrence.

13- Version-gated the Collation / glibc index risk section so it works on
    PostgreSQL 13 and 14 instead of erroring. pg_database.datcollversion and
    pg_database_collation_actual_version() are PG15+, but
    pg_collation.collversion and pg_collation_actual_version() go back to PG10,
    so named collations - where most text indexes get their ordering - are now
    checked in full on older servers. The database-default collation cannot be
    version-checked before PG15; rather than skip it, the pre-PG15 path reports
    the blast radius instead: the operating system's current libc collation
    version, and how many indexes sort by the database default, broken out by
    PRIMARY KEY and UNIQUE with a total size. This is the RHEL 7 (glibc 2.17)
    to RHEL 8 (glibc 2.28) case, which is exactly the population of databases
    still running PG13. Previously the section raised five "column does not
    exist" errors on PG13 and the collation health check never fired.

12- Fixed issue #7 - the autovacuum eligibility queries now consider
    autovacuum_vacuum_insert_threshold and autovacuum_vacuum_insert_scale_factor
    (PostgreSQL 13 and later), including per-table reloption overrides. Tables
    that are insert-only accumulate no dead tuples, so the dead-tuple test alone
    never listed them even when autovacuum was about to vacuum them. Two new
    columns report the insert trigger point and n_ins_since_vacuum; a threshold
    of -1 shows NULL because it disables insert-driven autovacuum.

```

