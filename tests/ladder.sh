#!/usr/bin/env bash
# Run the harness against several PostgreSQL majors in one command and print a
# comparison table.
#
# This branch claims to run clean on PG13 through PG19. CI checks that on every
# push; this is the local equivalent, for when you are changing a version gate
# and do not want to wait for a round trip.
#
# BYOD, deliberately. It starts no containers and installs nothing -- it
# connects to servers you already have and calls ./tests/run.sh --isolate
# against each, which creates and drops its own temporary database. Point it at
# whatever you run locally.
#
# Usage:
#   ./tests/ladder.sh 5433 5434 5435 5436 5437 5432       # ports on PGHOST
#   ./tests/ladder.sh "port=5433" "host=db2 port=5432"    # full conninfo
#   PGHOST=localhost PGUSER=postgres ./tests/ladder.sh 5433 5432
#
# Any run.sh flags after `--` are passed through:
#   ./tests/ladder.sh 5433 5432 -- --seed populated --with-pgss
#
# Exit status is non-zero if any leg fails, so it works in a pre-push hook.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TARGETS=()
PASSTHRU=(--isolate --seed populated --with-pgss)
seen_dashdash=0
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        seen_dashdash=1
        PASSTHRU=(--isolate)
        continue
    fi
    if [[ $seen_dashdash -eq 1 ]]; then PASSTHRU+=("$arg"); else TARGETS+=("$arg"); fi
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
fi

printf '>>> ladder: %d target(s), flags: %s\n\n' "${#TARGETS[@]}" "${PASSTHRU[*]}"
printf '%-22s %-8s %-7s %-7s %-8s %s\n' TARGET VERSION RESULT ERRORS SECTIONS NOTE
printf '%s\n' "----------------------------------------------------------------------------"

overall=0
for target in "${TARGETS[@]}"; do
    # A bare number is a port on the inherited PGHOST; anything else is conninfo.
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        conn="port=$target"
        label="port $target"
    else
        conn="$target"
        label="$target"
    fi

    ver=$(psql "$conn" -tAc "show server_version" 2>/dev/null | awk '{print $1}')
    if [[ -z "$ver" ]]; then
        printf '%-22s %-8s %-7s %-7s %-8s %s\n' "$label" "-" "SKIP" "-" "-" "unreachable"
        overall=1
        continue
    fi

    # run.sh reads PG* from the environment; translate the conninfo we were
    # given into those rather than teaching run.sh a second way to connect.
    env_args=()
    for kv in $conn; do
        case "${kv%%=*}" in
            host)   env_args+=("PGHOST=${kv#*=}") ;;
            port)   env_args+=("PGPORT=${kv#*=}") ;;
            user)   env_args+=("PGUSER=${kv#*=}") ;;
            dbname) env_args+=("PGDATABASE=${kv#*=}") ;;
        esac
    done

    log=$(mktemp)
    env "${env_args[@]}" "$REPO/tests/run.sh" "${PASSTHRU[@]}" >"$log" 2>&1
    status=$?

    artifacts=$(grep -o 'tests/artifacts/[0-9_]*' "$log" | head -1)
    errors="-" ; sections="-" ; note=""
    if [[ -n "$artifacts" && -f "$REPO/$artifacts/psql_stderr.log" ]]; then
        errors=$(grep -c 'ERROR:' "$REPO/$artifacts/psql_stderr.log")
    fi
    if [[ -n "$artifacts" && -f "$REPO/$artifacts/report.html" ]]; then
        sections=$(grep -o '<a name="[^"]*"' "$REPO/$artifacts/report.html" |
                   sort -u | wc -l | tr -d ' ')
    fi
    if [[ $status -ne 0 ]]; then
        note=$(grep -m1 'FAIL:' "$log" | sed 's/^FAIL: //' | cut -c1-40)
        overall=1
    fi

    printf '%-22s %-8s %-7s %-7s %-8s %s\n' \
        "$label" "$ver" "$([[ $status -eq 0 ]] && echo PASS || echo FAIL)" \
        "$errors" "$sections" "$note"
    rm -f "$log"
done

echo
if [[ $overall -eq 0 ]]; then
    echo ">>> ladder PASS"
else
    echo ">>> ladder FAIL (see tests/artifacts/ for the failing run)" >&2
fi
exit $overall
