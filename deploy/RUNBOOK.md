# iSales Production RUNBOOK (v1 single-host)

Operational runbook for the iSales platform deployed on a single host.
Two platforms supported: **Linux + systemd** (primary) and
**macOS 14+ on Apple Silicon + launchd** (store / field workstation).
Each section gives the Linux command sequence inline; the macOS equivalent
is in a `<details>` block — expand it on macOS hosts.

Audience: operator running deploys, on-call engineer, anyone recovering the
system from incident.

> Architecture overview: `deploy/README.md` (Linux) / `deploy/macos/README.md`
> (macOS). Spec contract: `openspec/specs/deployment-topology/spec.md`.

---

## §1. First-time deployment

Target: a fresh Ubuntu 22.04 LTS host (4 CPU / 8 GB / 30 GB minimum).

```bash
# 0. Clone the meta-repo
git clone https://github.com/tommax-bai/isales.git ~/isales
cd ~/isales

# 1. One-time provisioning (apt install, user, dirs, redis AOF, PG init)
sudo bash deploy/linux/scripts/provision.sh

# 2. Edit the centralized env files. provision.sh has bootstrapped
#    /etc/isales/env/*.env with random PG password / JWT secret / fernet key,
#    BUT the admin login still needs to be set:
sudo -e /etc/isales/env/api.env
#    -> set ISALES_ADMIN_USER=admin
#    -> set ISALES_ADMIN_PASSWORD_HASH=$(python3 -c \
#         'import bcrypt; print(bcrypt.hashpw(b"<your-password>", bcrypt.gensalt()).decode())')

# 3. Install the first release (clones 7 service repos + builds web)
sudo bash deploy/linux/scripts/install.sh v0.1.0

# 4. Run schema migrations
sudo bash deploy/linux/scripts/migrate.sh

# 5. Switch the symlink + start services. First deploy will be outside the
#    low-peak window — pass --force.
sudo bash deploy/linux/scripts/deploy.sh <release-ts> --force --include-modem

# 6. Smoke test
curl -sf http://localhost/api/healthz | jq .
curl -sf http://localhost/                | head -1   # should be SPA index.html

# 7. Hard-gates before sending real traffic (see §6)
```

---

## §2. Routine deploy

Daily / weekly release cadence. Run during the low-peak window
(default 22:00–08:00 host TZ). Outside the window, deploy.sh refuses unless
`--force` is given (engine restart drops active calls).

```bash
# 1. Build the new release on the host
sudo bash deploy/linux/scripts/install.sh v0.1.1

# 2. (optional but recommended) preview the migrations
sudo DRY_RUN=1 bash deploy/linux/scripts/migrate.sh
sudo bash deploy/linux/scripts/migrate.sh

# 3. Promote — restart order: telephony-api -> scheduler -> worker -> engine -> api
sudo bash deploy/linux/scripts/deploy.sh <new-release-ts>

# 4. Verify
journalctl -u isales-engine -n 50 --no-pager
systemctl status isales-{api,engine,scheduler,worker,telephony-api} --no-pager
```

**modem-controller restart**: by default deploy.sh skips it (hardware coupling).
If the new release contains modem-controller changes, pass `--include-modem`
during a maintenance window.

---

## §3. Rollback

```bash
# List recent releases (sorted by mtime, current marked)
sudo bash deploy/linux/scripts/rollback.sh --list

# Rollback to a prior release
sudo bash deploy/linux/scripts/rollback.sh <prior-release-ts>
```

`rollback.sh` swaps the symlink + restarts services in the same order as
`deploy.sh`. **It does NOT touch the database schema.**

### §3.1 rollback-schema (manual, dangerous)

If the older release expects an older alembic revision, decide based on
the migration log whether to:

```bash
# Option A: leave schema forward — most v1 changes are additive (CREATE TABLE
# / ADD COLUMN nullable). Older code typically still works.

# Option B: downgrade. ONLY if you are sure no rows were written using the
# new columns. `pg_dump` first.
sudo -u postgres pg_dump --format=custom isales > /opt/isales/backups/pg/pre-downgrade-$(date +%FT%T).sql.gz
sudo bash -c '/opt/isales/current/venv/bin/alembic \
    -c /opt/isales/current/isales-common/alembic.ini downgrade -1'
```

Forward-fix is usually safer than downgrade. When in doubt, ship a bug-fix
release and `deploy.sh` it instead of rolling back.

---

## §4. Backup recovery drill

Backups land in `/opt/isales/backups/{pg,redis}/YYYY-MM-DD.{sql,rdb}.gz`,
14 days retention, triggered by `/etc/cron.d/isales-backup` daily 02:30.
Logs go to syslog tag `isales-backup`.

### §4.1 PG recovery

