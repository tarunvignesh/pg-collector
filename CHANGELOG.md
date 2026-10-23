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

```

