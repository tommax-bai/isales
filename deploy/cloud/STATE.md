# cloud deployment — current state snapshot

**Last updated**: 2026-05-17 (ARTC Linux SDK vendored; previous: interactive provisioning session)

This file is a **point-in-time snapshot** of what's actually deployed to the
iSales cloud, distinct from `deploy/RUNBOOK-cloud.md` which describes *how*
to deploy from scratch. Update this file whenever cloud topology changes.

If you're picking up the project on a fresh dev machine, this is the
fastest way to learn the current state of the cloud-side world.

## ECS

| Field | Value |
|---|---|
| Public IP | `121.89.85.150` |
| Hostname | `iZ0jlev0nr9m65tj6546zyZ` |
| Region | Aliyun (region inferred from console; verify before any region-specific work) |
| OS | **Alibaba Cloud Linux 3.2104 U13 (OpenAnolis Edition)** — RHEL 8-compatible, `dnf`/`yum`-based |
| Arch | x86_64 |
| CPU / RAM | 8C 8G (provisioned; A2 spec called for 4C16G — fine for PoC) |
| Disk | 40 GiB system disk, ~33 GiB free |
| Swap | none (default) |
| SSH | port 22, public key auth only (key bound via Aliyun console "SSH 密钥对") |
| Login user | `root` |

### SSH access from a dev machine

The `.pem` private key must be on your machine. The SSH command shape:

```
ssh -i <path-to>/isales.pem root@121.89.85.150
```

The current developer keeps the key at `C:\Users\tianx\codes\isales.pem`
(Windows). On a new machine: copy the `.pem` from a secure location
(e.g. password manager attachment, USB drive, another dev machine's
`~/.ssh/`), `chmod 600` it on macOS/Linux, then test:

```
ssh -i ~/.ssh/isales.pem root@121.89.85.150 'hostname'
```

The key's fingerprint (so you can verify you have the right `.pem`):

```
2048 SHA256:ESKEddFU95g0ytlCZyTYEg3T4SHYNe7oBVPHpWQI5k0 (RSA)
```

If `Permission denied (publickey)`: the key is either wrong, not bound
to this ECS in the Aliyun console, or has wrong file permissions on a
Unix host. Aliyun console → ECS instance → "更多 > 密钥对 > 绑定/解绑
密钥对".

## Installed components on the ECS

All on the same single instance — no managed RDS / Redis, no separate
nodes. Single-host posture acceptable for v1.0 PoC (no HA).

| Service | Version | systemd unit | Listen | Auth |
|---|---|---|---|---|
| PostgreSQL | 13.23 | `postgresql.service` | `127.0.0.1:5432`, `[::1]:5432` | scram-sha-256, user `isales` |
| Redis | 6.2.20 | `redis.service` | `127.0.0.1:6379`, `[::1]:6379` | `requirepass` |
| sshd | (system) | `sshd.service` | `0.0.0.0:22` | pubkey-only |

PostgreSQL data dir: `/var/lib/pgsql/data/`.
Redis config: `/etc/redis.conf`.

**No** nginx, no Let's Encrypt cert, no domain — A2 §1.1 still pending.
**No** isales-api / engine / scheduler / worker / web deployed yet —
provisioned the data plane only.

### Why PG 13 not PG 16

`alinux3-updates` repo only carries `postgresql-13.23-2.0.1.al8`.
Installing PG 16 would require adding the PostgreSQL Global Development
Group (PGDG) repo against RHEL 8, which works but introduces one more
maintained dependency. v1.0 schema is plain SQLAlchemy migrations
compatible across PG 13–16, so PG 13 was chosen as the simplest stable
path. To upgrade later: `pg_dumpall` → install PG 16 from PGDG → `psql
< dump.sql` → cutover.

### Why AL3 not Ubuntu 22.04

The ECS was already provisioned with AL3 by the user before the iSales
deployment work began. Reprovisioning to Ubuntu was deemed not worth
the cost (PG/Redis on AL3 are first-class supported). Implication:
`deploy/cloud/scripts/install.sh` (originally written for Ubuntu apt)
needs an `apt → dnf` adaptation pass before it's runnable here. The
required package mappings:

| Ubuntu apt | AL3 dnf |
|---|---|
| `postgresql postgresql-contrib` | `postgresql-server postgresql-contrib` (already installed) |
| `redis-server` | `redis` (already installed) |
| `python3.12 python3.12-venv` | needs PythonNN scl or build-from-source — verify before deploy |
| `nginx` | `nginx` (in `epel`) |

## Secrets

Real values live in `deploy/cloud/env/{api,engine,scheduler,worker}.env`,
committed to this private repo per the 2026-05-17 decision. See
`deploy/cloud/env/README.md` for the policy, rotation procedure, and
the migration path when secrets need to leave git.

To use the secrets on the ECS:

```bash
for svc in api engine scheduler worker; do
  scp -i ~/.ssh/isales.pem deploy/cloud/env/$svc.env \
      root@121.89.85.150:/etc/isales/env/$svc.env
done
ssh -i ~/.ssh/isales.pem root@121.89.85.150 \
    'mkdir -p /etc/isales/env && chown root:isales /etc/isales/env/*.env && chmod 0640 /etc/isales/env/*.env'
```