```bash
# 1. Spin a separate PG instance (or use a separate database name)
sudo -u postgres createdb isales_restore_test

# 2. Restore
gunzip -c /opt/isales/backups/pg/2026-05-09.sql.gz | \
    sudo -u postgres pg_restore -d isales_restore_test

# 3. Verify
sudo -u postgres psql -d isales_restore_test -c '\dt' | head -20
sudo -u postgres psql -d isales_restore_test -c \
    "SELECT (SELECT version_num FROM alembic_version), \
            (SELECT count(*) FROM campaign);"

# Pass criterion: alembic_version matches the snapshot's release, and
# count(*) of campaign matches what production had on that date.
```

### §4.2 Redis recovery

```bash
# RDB snapshots are loadable by stopping redis-server and replacing dump.rdb
sudo systemctl stop redis-server
gunzip -c /opt/isales/backups/redis/2026-05-09.rdb.gz \
    > /var/lib/redis/dump.rdb
sudo chown redis:redis /var/lib/redis/dump.rdb
sudo systemctl start redis-server

# Validate keys are present
redis-cli dbsize
redis-cli keys 'campaign:*' | head
```

Run this drill **at least quarterly** and before each major release.

---

## §5. Failure cheatsheet

| Symptom | First step | Next step |
|---------|------------|-----------|
| `psql: connection refused` | `systemctl status postgresql` | Check disk full / `journalctl -u postgresql -n 100` |
| Redis OOM (`OOM command not allowed`) | `redis-cli info memory` | bump `maxmemory` in `/etc/redis/redis.conf.d/isales.conf`; or eviction policy |
| modem-controller "device disconnected" | `udevadm monitor --kernel` to see if USB events fire | Reseat USB; `journalctl -u isales-modem-controller -n 200` |
| modem-controller exits immediately with `ISALES_MODEM_SERIAL_PATH is required` | Inspect `/etc/isales/modem-controller.env` (Linux) or `/etc/isales/env/modem-controller.env` (macOS) | Set `ISALES_MODEM_SERIAL_PATH=/dev/ttyUSB-isales-modem` (Linux, requires udev rule) or `/dev/cu.usbmodem*` (macOS, `ls /dev/cu.usbmodem*` to discover); reload systemd unit / re-run install.sh so launchd plist picks up new env. **Never** set `ISALES_ALLOW_MOCK_AT=1` in production — that bypass exists for CI only |
| modem-controller logs `MockATClient (dev/CI mode)` in production | Sign of misconfiguration: `ISALES_ALLOW_MOCK_AT=1` leaked into prod env | Remove `ISALES_ALLOW_MOCK_AT` from `modem-controller.env`; restart the service; verify with `journalctl -u isales-modem-controller \| grep MockATClient` returns nothing |
| `engine:dial` queue depth > 500 | `redis-cli llen engine:dial` | Engine likely down; `systemctl restart isales-engine` if active |
| worker celery stuck (no `summarize_call` runs) | `celery -A isales_worker inspect active` | Restart worker; check `engine:worker:call-ended` Redis list isn't empty |
| nginx 502 from `/api/` | `curl http://127.0.0.1:8000/healthz` direct | api service down; `systemctl status isales-api` |
| nginx 502 from `/ws/` | curl direct + check `journalctl -u isales-api` | WebSocket worker count is 1 by design — do not increase |
| API login failing | Check `ISALES_ADMIN_PASSWORD_HASH` in `/etc/isales/env/api.env` is bcrypt | Regenerate hash and restart isales-api |
| JWT auth between api ↔ telephony-api breaks | Verify `ISALES_JWT_SECRET` matches in both env files | Re-deploy with consistent secret; restart both services |
| Backup cron not running | `systemctl status cron`; `journalctl -t isales-backup` | Check `/etc/cron.d/isales-backup` perms (must be 0644 root) |

### §5.1 Useful one-liners

```bash
# All iSales service status at a glance
systemctl --no-pager status \
    isales-{api,engine,scheduler,worker,telephony-api,modem-controller} | \
    grep -E "Loaded|Active|Main PID"

# Latest 5 minutes of error logs across services
journalctl --since '5 min ago' -p err -u 'isales-*'

# Active call count (scheduler + engine)
redis-cli get isales:concurrency:active

# All queue depths
redis-cli --scan --pattern 'engine:*' | xargs -I% redis-cli llen %
```

---

## §6. Pre-launch hard gates

Before sending real traffic, ALL of these must pass:

- [ ] First-time deployment §1 completed on the production host
- [ ] §4 PG backup recovery drill passes (alembic version + campaign count match)
- [ ] §4 Redis recovery drill passes (dbsize > 0 after restore)
- [ ] At least one full install → deploy → rollback → deploy cycle exercised on production host
- [ ] Monitoring contact established: `prometheus.yml` deployed on operator's
      Prometheus host (per `deploy/monitoring/README.md`); at least 2 of 4
      alerts have a meaningful target (the others can be TODO)
