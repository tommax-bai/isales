# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is (and isn't)

This is the **iSales meta-repo**. It contains specs, the implementation plan, and cross-repo tooling — **no runtime code**. The seven service codebases live in sibling directories next to this one:

```
../isales-common      # SQLAlchemy models / Pydantic schemas / Provider ABCs / Alembic migrations
../isales-api         # FastAPI admin backend + WebSocket proxy
../isales-telephony   # telephony-api (HTTP) + modem-controller (AT commands, USB GSM modem)
../isales-scheduler   # lead dispatch, time windows, retry/follow-up
../isales-worker      # post-call summary, webhook fan-out
../isales-engine      # realtime call engine: state machine + 3-layer AI pipeline (N-role PK + N×M judges + 1 polish)
../isales-web         # Vue 3 admin frontend
```

`isales-common` is consumed as a pip package by the other six; there is no monorepo. When a task spans service boundaries, treat each sibling repo as a separate work area with its own venv, tests, and git history.

## Commands

All commands run from the repo root and shell out to sibling repos via `../`.

```bash
make test-all                          # pytest in each python service + vitest in isales-web
make test-all PYTEST_ARGS="-k modem"   # pass-through args go to every pytest invocation
make spec-validate                     # openspec validate --specs && --changes
make deploy-check                      # shellcheck deploy/**/*.sh + env-template ↔ service-README consistency
```

`scripts/test_all.sh` **silently skips** a sibling repo if `../<repo>/.venv/bin/python` (Python) or `../<repo>/node_modules` (web) is missing — bootstrap each one with `pip install -e ".[dev]"` or `npm install` before relying on the aggregate result. A skipped repo shows as `?` in the summary; only `✗` returns non-zero.

External tools the Makefile assumes are on `$PATH`: `openspec`, `shellcheck`, `python3`. They are not vendored.

To run a single test in one service, work in that sibling repo directly:

```bash
cd ../isales-engine && .venv/bin/python -m pytest -q -k "test_barge_in"
```

## OpenSpec workflow — the only way to change behavior specs

Direct edits to `openspec/specs/*.md` are deprecated. All spec changes flow through OpenSpec change proposals:

```bash
openspec list                           # active changes
openspec status --change <name>         # progress on one change
/opsx:propose <name>                    # draft a new change (folder under openspec/changes/<name>/)
/opsx:apply <name>                      # implement against the proposal
/opsx:archive <name>                    # finalize, sync specs/, move to openspec/changes/archive/
```

Each change folder contains `proposal.md` (why / what / impact), `design.md` (detail + tradeoffs), `tasks.md` (checklist with inline implementation notes), and `specs/<capability>/spec.md` deltas. Archived changes under `openspec/changes/archive/` are the source of truth for what's actually been built (the chronological `YYYY-MM-DD-<name>/` directories there encode the project's real history far better than git log alone).

Spec files use a strict format that `openspec validate` enforces: `## Requirements` → `### Requirement: ...` (with MUST/SHALL/SHOULD/MAY) → `#### Scenario:` blocks with `WHEN`/`THEN` bullets. Preserve this structure when editing.

## Architecture reading order

1. `README.md` — repo layout + production deploy entry points.
2. `DESIGN.md` — index into the 19 capability specs under `openspec/specs/`. Start there to find the right spec for a domain question.
3. `openspec/specs/architecture/spec.md` — repo split, single-host invariant (being amended; see below), shared-store rules.
4. `openspec/specs/service-communication/spec.md` — the inter-service channel matrix (Redis queue vs pub/sub, HTTP, gRPC, Unix socket).
5. `IMPLEMENTATION_PLAN.md` — phase 0–8 build order. Completed phases now point to their archived OpenSpec change for canonical detail.
6. `openspec/v1-roadmap.md` + `openspec/v1-roadmap-aliyun-rtc-poc*.md` — current strategic direction (cloud-edge split, Aliyun RTC PaaS, Windows edge client).

## Active architectural pivot — read before assuming "v1 single-host"

The `architecture` spec still declares "v1 single-host deployment" (Linux/macOS, all 7 services on one box, USB modem direct-attached). That model is being superseded:

- **`openspec/changes/arch-cloud-edge-split/`** moves 5 services (api/engine/scheduler/worker/web) to Aliyun ECS and keeps only `modem-controller` + a new `audio-bridge` module on the edge. Media plane is Aliyun RTC PaaS; control plane is gRPC bidi streaming with bearer tokens. Engine session co-location means barge-in cancels bypass Redis Pub/Sub in v1.0.
- **`openspec/changes/windows-client-core/`** retargets the edge from Mac mini to customer-owned Windows PCs (one seat = one PC + one USB GSM modem + one SIM). 24/7 uptime assumptions are dropped; the edge becomes a tray app with offline buffering.
- **`openspec/changes/impl-real-at/`** swaps mock AT clients for real `pyserial`-driven AT command paths in `modem-controller`.

When working on architecture, deployment-topology, service-communication, or device-hardware specs, **check the active changes first** — the merged spec text may not yet reflect what's currently being built. Conversely, when editing service code, the active proposals tell you which direction not to design against.

## Deploy / runbook anchors

- `deploy/RUNBOOK.md` — operational source of truth (first-time deploy, routine deploy, rollback, backup drill, pre-launch hard-gates, failure cheatsheet). Linux is mainline; macOS sections are in `<details>` blocks.
- `deploy/RUNBOOK-cloud.md` — cloud-edge variant: how to do a clean cloud-side deploy from scratch (Aliyun ECS / RDS / Redis / OSS / domain / TLS) plus debug/backup procedures.
- `deploy/cloud/STATE.md` — **current deployment snapshot** (ECS IP, OS, installed versions, vendor paths, deviations, pending steps). Read this first when picking up cloud work on a new dev machine — it's the fastest way to learn what's actually running. Update it whenever cloud topology changes.
- `deploy/cloud/env/` — real secret values for the 4 cloud services (private-repo policy; see `deploy/cloud/env/README.md` for rotation + migration-out-of-git steps).
- `deploy/cloud/` + `deploy/edge/` — cloud-edge split deployment artifacts (current direction).
- `deploy/linux/` + `deploy/macos/` — legacy single-host deployment artifacts (still operational).
- `deploy/env/*.env.example` — centralized EnvironmentFile templates; `make deploy-check` enforces they stay in sync with each service repo's README "Environment" section.

The deploy scripts assume `/opt/isales/{releases,current,backups,logs}` + `/etc/isales/env/` layout and an `isales` system user (Linux) or `_isales` (macOS).

ARTC SDK binaries are proprietary and gitignored everywhere; vendor paths
and download URL are pinned in `deploy/cloud/STATE.md` § "ARTC SDK vendor".

## Conventions worth knowing before editing

- **Cross-repo refactors**: if a change touches `isales-common`, bump its version and update consumers' pins — there is no live link between sibling repos.
- **Channel discipline**: Redis Queue = "must deliver, async OK"; Redis Pub/Sub = "realtime, lossy OK". The matrix in `service-communication/spec.md` is exhaustive; introducing a new channel requires a change proposal.
- **Global concurrency**: cross-engine concurrency caps MUST use Redis `INCR/DECR`. Local in-process counters are explicitly forbidden by spec.
- **JWT**: `isales-api` is the sole issuer; `telephony-api` only verifies. Shared HMAC secret travels via env files. `isales-web` connects to `telephony-api` directly, not through `isales-api`.
- **Spec language**: requirements use RFC 2119 keywords (MUST / SHALL / SHOULD / MAY). When proposing changes, mirror that vocabulary.
