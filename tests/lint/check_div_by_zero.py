#!/usr/bin/env python3
"""Static division-by-zero check for pg_collector.sql.

Upstream issue awslabs/pg-collector#10: a report run against a database whose
`pg_stat_statements` counters were reset mid-collection aborts whole sections
with `ERROR: division by zero`. The divisors in those queries -- `calls`, the
window `sum(total_exec_time) over ()`, `sum(allocated)` -- are all counters
that are legitimately zero, so the arithmetic has to be written defensively
rather than relying on the data never reaching zero.

This checker fails if a division's divisor looks like a column reference or an
aggregate over one and is not guarded. It deliberately does not try to prove
that a given column can be zero: in a diagnostic tool that reads live
statistics views, the burden is the other way round -- a bare counter in a
denominator is a bug until it is guarded or explicitly allowlisted.

Guards recognised
-----------------
`nullif(x, 0)`      the normal fix; the row renders empty instead of erroring
`greatest(x, 1)`    where a floor of 1 is meaningful
`coalesce(nullif(...), ...)` and any expression whose outermost call is one of
                    the above
a zero test on the same column anywhere in the statement, which is how the
                    bloat and progress queries already do it:
                    `case when iotta = 0 then 0.0 else ipages::float / iotta end`.
                    This is a heuristic -- it proves the author considered zero
                    for that column, not that the test dominates the division --
                    and it is the reason the checker reports zero findings on a
                    file whose remaining divisions are all CASE-guarded.

Divisors that are literals, `current_setting(...)`, interval/extract
arithmetic, or anything else that cannot come from a statistics counter are
ignored. Add to SAFE_DIVISOR_PREFIXES or SAFE_DIVISORS when a new one appears.

Usage:
    python3 tests/lint/check_div_by_zero.py pg_collector.sql
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from check_safety import tokenize

# Outermost call that makes a divisor safe no matter what is inside it.
GUARD_FUNCTIONS = ("nullif", "greatest")

# Divisor expressions that cannot be a statistics counter. Prefix match on the
# normalised (lowercased, whitespace-collapsed) text.
SAFE_DIVISOR_PREFIXES = (
    "current_setting",
    "extract",
    "pg_size_bytes",
    "interval",
    "date_part",
)

# Exact divisors that are safe. Mostly unit conversions.
SAFE_DIVISORS = frozenset({
    "1024",
    "1000",
    "60",
    "3600",
    "1000000",
    "1024*1024",
    "1024.0",
    "1000.0",
})

# Columns that read like counters but have a hard minimum above zero, so a
# guard would be dead code. Each entry needs a reason; "it has never been zero
# on my cluster" is not one.
ALWAYS_NONZERO = {
    # Constant: 2^31 - 3000000, the wraparound horizon.
    "max_old_xid",
    # GUC, minimum 100000.
    "autovacuum_freeze_max_age",
    # GUC, minimum 1.
    "max_connections",
    # pg_sequences.max_value is bounded away from zero in both directions.
    "max_value",
}

# A divisor shaped like one of these is a counter: flag it unless guarded.
# Bare identifier (`calls`, `stat.n_tup_ins`) or an aggregate over one.
BARE_IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_$]*(\.[a-z_][a-z0-9_$]*)*$")
AGGREGATE_CALL = re.compile(r"^(sum|count|avg|min|max|total)\s*\(")


def _collapse(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def _read_divisor(stmt: str, i: int) -> tuple[str, int]:
    """Read the divisor expression starting at `i`. Returns (text, end index).

    A divisor is one `primary`: a parenthesised group, or an identifier with an
    optional argument list, optionally followed by a window clause. That is
    enough to classify -- anything more is a binary expression whose first
    operand we have already captured, and a division's immediate right operand
    is what determines whether it can be zero.
    """
    n = len(stmt)
    while i < n and stmt[i].isspace():
        i += 1
    start = i

    if i < n and stmt[i] == "(":
        depth = 0
        while i < n:
            if stmt[i] == "(":
                depth += 1
            elif stmt[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        return stmt[start:i], i

    while i < n and (stmt[i].isalnum() or stmt[i] in "_$."):
        i += 1
    # Optional argument list.
    j = i
    while j < n and stmt[j].isspace():
        j += 1
    if j < n and stmt[j] == "(":
        depth = 0
        while j < n:
            if stmt[j] == "(":
                depth += 1
            elif stmt[j] == ")":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        i = j
        # Optional window clause: `sum(x) over ()`.
        k = i
        while k < n and stmt[k].isspace():
            k += 1
        if stmt[k:k + 4].lower() == "over":
            k += 4
            while k < n and stmt[k].isspace():
                k += 1
            if k < n and stmt[k] == "(":
                depth = 0
                while k < n:
                    if stmt[k] == "(":
                        depth += 1
                    elif stmt[k] == ")":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
                i = k
    return stmt[start:i], i


def _unwrap(expr: str) -> str:
    """Strip redundant outer parentheses: `((sum(x)))` -> `sum(x)`."""
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        for pos, ch in enumerate(expr):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and pos != len(expr) - 1:
                    return expr  # the parens are not a single wrapping group
        expr = expr[1:-1].strip()
    return expr


def zero_tested(stmt: str, expr: str) -> bool:
    """True if `stmt` compares `expr` against 0 anywhere.

    Catches the CASE-guard idiom the bloat and vacuum-progress queries use.
    Both the qualified name (`st.n_live_tup`) and its bare tail (`n_live_tup`)
    count, because the guard and the division often differ in qualification.
    """
    names = {expr}
    if "." in expr:
        names.add(expr.rsplit(".", 1)[1])
    haystack = _collapse(stmt)
    for name in names:
        pattern = (
            r"(?:^|[^a-z0-9_.])" + re.escape(name) +
            r"\s*(?:=|<>|!=|>=|>)\s*0(?![0-9.])"
        )
        if re.search(pattern, haystack):
            return True
    return False


def _split_sum(expr: str) -> list[str]:
    """Split on top-level `+` / `-`. `a + sum(b + c)` -> ['a', 'sum(b + c)']."""
    parts: list[str] = []
    depth = 0
    current = ""
    for ch in expr:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth == 0 and ch in "+-":
            parts.append(current)
            current = ""
            continue
        current += ch
    parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def _is_counter(part: str) -> bool:
    part = _unwrap(part)
    if part in ALWAYS_NONZERO:
        return False
    if "." in part and part.rsplit(".", 1)[1] in ALWAYS_NONZERO:
        return False
    return bool(AGGREGATE_CALL.match(part) or BARE_IDENTIFIER.fullmatch(part))


def classify(divisor: str) -> str | None:
    """Return a reason string if the divisor is an unguarded counter.

    A divisor is a counter if it is a column, an aggregate over one, or a sum
    of those -- `blks_hit + blks_read` is the textbook case: the cache hit
    ratio divides by zero on a database nothing has touched yet.
    """
    # Casts carry no information about nullability.
    expr = _unwrap(re.sub(r"::\s*[a-z][a-z0-9_ ]*", "", _collapse(divisor)))
    if not expr or expr == "__str__":
        return None
    if expr.startswith(GUARD_FUNCTIONS) or expr.startswith(SAFE_DIVISOR_PREFIXES):
        return None
    if expr in SAFE_DIVISORS or re.fullmatch(r"[0-9.]+", expr):
        return None

    parts = _split_sum(expr)
    if not parts or not all(_is_counter(p) for p in parts):
        return None
    if len(parts) > 1:
        return f"`{expr}` sums counters and is 0 when all of them are 0"
    if AGGREGATE_CALL.match(parts[0]):
        return f"aggregate `{expr}` can be 0 when every input row is 0"
    return f"column `{expr}` is a counter and can be 0"


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8", errors="replace")
    statements = tokenize(text)

    errors: list[str] = []
    divisions = 0
    guarded = 0

    for line, stmt in statements:
        for m in re.finditer(r"/", stmt):
            i = m.start()
            # `/` only ever means division here: block comments and string
            # literals are already stripped by tokenize().
            divisor, _ = _read_divisor(stmt, i + 1)
            if not divisor.strip():
                continue
            divisions += 1
            reason = classify(divisor)
            if reason is None:
                if _unwrap(_collapse(divisor)).startswith(GUARD_FUNCTIONS):
                    guarded += 1
                continue
            if zero_tested(stmt, _unwrap(_collapse(divisor))):
                guarded += 1
                continue
            # Report the line the statement starts on; tokenize() does not
            # preserve per-token line numbers.
            snippet = _collapse(stmt[max(0, i - 60):i + len(divisor) + 1])
            errors.append(
                f"{path}:{line}: unguarded division -- {reason}\n"
                f"    ...{snippet}\n"
                f"    fix: wrap the divisor in nullif(..., 0)"
            )

    if errors:
        for e in errors:
            print(e)
        print(
            f"\ndivision-by-zero check FAILED: {len(errors)} unguarded "
            f"division(s) in {path}",
            file=sys.stderr,
        )
        return 1

    print(
        f"division-by-zero check passed: {divisions} division(s), "
        f"{guarded} guarded by nullif/greatest ({path})"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-sql>", file=sys.stderr)
        return 2
    return check(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
