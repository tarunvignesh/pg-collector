#!/usr/bin/env bash
# Test runner for pg_collector.sql.
#
# CI mode (default): seed a fresh PG container, run pg_collector.sql as the
# read-only role pgc_runner, assert the report is well-formed, confirm no
# user-schema rows changed, upload the report for inspection.
#
# BYOD mode (--isolate): use the caller's PG cluster but createdb a fresh
# temporary database, seed and run inside it, dropdb on exit. Full harness,
# no container required.
#
# BYO-DSN mode: point at any Postgres via PGHOST/PGUSER/etc. and run the
# structural assertions on whatever the script produces. Skips seeding and
# the before/after schema diff so we never touch a user database.
#
# Usage:
#   ./tests/run.sh                                # defaults: seed=empty, no pgss, no aurora
#   ./tests/run.sh --seed populated --with-pgss --with-aurora-mock
#   ./tests/run.sh --as-role pgc_runner
#   PGHOST=... PGUSER=... ./tests/run.sh --skip-seed --skip-diff
#   PGHOST=... PGUSER=... ./tests/run.sh --isolate --seed populated   # BYOD with temp-DB isolation

set -euo pipefail

# ---------- defaults ----------
SEED="empty"              # empty | populated
WITH_PGSS=0
WITH_AURORA_MOCK=0
AS_ROLE=""                # if empty, uses $PGUSER
SKIP_SEED=0
SKIP_DIFF=0
ISOLATE=0

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)               SEED="$2"; shift 2 ;;
        --with-pgss)          WITH_PGSS=1; shift ;;
        --with-aurora-mock)   WITH_AURORA_MOCK=1; shift ;;
        --as-role)            AS_ROLE="$2"; shift 2 ;;
        --skip-seed)          SKIP_SEED=1; shift ;;
        --skip-diff)          SKIP_DIFF=1; shift ;;
        --isolate)            ISOLATE=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------- environment ----------
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"
# PGPASSWORD passed through from caller / CI secrets.

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPORT_DIR="${REPORT_DIR:-/tmp}"
STAMP="$(date +%Y%m%d_%H%M%S)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$HERE/artifacts/$STAMP}"
mkdir -p "$ARTIFACT_DIR"

# ---------- --isolate: create a temp DB, drop on exit ----------
MAINT_DB="$PGDATABASE"
if [[ "$ISOLATE" -eq 1 ]]; then
    if [[ "$SKIP_SEED" -eq 1 ]]; then
        echo "ERROR: --isolate and --skip-seed are incompatible (temp DB would be empty)." >&2
        exit 2
    fi
    TMP_DB="pgc_test_$$"
    echo ">>> --isolate: creating temporary database '$TMP_DB' in cluster..."
    if ! createdb --maintenance-db="$MAINT_DB" "$TMP_DB" 2>"$ARTIFACT_DIR/createdb.err"; then
        echo "FAIL: createdb $TMP_DB failed." >&2
        echo "  Does role '$PGUSER' have CREATEDB? Can it connect to '$MAINT_DB'?" >&2
        sed 's/^/  /' "$ARTIFACT_DIR/createdb.err" >&2 || true
        exit 1
    fi
    export PGDATABASE="$TMP_DB"
    # seed_health_checks.sql scopes its GUCs to the database wherever the
    # context allows, so dropdb removes them. `autovacuum` is context 'sighup'
    # and can only be set cluster-wide, so reset it here or --isolate leaves
    # the caller's cluster with autovacuum off. Reset before dropdb: the
    # reset targets the cluster, not the database, and must run even if
    # dropdb fails.
    # shellcheck disable=SC2064
    trap "echo '>>> --isolate: resetting cluster-scoped GUCs...'; psql -qAt -d '$MAINT_DB' -c 'ALTER SYSTEM RESET autovacuum' >/dev/null 2>&1 || true; psql -qAt -d '$MAINT_DB' -c 'SELECT pg_reload_conf()' >/dev/null 2>&1 || true; echo '>>> --isolate: dropping $TMP_DB...'; dropdb --if-exists --maintenance-db='$MAINT_DB' '$TMP_DB' >/dev/null 2>&1 || true" EXIT INT TERM
fi

echo ">>> pg_collector test runner"
echo "    host=$PGHOST port=$PGPORT db=$PGDATABASE user=$PGUSER"
echo "    seed=$SEED skip_seed=$SKIP_SEED skip_diff=$SKIP_DIFF isolate=$ISOLATE"
echo "    with_pgss=$WITH_PGSS with_aurora_mock=$WITH_AURORA_MOCK as_role=${AS_ROLE:-<default>}"
echo "    artifacts=$ARTIFACT_DIR"

# ---------- helpers ----------
PSQL_ADMIN="psql -v ON_ERROR_STOP=1 -qAt"

snapshot() {
    local label="$1"
    # Non-catalog schemas only; excludes pg_*, information_schema.
    local query="
SELECT n.nspname || '.' || c.relname || E'\t' || c.reltuples::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY 1"
    $PSQL_ADMIN -c "$query" > "$ARTIFACT_DIR/snapshot_$label.txt"
}

