#!/usr/bin/env python3
"""Verify deploy/env/<service>.env.example variable sets match the variables
each service's README claims to support.

Used by `make deploy-check`. Exits non-zero on any mismatch.

Convention:
    deploy/env/<name>.env.example  variables (LHS of `^[A-Z_]+=`)
    isales-<repo>/README.md         variables in the "Environment" / "env"
                                    section, listed as `ISALES_X` or in a
                                    pipe-table column.

We map deploy template name -> service repo name + variable scope:

    api              -> isales-api
    engine           -> isales-engine
    scheduler        -> isales-scheduler
    worker           -> isales-worker
    telephony-api    -> isales-telephony   (filter to api column)
    modem-controller -> isales-telephony   (filter to modem column)

Note: README discovery is heuristic by design. We accept superset matches in
both directions but FAIL when a required variable is absent from one side.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# (env-template name, repo name, optional column-filter for telephony)
SERVICES: list[tuple[str, str, str | None]] = [
    ("api", "isales-api", None),
    ("engine", "isales-engine", None),
    ("scheduler", "isales-scheduler", None),
    ("worker", "isales-worker", None),
    ("telephony-api", "isales-telephony", "api"),
    ("modem-controller", "isales-telephony", "modem"),
]

# These vars are platform conventions / documented as cross-service shared
# (TZ on every service that mentions wall-clock; database/redis URL ditto).
# We also accept FERNET_KEY in worker even though api README doesn't list it
# (current behavior — see tasks 2.7 follow-up).
ALLOW_TEMPLATE_EXTRAS: dict[str, set[str]] = {
    # Vars the template may carry without README backing (commented-out
    # debug / mock harness toggles, OS-conventional vars).
    "*": {"TZ"},
    "modem-controller": {"ISALES_SKIP_UDEV", "MOCK_DIAL_DELAY_MS", "MOCK_CALL_DURATION_MS"},
}

ENV_VAR_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=", re.MULTILINE)
README_VAR_RE = re.compile(r"`(ISALES_[A-Z0-9_]+|MOCK_[A-Z0-9_]+|TZ)`")


def vars_in_template(path: Path) -> set[str]:
    """Collect variables documented in the template — both active assignments
    AND commented-out optional vars (e.g. `# MOCK_DIAL_DELAY_MS=1000`). The
    template is part of the service's documented contract, so a commented
    line still counts as 'documented'.
    """
    text = path.read_text()
    out: set[str] = set()
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            stripped = stripped.lstrip("#").lstrip()
        match = re.match(r"([A-Z][A-Z0-9_]*)=", stripped)
        if match:
            out.add(match.group(1))
    return out


def vars_in_readme(path: Path, column_filter: str | None) -> set[str]:
    text = path.read_text()
    if column_filter is None:
        return set(README_VAR_RE.findall(text))

    # telephony README has a 4-column table:
    #   | variable | api | modem | meaning |
    # Find the table header and only collect from rows where the requested
    # column has 'yes'/'opt'.
    out: set[str] = set()
    in_table = False
    col_index = None  # 1-based for `api` or `modem` column
    for line in text.splitlines():
        if line.startswith("| variable") and "api" in line and "modem" in line:
            in_table = True
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            try:
                col_index = cells.index(column_filter)
            except ValueError:
                col_index = None
            continue
        if in_table:
            if not line.startswith("|"):
                in_table = False
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if col_index is None or len(cells) <= col_index:
                continue
            mark = cells[col_index].lower()
            if mark not in {"yes", "opt"}:
                continue
            varname_match = re.search(r"`([A-Z][A-Z0-9_]+)`", cells[0])
            if varname_match:
                out.add(varname_match.group(1))
    # Also pick up bare-list mentions in non-table sections (telephony README
    # has both forms).
    if not out:
        out = set(README_VAR_RE.findall(text))
    return out


def main() -> int:
    failures: list[str] = []
    extras_allowed = ALLOW_TEMPLATE_EXTRAS.get("*", set())

    for env_name, repo, column in SERVICES:
        tpl = REPO_ROOT / "deploy" / "env" / f"{env_name}.env.example"
        readme = REPO_ROOT.parent / repo / "README.md"
        if not tpl.exists():
            failures.append(f"[{env_name}] missing template {tpl}")
            continue
        if not readme.exists():
            failures.append(f"[{env_name}] missing README {readme}")
            continue

        tpl_vars = vars_in_template(tpl)
        readme_vars = vars_in_readme(readme, column)
        extras_for_svc = extras_allowed | ALLOW_TEMPLATE_EXTRAS.get(env_name, set())

        only_in_tpl = tpl_vars - readme_vars - extras_for_svc
        only_in_readme = readme_vars - tpl_vars

        if only_in_tpl:
            failures.append(
                f"[{env_name}] variables in {tpl.name} but not in {repo}/README.md: "
                + ", ".join(sorted(only_in_tpl))
            )
        if only_in_readme:
            failures.append(
                f"[{env_name}] variables in {repo}/README.md but not in {tpl.name}: "
                + ", ".join(sorted(only_in_readme))
            )

    if failures:
        print("env consistency check FAILED:", file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print("env consistency check ok ({} services)".format(len(SERVICES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
