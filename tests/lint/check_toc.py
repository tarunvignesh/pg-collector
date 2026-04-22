#!/usr/bin/env python3
"""TOC / anchor parity check for pg_collector.sql.

Every `href="#X"` used in the rendered report must resolve to a matching
`<a name="X"></a>` somewhere in the script. The one exception is `#top`,
which relies on browser default behavior. Placeholder cells using `#******`
are ignored.

Fails CI if the TOC links to a section that isn't rendered, or a section
exists with no TOC entry (the latter is a warning-only check since some
sub-anchors are legitimate).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HREF_RE = re.compile(r'href="#([^"]+)"')
NAME_RE = re.compile(r'<a\s+name="([^"]+)"\s*>')

IGNORED_HREFS = frozenset({"top"})
# Anchors known to be intentionally unlinked (section-group separators, etc.).
IGNORED_ANCHORS = frozenset({"-----"})
PLACEHOLDER = re.compile(r"^\*+$")


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    hrefs = {m for m in HREF_RE.findall(text)}
    anchors = {m for m in NAME_RE.findall(text)}

    meaningful_hrefs = {
        h for h in hrefs if h not in IGNORED_HREFS and not PLACEHOLDER.match(h)
    }

    broken = sorted(meaningful_hrefs - anchors)
    orphan = sorted(anchors - meaningful_hrefs - IGNORED_HREFS - IGNORED_ANCHORS)

    errors = 0
    if broken:
        print(f"{path}: {len(broken)} broken href(s) with no matching anchor:")
        for h in broken:
            print(f"  href=\"#{h}\"")
        errors += len(broken)

    if orphan:
        meaningful_orphan = [o for o in orphan if not PLACEHOLDER.match(o)]
        if meaningful_orphan:
            print(f"{path}: {len(meaningful_orphan)} anchor(s) with no TOC entry:")
            for a in meaningful_orphan:
                print(f"  <a name=\"{a}\">")

    if errors:
        print(f"\nTOC parity FAILED: {errors} broken href(s) in {path}", file=sys.stderr)
        return 1

    print(
        f"TOC parity passed: {len(meaningful_hrefs)} link(s) "
        f"-> {len(anchors)} anchor(s) ({path})"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <path-to-sql>", file=sys.stderr)
        return 2
    return check(Path(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
