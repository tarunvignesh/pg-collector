"""Pytest wrapper around the existing test harness.

Exists to produce a structured test report (HTML via pytest-html, JUnit
XML via pytest's built-in --junitxml). Each test simply invokes one of
the existing scripts and asserts on its exit code; the harness itself
remains the source of truth.

Usage:
    # Static lint only — no DB required:
    pytest tests/test_harness.py -k lint --html=test_report.html --self-contained-html

    # Full harness — needs a Postgres reachable via PG* env vars:
    PGHOST=localhost PGUSER=postgres \\
        pytest tests/test_harness.py --html=test_report.html --self-contained-html

    # JUnit XML for CI:
    pytest tests/test_harness.py --junitxml=junit.xml
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "pg_collector.sql"


# ---------- Static lint ----------

LINT_CHECKERS = [
    "check_safety.py",
    "check_toc.py",
    "check_if_endif.py",
    "check_dialect.py",
    "check_div_by_zero.py",
]


@pytest.mark.parametrize("checker", LINT_CHECKERS)
def test_lint(checker: str) -> None:
    result = subprocess.run(
        ["python3", f"tests/lint/{checker}", "pg_collector.sql"],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"{checker} exit={result.returncode}\n"
        f"--- stdout ---\n{result.stdout}\n"
        f"--- stderr ---\n{result.stderr}"
    )


# ---------- Runtime harness ----------

REQUIRES_DB = pytest.mark.skipif(
    not os.environ.get("PGHOST"),
    reason="PGHOST not set; runtime tests require a Postgres reachable via PG* env",
)


RUNTIME_PARAMS = [
    pytest.param(
        ["--isolate", "--seed", "empty"],
        id="empty-seed",
    ),
    pytest.param(
        ["--isolate", "--seed", "populated", "--with-pgss", "--with-aurora-mock"],
        id="populated-pgss-aurora",
    ),
]


@REQUIRES_DB
@pytest.mark.parametrize("flags", RUNTIME_PARAMS)
def test_runtime(flags: list[str], tmp_path: Path) -> None:
    env = os.environ.copy()
    env["ARTIFACT_DIR"] = str(tmp_path)
    result = subprocess.run(
        ["./tests/run.sh", *flags],
        cwd=REPO,
        capture_output=True,
        text=True,
        env=env,
    )
    tail_out = "\n".join(result.stdout.splitlines()[-40:])
    tail_err = "\n".join(result.stderr.splitlines()[-40:])
    assert result.returncode == 0, (
        f"run.sh {' '.join(flags)} exit={result.returncode}\n"
        f"--- stdout (tail) ---\n{tail_out}\n"
        f"--- stderr (tail) ---\n{tail_err}"
    )
    assert ">>> PASS" in result.stdout, "run.sh did not print the PASS banner"
