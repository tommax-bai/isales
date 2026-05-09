# iSales Production RUNBOOK (v1 single-host)

Operational runbook for the iSales platform deployed on a single Linux host
under systemd. Audience: operator running deploys, on-call engineer, anyone
recovering the system from incident.

> Architecture overview: `deploy/README.md`. Spec contract: `openspec/specs/deployment-topology/spec.md`.

---

## §1. First-time deployment

Target: a fresh Ubuntu 22.04 LTS host (4 CPU / 8 GB / 30 GB minimum).

```bash
# 0. Clone the meta-repo
git clone https://github.com/tommax-bai/isales.git ~/isales
cd ~/isales

# 1. One-time provisioning (apt install, user, dirs, redis AOF, PG init)
sudo bash deploy/scripts/provision.sh

# 2. Edit the centralized env files. provision.sh has bootstrapped
#    /etc/isales/env/*.env with random PG password / JWT secret / fernet key,
#    BUT the admin login still needs to be set:
sudo -e /etc/isales/env/api.env
#    -> set ISALES_ADMIN_USER=admin
#    -> set ISALES_ADMIN_PASSWORD_HASH=$(python3 -c \
#         'import bcrypt; print(bcrypt.hashpw(b"<your-password>", bcrypt.gensalt()).decode())')

# 3. Install the first release (clones 7 service repos + builds web)
sudo bash deploy/scripts/install.sh v0.1.0

# 4. Run schema migrations
sudo bash deploy/scripts/migrate.sh

# 5. Switch the symlink + start services. First deploy will be outside the
#    low-peak window — pass --force.
sudo bash deploy/scripts/deploy.sh <release-ts> --force --include-modem

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
sudo bash deploy/scripts/install.sh v0.1.1

# 2. (optional but recommended) preview the migrations
sudo DRY_RUN=1 bash deploy/scripts/migrate.sh
sudo bash deploy/scripts/migrate.sh

# 3. Promote — restart order: telephony-api -> scheduler -> worker -> engine -> api
sudo bash deploy/scripts/deploy.sh <new-release-ts>

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
sudo bash deploy/scripts/rollback.sh --list

# Rollback to a prior release
sudo bash deploy/scripts/rollback.sh <prior-release-ts>
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