- [ ] Smoke test: import a 10-lead test campaign with mock providers, confirm
      `call_record` rows + `transcript` populate, `worker callback_log` shows
      attempted entries, `lead.status` advances
- [ ] On-call rotation set up: who responds to alerts, contact channels

Only then flip a real campaign to active.

---

## §7. macOS deployment (Apple Silicon, macOS 14+)

This section mirrors §1–§5 for hosts running macOS 14+ on Apple Silicon
(`uname -m == arm64`). Decisions: `openspec/changes/impl-deploy-macos/design.md`.
Architecture: `deploy/macos/README.md`.

The directory skeleton (`/opt/isales/{releases,current,backups,logs}` +
`/etc/isales/env/`) is identical to Linux. Differences land in service
management (launchctl), package manager (brew), and USB / audio backends.

<details>
<summary><strong>§7.1 First-time deployment (macOS)</strong></summary>

Target: a fresh Mac mini M2 / M4 or Mac Studio M2, macOS 14 (Sonoma) or
newer, Homebrew already installed at `/opt/homebrew`.

```bash
# 0. Clone the meta-repo
git clone https://github.com/tommax-bai/isales.git ~/isales
cd ~/isales

# 1. One-time provisioning (brew install, _isales user, dirs, redis AOF, PG init).
#    MUST be invoked via sudo so brew runs as your normal user (Apple Silicon
#    brew refuses to run as root).
sudo bash deploy/macos/scripts/provision.sh

# 2. Edit centralized env (same files as Linux). provision.sh has bootstrapped
#    /etc/isales/env/*.env with random PG password / JWT secret / fernet key.
sudo -e /etc/isales/env/api.env
#    -> set ISALES_ADMIN_USER + ISALES_ADMIN_PASSWORD_HASH

# 3. Install the first release. install.sh renders 6 launchd plists with
#    /etc/isales/env/<svc>.env inlined into <EnvironmentVariables> (launchd
#    has no EnvironmentFile= equivalent), copies them to /Library/LaunchDaemons/,
#    and installs the daily backup plist.
sudo bash deploy/macos/scripts/install.sh v0.1.0

# 4. Run schema migrations
sudo bash deploy/macos/scripts/migrate.sh

# 5. Switch the symlink + bootstrap & kickstart 6 services. First deploy will
#    be outside the low-peak window — pass --force.
sudo bash deploy/macos/scripts/deploy.sh <release-ts> --force --include-modem

# 6. Smoke test
curl -sf http://localhost/api/healthz | jq .
```

</details>

<details>
<summary><strong>§7.2 Routine deploy (macOS)</strong></summary>

```bash
sudo bash deploy/macos/scripts/install.sh v0.1.1
sudo DRY_RUN=1 bash deploy/macos/scripts/migrate.sh
sudo bash deploy/macos/scripts/migrate.sh
sudo bash deploy/macos/scripts/deploy.sh <new-release-ts>
```

deploy.sh restart order is the same as Linux, but uses launchctl:
```
com.isales.telephony-api → com.isales.scheduler → com.isales.worker
  → com.isales.engine → com.isales.api
```
nginx is reloaded via `brew services reload nginx` (runs as `$SUDO_USER`).
modem-controller skipped unless `--include-modem`.

**Editing env after deploy** — because launchd inlines env at install time,
editing `/etc/isales/env/<svc>.env` requires re-running `install.sh` to push
the new values into the plists, or `launchctl bootout system <plist> &&
launchctl bootstrap system <plist>` for that single service.

</details>

<details>
<summary><strong>§7.3 Rollback (macOS)</strong></summary>

```bash
sudo bash deploy/macos/scripts/rollback.sh --list
sudo bash deploy/macos/scripts/rollback.sh <prior-release-ts>
```

Schema is left forward-applied (same default as Linux). For schema
downgrade, the alembic command is identical:
```bash
sudo -u _isales /opt/isales/current/venv/bin/alembic \
    -c /opt/isales/current/isales-common/alembic.ini downgrade -1
```

</details>

<details>
<summary><strong>§7.4 Backup recovery drill (macOS)</strong></summary>

Backups land in the same path as Linux (`/opt/isales/backups/{pg,redis}/`),
triggered by launchd `com.isales.backup` (StartCalendarInterval daily 02:30).
Logs go to unified logging under tag `isales-backup`.

Manual trigger (e.g. for the recovery drill before a release):
```bash
sudo launchctl kickstart -k system/com.isales.backup
log show --predicate 'subsystem == "isales-backup"' --last 5m --no-pager | tail
```