# ---------- seed phase ----------
if [[ "$SKIP_SEED" -eq 0 ]]; then
    echo ">>> Seeding fixtures as $PGUSER..."
    $PSQL_ADMIN -f "$HERE/fixtures/seed_common.sql"

    if [[ "$WITH_PGSS" -eq 1 ]]; then
        echo ">>> Installing pg_stat_statements..."
        $PSQL_ADMIN -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || true
    fi

    if [[ "$SEED" == "populated" ]]; then
        echo ">>> Applying health-check triggers..."
        $PSQL_ADMIN -f "$HERE/fixtures/seed_health_checks.sql"
    fi

    if [[ "$WITH_AURORA_MOCK" -eq 1 ]]; then
        echo ">>> Installing Aurora mock..."
        $PSQL_ADMIN -f "$HERE/fixtures/seed_aurora_mock.sql"
    fi
fi

# ---------- before snapshot ----------
if [[ "$SKIP_DIFF" -eq 0 ]]; then
    echo ">>> Snapshotting schema (before)..."
    snapshot "before"
fi

# ---------- run pg_collector.sql as the runner role ----------
RUNNER="${AS_ROLE:-pgc_runner}"
echo ">>> Running pg_collector.sql as $RUNNER..."

# Inherit PG* but override -U, explicitly trust pg_read_all_data — failures
# here mean the script attempted a write.
OUT_LOG="$ARTIFACT_DIR/psql_stdout.log"
ERR_LOG="$ARTIFACT_DIR/psql_stderr.log"
set +e
if [[ -n "$AS_ROLE" ]]; then
    # User supplied their own role; don't force a password.
    PGUSER="$AS_ROLE" psql -f "$REPO/pg_collector.sql" > "$OUT_LOG" 2> "$ERR_LOG"
else
    PGUSER="$RUNNER" PGPASSWORD=runner \
        psql -f "$REPO/pg_collector.sql" > "$OUT_LOG" 2> "$ERR_LOG"
fi
PSQL_RC=$?
set -e

# Capture the generated HTML report. The script writes /tmp/pg_collector_<db>-*.html.
REPORT=$(ls -t /tmp/pg_collector_"$PGDATABASE"-*.html 2>/dev/null | head -n 1 || true)
if [[ -z "$REPORT" ]]; then
    echo "ERROR: no report found at /tmp/pg_collector_${PGDATABASE}-*.html" >&2
    echo "stderr:" >&2
    tail -n 40 "$ERR_LOG" >&2 || true
    exit 1
fi
cp "$REPORT" "$ARTIFACT_DIR/report.html"
echo ">>> Report: $ARTIFACT_DIR/report.html"

# Success banner
if ! grep -q "Report Generated Successfully" "$OUT_LOG"; then
    echo "FAIL: 'Report Generated Successfully' not in psql stdout" >&2
    tail -n 40 "$OUT_LOG" >&2
    exit 1
fi

# Permission-denied detection — our trust proof.
# Benign errors we accept: pg_stat_statements missing, CCM disabled.
if grep -iE 'permission denied|must be superuser' "$ERR_LOG" \
    | grep -ivE 'pg_stat_statements'; then
    echo "FAIL: script attempted a write (permission denied). See $ERR_LOG" >&2
    exit 1
fi

# ---------- after snapshot + diff ----------
if [[ "$SKIP_DIFF" -eq 0 ]]; then
    echo ">>> Snapshotting schema (after)..."
    snapshot "after"
    if ! diff -u "$ARTIFACT_DIR/snapshot_before.txt" "$ARTIFACT_DIR/snapshot_after.txt" \
            > "$ARTIFACT_DIR/snapshot_diff.txt"; then
        echo "FAIL: schema/row-count changed during pg_collector run:" >&2
        cat "$ARTIFACT_DIR/snapshot_diff.txt" >&2
        exit 1
    fi
fi

# ---------- HTML assertions ----------
ASSERT_ARGS=(--report "$ARTIFACT_DIR/report.html" --script "$REPO/pg_collector.sql")

if [[ "$SEED" == "populated" ]]; then
    # These are the observations we reliably trigger in seed_health_checks.sql.
    ASSERT_ARGS+=(--expect-observations \
        "duplicate_indexes,invalid_indexes,unused_indexes,autovacuum_parameter,sequences,ssl,enable_indexonlyscan,excessive_logging,track_counts,enable_indexscan,synchronous_commit,dead_rows,table_autovacuum_off,inactive_replication_slots")
elif [[ "$SKIP_SEED" -eq 0 ]]; then
    # Empty-DB mode: no observations should fire except perhaps SSL.
    # (We can't use --no-observations here because the CI container is
    # unencrypted, so `ssl` observation fires unconditionally.)
    :
fi

if [[ "$WITH_AURORA_MOCK" -eq 1 ]]; then
    ASSERT_ARGS+=(--aurora mocked)
elif [[ "$SKIP_SEED" -eq 0 ]]; then
    ASSERT_ARGS+=(--aurora none)
fi

echo ">>> Running HTML assertions..."
if command -v uv >/dev/null 2>&1 && ! python3 -c "import bs4" 2>/dev/null; then
    # Local dev convenience: use uv-managed env if bs4 isn't installed system-wide.
    uv run --with beautifulsoup4 --quiet python3 "$HERE/report_assertions.py" "${ASSERT_ARGS[@]}"
else
    python3 "$HERE/report_assertions.py" "${ASSERT_ARGS[@]}"
fi

echo ">>> PASS (artifacts in $ARTIFACT_DIR)"
