#!/usr/bin/env python3
"""PostgreSQL dialect parse check for pg_collector.sql.

Each embedded SQL statement is handed to libpg_query (via `pglast`) to
confirm it's syntactically valid PostgreSQL. This catches typos, missing
parens, and accidental ambiguity without needing a live database.

Psql variable references (`:name`, `:'name'`, `:"name"`) are substituted
with placeholders so pglast can parse them. Statements whose entire body
is a single variable reference (e.g. `PREPARE x AS :var`) are skipped —
the substitution happens at psql-client time and is opaque to the parser.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    from pglast import parse_sql
    from pglast.parser import ParseError
except ImportError:
    print(
        "check_dialect.py requires pglast. Install with: pip install pglast",
        file=sys.stderr,
    )
    sys.exit(2)


def extract_statements(text: str) -> list[tuple[int, str]]:
    """Yield (line_number, raw_statement) pairs, preserving string contents
    so pglast can parse them. Strips only:
      - backslash meta-commands (whole line if at line start, else to EOL)
      - `--` line comments and `/* */` block comments
    Splits statements on unquoted `;` or when a mid-line meta-command appears.
    """
    n = len(text)
    i = 0
    line = 1
    buf: list[str] = []
    buf_start_line = 1
    at_line_start = True
    out: list[tuple[int, str]] = []

    def flush() -> None:
        nonlocal buf, buf_start_line
        s = "".join(buf).strip()
        if s:
            out.append((buf_start_line, s))
        buf = []
        buf_start_line = line

    while i < n:
        c = text[i]

        if c == "\n":
            buf.append("\n")
            i += 1
            line += 1
            at_line_start = True
            continue

        if at_line_start and c in " \t":
            buf.append(c)
            i += 1
            continue

        if c == "\\":
            meta_at_line_start = at_line_start
            while i < n and text[i] != "\n":
                i += 1
            if not meta_at_line_start:
                flush()
            continue

        at_line_start = False

        if c == "-" and i + 1 < n and text[i + 1] == "-":
            while i < n and text[i] != "\n":
                i += 1
            continue

        if c == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
            continue

        if c == "'":
            buf.append(c)
            i += 1
            while i < n:
                if text[i] == "'" and i + 1 < n and text[i + 1] == "'":
                    buf.append(text[i]); buf.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == "'":
                    buf.append(text[i])
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            continue

        if c == '"':
            buf.append(c)
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            if i < n:
                buf.append(text[i])
                i += 1
            continue

        if c == "$":
            m = re.match(r"\$[A-Za-z_][A-Za-z_0-9]*\$|\$\$", text[i:])
            if m:
                tag = m.group(0)
                end = text.find(tag, i + len(tag))
                if end == -1:
                    buf.append(text[i:]); i = n
                else:
                    chunk = text[i:end + len(tag)]
                    line += chunk.count("\n")
                    buf.append(chunk)
                    i = end + len(tag)
                continue

        if c == ";":
            flush()
            i += 1
            continue

        buf.append(c)
        i += 1

    flush()
    return out


# Replace psql variable references with parse-safe placeholders.
#   :'var'  -> 'PSQLVAR'   (string)
#   :"var"  -> "PSQLVAR"   (quoted identifier)
#   :var    -> NULL        (generic expression)
VAR_QUOTED_STR = re.compile(r":'\w+'")
VAR_QUOTED_ID = re.compile(r':"\w+"')
VAR_BARE = re.compile(r"(?<![:\w]):\w+\b")


def substitute_vars(stmt: str) -> str:
    stmt = VAR_QUOTED_STR.sub("'PSQLVAR'", stmt)
    stmt = VAR_QUOTED_ID.sub('"PSQLVAR"', stmt)
    stmt = VAR_BARE.sub("NULL", stmt)
    return stmt


def is_opaque_prepare(stmt: str) -> bool:
    """True if statement is `PREPARE name AS :varname` — body is dynamic."""
    m = re.match(
        r"\s*PREPARE\s+\w+\s+AS\s+NULL\s*$",
        stmt, re.IGNORECASE,
    )
    return m is not None


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    statements = extract_statements(text)

    errors: list[str] = []
    checked = 0
    skipped = 0

    for line, raw in statements:
        subbed = substitute_vars(raw)
        if is_opaque_prepare(subbed):
            skipped += 1
            continue
        try:
            parse_sql(subbed)
            checked += 1
        except ParseError as e:
            errors.append(
                f"{path}:{line}: parse error: {e}\n    statement: {raw[:160]!r}"
            )

    if errors:
        for e in errors:
            print(e)
        print(
            f"\ndialect parse FAILED: {len(errors)} issue(s) in {path}",
            file=sys.stderr,
        )
        return 1

    print(
        f"dialect parse passed: {checked} statement(s) parsed, "
        f"{skipped} opaque PREPARE skipped ({path})"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-sql>", file=sys.stderr)
        return 2
    return check(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