PG restore (using brew's psql/pg_restore):
```bash
PGPATH=/opt/homebrew/opt/postgresql@16/bin
sudo -u _isales $PGPATH/createdb isales_restore_test
gunzip -c /opt/isales/backups/pg/2026-05-09.sql.gz | \
    sudo -u _isales $PGPATH/pg_restore -d isales_restore_test
sudo -u _isales $PGPATH/psql -d isales_restore_test -c '\dt' | head -20
```

Redis restore — stop the brew service, replace dump.rdb, restart:
```bash
sudo -u $USER /opt/homebrew/bin/brew services stop redis
gunzip -c /opt/isales/backups/redis/2026-05-09.rdb.gz \
    > /opt/homebrew/var/db/redis/dump.rdb
sudo -u $USER /opt/homebrew/bin/brew services start redis
/opt/homebrew/bin/redis-cli dbsize
```

</details>

<details>
<summary><strong>§7.5 Failure cheatsheet (macOS)</strong></summary>

| Symptom | First step | Next step |
|---------|------------|-----------|
| brew service down (PG / Redis / nginx) | `brew services list` (as `$SUDO_USER`) | `brew services restart <svc>`; check `/opt/homebrew/var/log/<svc>.log` |
| launchd service down | `launchctl print system/com.isales.<svc>` | Look at `state =`; tail `/opt/isales/logs/<svc>.{out,err}.log`; `log show --predicate 'subsystem == "com.isales.<svc>"' --last 5m` |
| USB modem not recognised | `ioreg -p IOUSB \| grep -iE 'modem\|Quectel\|Huawei\|SIMCom\|ZTE'` | `system_profiler SPUSBDataType`; reseat; check `pyserial.tools.list_ports.comports()` from venv |
| AT serial port stolen by macOS modem service | `lsof /dev/cu.usbmodem*` | If macOS `usbmuxd` / `commcenter` holds it: kill the offending PID, file an internal note; long-term: SIP off + kext blacklist (per design.md risk note) |
| Core Audio errors (`PortAudio error … device unavailable`) | `python3 -c 'import sounddevice as sd; print(sd.query_devices())'` (run in venv) | Confirm USB Audio CODEC / Quectel / Huawei device shows; set `ISALES_AUDIO_DEVICE_NAME` in modem-controller.env to disambiguate |
| Plist env stale after editing /etc/isales/env/* | n/a — by design | Re-run `install.sh`, OR `launchctl bootout system <plist> && launchctl bootstrap system <plist>` |
| `brew install` failing as root | n/a — by design | Always invoke scripts via `sudo` so they re-elevate; do not run scripts as root user directly |
| `nginx: bind() to 0.0.0.0:80 failed (Permission denied)` | brew nginx defaults to 8080 on macOS | Either run on 8080, or `sudo nginx`, or `setcap` equivalent (not recommended on macOS) — see brew nginx caveats |

### §7.5.1 Useful one-liners (macOS)

```bash
# All iSales service status at a glance
for svc in api engine scheduler worker telephony-api modem-controller; do
    state=$(launchctl print system/com.isales.$svc 2>/dev/null \
        | awk '/^[[:space:]]+state =/ {print $3}')
    pid=$(launchctl print system/com.isales.$svc 2>/dev/null \
        | awk '/^[[:space:]]+pid =/ {print $3}')
    printf '  %-32s %-10s pid=%s\n' "com.isales.$svc" "${state:-?}" "${pid:-?}"
done

# Last 5 minutes of error-level unified logs from all isales services
log show --predicate 'subsystem BEGINSWITH "com.isales."' --last 5m --no-pager | grep -i error

# brew services overview
sudo -u "$SUDO_USER" /opt/homebrew/bin/brew services list

# Active call count (cross-platform — same Redis schema as Linux)
/opt/homebrew/bin/redis-cli get isales:concurrency:active
```

</details>

### §7.6 Pre-launch hard gates (macOS-specific additions)

In addition to §6 (which is platform-agnostic), the macOS rollout MUST also pass:

- [ ] `provision.sh` re-run is fully idempotent: second run prints "already exists, skipped" for every step
- [ ] `install.sh` produces a plist whose `<EnvironmentVariables>` matches `/etc/isales/env/<svc>.env` exactly (verify with `plutil -p /Library/LaunchDaemons/com.isales.api.plist | grep -A50 EnvironmentVariables`)
- [ ] Plug a real USB GSM modem; modem-controller logs `device.status = registered` within 5 s
- [ ] At least 3 real outbound calls completed end-to-end with audio audible on both ends
- [ ] Core Audio end-to-end p95 latency ≤ 200 ms (measured per `tests/macos/test_coreaudio_latency.py` with a real loopback device)
- [ ] One full install → deploy → rollback → deploy cycle exercised on the Mac host
- [ ] `launchctl kickstart system/com.isales.backup` produces a fresh PG + Redis backup; both files pass `gunzip -t`
