#!/usr/bin/env python3
"""`\\if` / `\\endif` balance check for pg_collector.sql.

psql meta-commands are line-oriented: `\\if`, `\\elif`, `\\else`, `\\endif`
must appear as the first non-whitespace token on a line to be recognized.

The script relies heavily on nested `\\if` blocks (Aurora gates, extension
version gates, Observations checks). An unbalanced or misnested block
silently swallows or duplicates large ranges of output; this check catches
it at PR time.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPEN_RE = re.compile(r"^\s*\\if\b")
SAME_LEVEL_RE = re.compile(r"^\s*\\(elif|else)\b")
CLOSE_RE = re.compile(r"^\s*\\endif\b")


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    depth = 0
    stack: list[int] = []  # line numbers of open \if
    errors: list[str] = []

    for lineno, line in enumerate(text.splitlines(), start=1):
        if OPEN_RE.match(line):
            depth += 1
            stack.append(lineno)
        elif CLOSE_RE.match(line):
            if depth == 0:
                errors.append(f"{path}:{lineno}: \\endif without matching \\if")
            else:
                depth -= 1
                stack.pop()
        elif SAME_LEVEL_RE.match(line):
            if depth == 0:
                errors.append(
                    f"{path}:{lineno}: \\elif/\\else outside any \\if block"
                )

    if depth != 0:
        for lineno in stack:
            errors.append(f"{path}:{lineno}: \\if opened but never closed")

    if errors:
        for e in errors:
            print(e)
        print(
            f"\ncontrol-flow balance FAILED: {len(errors)} issue(s) in {path}",
            file=sys.stderr,
        )
        return 1

    print(f"control-flow balance passed ({path})")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-sql>", file=sys.stderr)
        return 2
    return check(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