The `isales` group needs to exist for chmod 0640 to make sense — create
it once: `groupadd isales` (the install scripts do this; if you're
mirroring env before running `install.sh`, do it manually first).

## ARTC SDK vendor — where the binaries live

The ARTC SDK is proprietary and **gitignored** in every repo it touches.
Three platform variants, three locations:

| Platform | Used by | Location |
|---|---|---|
| Linux Python wrapper | cloud engine | **ECS**: `/opt/isales/vendor/aliyun-artc-linux-python/` (symlink → `AliRTCSDK_Linux-7.10.2/`). Tarball + extracted dir both kept under `/opt/isales/vendor/`. Not on local Windows dev machine — pulled straight from alicdn to ECS. |
| Windows C++ SDK | edge (Windows client) | (in repo) `isales-telephony/deploy/edge/windows/vendor/aliyun-artc-windows/`. Gitignored. |
| macOS framework | edge (Mac mini QA only) | Not downloaded — A2 走 mock，未真实用到 |

Linux Python tarball (137 MiB, sha256 `09564bad835f2296140bc6c9f2d8d4a88e7e940de07cbb0a470b3cd8d5db0e98`)
download direct from alicdn CDN, no auth required:

```
https://alivc-demo-cms.alicdn.com/versionProduct/sdk/linux/AliRTCSDK_Linux-7.10.0-20260109.tar.gz
```

Note the filename says `7.10.0` but the tarball's top-level dir is `AliRTCSDK_Linux-7.10.2/` — Aliyun marketing tag inconsistent. The 7.10.2 inside is what we use.

The Python wrapper is ctypes-style FFI (4 `.py` files + a `Release/lib/`
with `libAliRtcLinuxEngine.so` (50 MiB), `libonnxruntime.so.1.16.3`
(17 MiB), `AliRtcCoreService` elf). **Not bound to a Python ABI** —
AL3's stock Python 3.6.8 imports all four modules without issue;
`ldd libAliRtcLinuxEngine.so` resolves cleanly against AL3 glibc 2.32.

At runtime, callers MUST set `LD_LIBRARY_PATH` to include
`/opt/isales/vendor/aliyun-artc-linux-python/Python/Release/lib` and
pass `AliRtcCoreService` absolute path to `CreateAliRTCEngine(...)`.

For CI / OSS distribution: A2 task 1.3 plans an OSS private bucket
mirror; not provisioned yet — but given the alicdn URL is unauthenticated,
the OSS mirror is no longer strictly needed (CI can pull direct).
The Windows SDK URL is pinned in
`isales-telephony/deploy/edge/windows/vendor/README.md`.

## OSS / object storage

**Not provisioned in v1.0.** The decision is to use ECS local
filesystem for v1.0 storage needs (recording uploads, opener prerender
PCM). v1.0 worker code doesn't yet exercise `ISALES_OSS_*` envvars, so
this is a no-op decision today; if/when recording upload lands, switch
to either OSS or a larger ECS disk.

## Active OpenSpec changes touching the cloud

| Change | Status | Cloud impact |
|---|---|---|
| `arch-cloud-edge-split` (A2) | 52/64 tasks; pending §1 Sprint 0 + §12 e2e | This whole snapshot is A2's data plane |
| `windows-client-core` (D1) | 38/53 tasks; pending hardware bring-up | Only edge-side; doesn't change this snapshot |
| `windows-artc-pybind11` | 37/51 tasks; §1-§7 implemented | Only edge-side |
| `impl-real-at` (A1) | 23/27 tasks; pending hardware acceptance | None |

## Deviations from spec to record at archive time

When A2 / D1 are archived, the following deviations must land as
`design.md` notes in the archived `openspec/changes/archive/...`
directories:

1. **AL3 vs Ubuntu 22.04** — install.sh apt → dnf required.
2. **PG 13 vs PG 16** — schema-compatible; cite "alinux3-updates default" reason.
3. **8C8G vs 4C16G** — half RAM; load-test to confirm; bump if needed.
4. **PG + Redis on the ECS vs managed RDS/Tair** — no HA; cite v1.0 PoC scope.
5. **No OSS** — local filesystem; cite "worker doesn't read OSS_* yet".
6. **Secrets in private repo git** — non-default policy; cite "single
   collaborator + internal PoC" with the README's migration path.

## Next deployment steps (what's still pending)

In rough order:

1. Mirror `deploy/cloud/env/*.env` to `/etc/isales/env/` on the ECS.
2. Adapt `deploy/cloud/scripts/install.sh` for AL3 dnf (file an issue
   or a small fix-up PR).
3. ~~Upload ARTC SDK Linux Python tarball.~~ **DONE 2026-05-17** —
   wget'd from alicdn to `/opt/isales/vendor/`, symlinked to
   `aliyun-artc-linux-python`, import-smoke on Python 3.6.8 passed.
4. Clone 5 sibling repos to `/opt/isales/releases/<ts>/` on the ECS,
   create venvs, alembic migrate, register systemd units.
5. nginx + Let's Encrypt + domain (A2 §1.1).
6. End-to-end smoke: scheduler dispatches a fake lead → engine joins
   ARTC channel → edge (Windows) joins same channel → audio flows.
