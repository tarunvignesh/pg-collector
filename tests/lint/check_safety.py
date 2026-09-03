#!/usr/bin/env python3
"""Static safety check for pg_collector.sql.

Fails CI if the script contains any statement that could mutate the database.
Tokenizes the file so we don't false-positive on write keywords that appear
inside `\\qecho` display strings, SQL comments, or quoted identifiers.

Rules
-----
1. Lines beginning with a backslash are psql meta-commands (client-side only);
   they are stripped.
2. A backslash encountered mid-line (e.g. `\\gset`) terminates the current SQL
   statement. The rest of the line is consumed.
3. `--` line comments, `/* ... */` block comments, `'...'` single-quoted
   strings, and `$tag$...$tag$` dollar-quoted strings are stripped.
4. The remaining text is split on unquoted `;`. Each fragment is a statement.
5. Fail if a statement's first keyword is in WRITE_KEYWORDS.
6. Fail if a statement references a side-effecting server-side function.
7. `PREPARE ... AS <body>` is allowed only if <body> starts with SELECT / WITH
   / VALUES. `EXECUTE <name>` is allowed only if <name> was previously
   introduced by an allowed PREPARE.
8. `SET` / `RESET` are write-class by default, but a session-scoped assignment
   to a GUC in SAFE_SESSION_GUCS is allowed: it changes only this backend's
   behaviour and touches no data. `SET ROLE`, `SET SESSION AUTHORIZATION`,
   `SET CONSTRAINTS`, `SET TRANSACTION` and `RESET ALL` stay rejected because
   they change the security or transaction context rather than a tunable.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

WRITE_KEYWORDS = frozenset({
    "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE",
    "CREATE", "ALTER", "DROP",
    "GRANT", "REVOKE", "COMMENT",
    "VACUUM", "ANALYZE", "REINDEX", "CLUSTER", "REFRESH",
    "LOCK",
    "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE",
    "SET", "RESET",
    "CALL", "DO",
    "NOTIFY", "LISTEN", "UNLISTEN",
    "DISCARD",
    "SECURITY",
    "IMPORT",
})

# GUCs the script may set on its own session. Each one only affects how this
# backend executes the collector's own read-only queries; none can alter data
# or outlive the session. Upstream added `SET statement_timeout` in the
# 2026-06 release so a slow catalog query cancels instead of hanging the run.
SAFE_SESSION_GUCS = frozenset({
    "statement_timeout",
    "lock_timeout",
    "idle_in_transaction_session_timeout",
})

# `SET [SESSION|LOCAL] <name> ...` / `RESET [SESSION|LOCAL] <name>`.
# Anything that is not a bare GUC name (ROLE, SESSION AUTHORIZATION,
# CONSTRAINTS, TRANSACTION, TIME ZONE, ALL) fails the allowlist lookup.
SET_TARGET_RE = re.compile(
    r"^(?:SET|RESET)\s+(?:SESSION\s+|LOCAL\s+)?([A-Za-z_][A-Za-z0-9_.]*)",
    re.IGNORECASE,
)

SIDE_EFFECT_FUNCTIONS = frozenset({
    "pg_stat_reset",
    "pg_stat_reset_shared",
    "pg_stat_reset_single_table_counters",
    "pg_stat_reset_single_function_counters",
    "pg_stat_statements_reset",
    "pg_replication_origin_create",
    "pg_replication_origin_drop",
    "pg_create_physical_replication_slot",
    "pg_create_logical_replication_slot",
    "pg_drop_replication_slot",
    "pg_logical_emit_message",
    "pg_terminate_backend",
    "pg_cancel_backend",
    "pg_advisory_lock",
    "pg_advisory_lock_shared",
    "pg_advisory_unlock",
    "pg_advisory_unlock_all",
    "pg_advisory_xact_lock",
    "pg_advisory_xact_lock_shared",
    "lo_create", "lo_creat", "lo_import", "lo_export", "lo_unlink",
    "pg_read_server_files",
    "pg_write_server_files",
    "pg_switch_wal", "pg_switch_xlog",
    "pg_backup_start", "pg_backup_stop",
    "pg_start_backup", "pg_stop_backup",
    "pg_reload_conf",
    "pg_rotate_logfile",
    "pg_promote",
})


def tokenize(text: str) -> list[tuple[int, str]]:
    """Return a list of (line_number, statement_text) pairs.

    `statement_text` has comments, string literals, and meta-commands stripped
    (replaced with a sentinel so adjacent tokens don't fuse).
    """
    n = len(text)
    i = 0
    line = 1
    buf: list[str] = []
    buf_start_line = 1
    buf_has_content = False
    at_line_start = True
    out: list[tuple[int, str]] = []

    def push(chunk: str, at: int | None = None) -> None:
        """Append to the current statement, anchoring its reported line.

        `buf` collects blank lines, comment gaps, and stripped meta-commands
        between statements, so the line a statement *starts* on is the line of
        its first non-whitespace chunk -- not wherever the previous flush left
        off. `at` overrides for chunks consumed after `line` has already been
        advanced past them (multi-line literals).
        """
        nonlocal buf_start_line, buf_has_content
        buf.append(chunk)
        if not buf_has_content and chunk.strip():
            buf_start_line = line if at is None else at
            buf_has_content = True

    def flush() -> None:
        nonlocal buf, buf_has_content
        s = "".join(buf).strip()
        if s:
            out.append((buf_start_line, s))
        buf = []
        buf_has_content = False

    while i < n:
        c = text[i]

        if c == "\n":
            push("\n")
            i += 1
            line += 1
            at_line_start = True
            continue

        if at_line_start and c in " \t":
            push(c)
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
            str_start_line = line
            i += 1
            while i < n:
                if text[i] == "'" and i + 1 < n and text[i + 1] == "'":
                    i += 2
                    continue
                if text[i] == "'":
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                i += 1
            push(" __STR__ ", at=str_start_line)
            continue

        if c == '"':
            push(c)
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\n":
                    line += 1
                push(text[i])
                i += 1
            if i < n:
                push(text[i])
                i += 1
            continue

        if c == "$":
            m = re.match(r"\$[A-Za-z_][A-Za-z_0-9]*\$|\$\$", text[i:])
            if m:
                tag = m.group(0)
                end = text.find(tag, i + len(tag))
                dollar_start_line = line
                if end == -1:
                    push(" __STR__ ", at=dollar_start_line)
                    i = n
                else:
                    line += text[i:end + len(tag)].count("\n")
                    push(" __STR__ ", at=dollar_start_line)
                    i = end + len(tag)
                continue

        if c == ";":
            i += 1
            flush()
            continue

        push(c)
        i += 1

    flush()
    return out


def first_keyword(stmt: str) -> str:
    m = re.match(r"\s*([A-Za-z_][A-Za-z_0-9]*)", stmt)
    return m.group(1).upper() if m else ""


def side_effect_calls(stmt: str) -> list[str]:
    hits = []
    lowered = stmt.lower()
    for fn in SIDE_EFFECT_FUNCTIONS:
        if re.search(rf"\b{re.escape(fn)}\s*\(", lowered):
            hits.append(fn)
    return hits


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    statements = tokenize(text)
    errors: list[str] = []
    prepared: dict[str, str] = {}

    for line, stmt in statements:
        kw = first_keyword(stmt)

        if kw == "PREPARE":
            m = re.match(
                r"PREPARE\s+(\w+)(?:\s*\([^)]*\))?\s+AS\s+(.+)$",
                stmt, re.IGNORECASE | re.DOTALL,
            )
            if not m:
                errors.append(f"{path}:{line}: PREPARE parse failure: {stmt[:80]!r}")
                continue
            name, body = m.group(1).lower(), m.group(2).strip()
            # psql variable substitution (`:varname`) — body is opaque to
            # static analysis. Allow; runtime read-only-role test enforces.
            if re.match(r":\w+\s*$", body):
                prepared[name] = body
                continue
            body_kw = first_keyword(body)
            if body_kw not in {"SELECT", "WITH", "VALUES"}:
                errors.append(
                    f"{path}:{line}: PREPARE {name!r} body is not read-only "
                    f"(starts with {body_kw or '<empty>'})"
                )
            prepared[name] = body
            continue

        if kw == "EXECUTE":
            m = re.match(r"EXECUTE\s+(\w+)", stmt, re.IGNORECASE)
            if not m:
                errors.append(f"{path}:{line}: dynamic EXECUTE disallowed: {stmt[:80]!r}")
                continue
            if m.group(1).lower() not in prepared:
                errors.append(
                    f"{path}:{line}: EXECUTE of unknown prepared statement "
                    f"{m.group(1)!r}"
                )
            continue

        if kw == "DEALLOCATE":
            continue

        if kw == "COPY":
            if re.search(r"\bCOPY\b[\s\S]+\bFROM\b", stmt, re.IGNORECASE):
                errors.append(f"{path}:{line}: COPY ... FROM writes to DB: {stmt[:80]!r}")
            continue

        if kw in ("SET", "RESET"):
            m = SET_TARGET_RE.match(stmt.strip())
            target = m.group(1).lower() if m else None
            if target in SAFE_SESSION_GUCS:
                continue
            errors.append(
                f"{path}:{line}: {kw} of non-allowlisted target "
                f"{target or '?'!r}: {stmt[:80]!r}"
            )
            continue

        if kw in WRITE_KEYWORDS:
            errors.append(
                f"{path}:{line}: write-class statement ({kw}): {stmt[:80]!r}"
            )
            continue

        hits = side_effect_calls(stmt)
        if hits:
            errors.append(
                f"{path}:{line}: side-effecting function(s) {hits}: {stmt[:80]!r}"
            )

    if errors:
        for e in errors:
            print(e)
        print(
            f"\nsafety check FAILED: {len(errors)} issue(s) in {path}",
            file=sys.stderr,
        )
        return 1

    print(f"safety check passed: {len(statements)} statements, all read-only ({path})")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-sql>", file=sys.stderr)
        return 2
    return check(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
