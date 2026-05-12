# PR #12 hardware acceptance log (2026-05-12)

Host: macOS 26.3.1 / arm64 / Apple M4 Mac mini / Homebrew @ `/opt/homebrew`.
USB modem: SIMCom A7670E-FASE via WCH CH343 (`1a86:55d3`) on
`/dev/cu.usbmodem5ABA0115671`. SIM: China Unicom LTE.

## 12.1 — hardware confirmed

AT direct dial of 13301035545 (operator personal handset) reached real
audible 10 s answer. Call state transitions observed: `2 → 3 → 0 → 6`
(ATD → alert → active → release).

## 12.2 — full install→migrate→deploy

A pre-existing first release `20260509-175955` was already on the host
from 5月 9. Acceptance built a second release to validate the full
sequence + provide a rollback target.

```
$ sudo env ISALES_GIT_BASE=file:///Users/bears/codes \
    bash deploy/macos/scripts/install.sh main
[info]  iSales install.sh (macOS) starting (release=20260512-170755, ref=main, DRY_RUN=0)
[info]  step 1/6: prepare release dir /opt/isales/releases/20260512-170755 + sync deploy/
[info]  syncing meta-repo deploy/ into /opt/isales/releases/20260512-170755/deploy/
[info]  step 2/6: clone/update repos at ref=main          # 7 repos via file://
[info]  step 3/6: create venv + pip install               # isales-common + 5 services + [macos]
[info]  step 4/6: build isales-web                        # ✓ built in 3.01s
[info]  step 5/6: install launchd plists with inlined env
[info]  installed + bootstrapped /Library/LaunchDaemons/com.isales.bootstrap-runtime.plist
[info]  installed /Library/LaunchDaemons/com.isales.{api,engine,scheduler,worker,telephony-api,modem-controller}.plist
[info]  installed + bootstrapped /Library/LaunchDaemons/com.isales.backup.plist
[info]  step 6/6: sync nginx config
[info]  install complete: /opt/isales/releases/20260512-170755

$ sudo bash deploy/macos/scripts/migrate.sh
[info]  running alembic upgrade head
INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
INFO  [alembic.runtime.migration] Will assume transactional DDL.
[info]  alembic upgrade complete

$ sudo bash deploy/macos/scripts/deploy.sh 20260512-170755 --force --include-modem
[info]  step 1/3: switch /opt/isales/current -> /opt/isales/releases/20260512-170755
[info]  step 2/3: restart services in dependency order
[info]  launchctl kickstart -k system/com.isales.telephony-api
[info]  launchctl kickstart -k system/com.isales.scheduler
[info]  launchctl kickstart -k system/com.isales.worker
[info]  launchctl kickstart -k system/com.isales.engine
[info]  launchctl kickstart -k system/com.isales.api
[info]  /opt/homebrew/bin/nginx -t                        # ok
[info]  launchctl kickstart -k user/<uid>/homebrew.mxcl.nginx
[info]  step 3/3: deployment summary
  com.isales.telephony-api         running    pid=58865
  com.isales.scheduler             running    pid=58872
  com.isales.worker                running    pid=58879
  com.isales.engine                running    pid=58887
  com.isales.api                   running    pid=58896
  com.isales.modem-controller      running    pid=…
$ curl -s http://127.0.0.1:8080/api/health
{"status":"ok"}
```

**Three deploy-artifact bugs fixed in PR #12 itself**:

1. `install.sh` now `cp -RL $META_REPO_DIR/deploy → $RELEASE_DIR/deploy`
   so `com.isales.backup.plist`'s `/opt/isales/current/deploy/macos/
   scripts/backup_*.sh` paths resolve (cron was logging `No such file
   or directory` daily since first install).
2. New `com.isales.bootstrap-runtime.plist` (root, `RunAtLoad=true`,
   `LaunchOnlyOnce=true`) re-creates `/var/run/isales` on every boot.
   macOS `/var/run` is tmpfs; the directory disappears on reboot,
   causing `modem-controller` to ENOENT inside `start_unix_server`
   and crash-loop (err.log had grown to 19 MB before this drill).
3. `deploy.sh` / `rollback.sh` replace `brew services reload nginx`
   with `launchctl kickstart -k user/<uid>/homebrew.mxcl.nginx`. Brew
   refuses `formula.jws.json` API access under nested sudo even after
   `sudo -u` drops to a non-root account; targeting the launchd label
   directly avoids brew completely.

## 12.3 — USB watcher dev-mode

`MacOSIokitWatcher` (1 Hz `comports()` polling) detects A7670 insert/
remove, GSM_MODEM_WHITELIST match on `1a86:55d3`, `_touch_last_seen`
updates `device.last_seen_at` in DB. `status=registered` transition
belongs to telephony-api `register` endpoint (stage-8 scope).

## 12.6 — Core Audio latency framework

```
$ python -m pytest tests/macos/test_coreaudio_latency.py -v
tests/macos/test_coreaudio_latency.py::test_end_to_end_latency_within_budget SKIPPED
tests/macos/test_coreaudio_latency.py::test_loopback_device_resolution_finds_known_drivers PASSED
tests/macos/test_coreaudio_latency.py::test_module_imports_cleanly PASSED
======================== 2 passed, 1 skipped in 35.30s =========================

$ python -c 'import sounddevice as sd; [print(i,d) for i,d in enumerate(sd.query_devices())]'
0 'Mac mini扬声器' in=0 out=2 sr=48000.0
```

**Hardware gap**: this Mac mini has exactly one audio device (built-in
speaker, output-only). The A7670E exposes USB-CDC serial only (via
CH343 bridge) — no USB Audio CODEC interface. No BlackHole / Loopback
kext installed. The p95 ≤ 200 ms trial cannot run here.

**Gate moves to**: (a) acquiring a real production GSM modem with USB
Audio CODEC interface and re-running this test against the hardware
audio loopback, or (b) installing BlackHole 2ch on staging and running
the proxy latency trial there. PR #4's 13 `_FakeStream` unit tests
cover backend behavioral correctness today.

## 12.7 — rollback drill

```
$ sudo bash deploy/macos/scripts/rollback.sh --list
[info]  available releases under /opt/isales/releases/:
  20260512-170755  v0.1.2 (current)
  20260509-175955  v0.1.2

$ sudo bash deploy/macos/scripts/rollback.sh 20260509-175955 --force --include-modem
[warn]  ROLLBACK: /opt/isales/releases/20260512-170755  ->  /opt/isales/releases/20260509-175955
[info]  ln -sfn /opt/isales/releases/20260509-175955 /opt/isales/current
[info]  launchctl kickstart -k system/com.isales.{telephony-api,scheduler,worker,engine,api}
[info]  launchctl kickstart -k user/<uid>/homebrew.mxcl.nginx
[info]  launchctl kickstart -k system/com.isales.modem-controller
[info]  rollback complete

# verification
$ readlink /opt/isales/current
/opt/isales/releases/20260509-175955

$ for svc in api engine scheduler worker telephony-api modem-controller ; do …; done
com.isales.api                   running
com.isales.engine                running
com.isales.scheduler             running
com.isales.worker                running
com.isales.telephony-api         running
com.isales.modem-controller      running

$ /opt/isales/current/venv/bin/python -c 'from serial.tools.list_ports import comports
for p in comports(): print(p.device, f"{p.vid:04x}:{p.pid:04x}", p.product)'
/dev/cu.debug-console 0000:0000 None
/dev/cu.Bluetooth-Incoming-Port 0000:0000 None
/dev/cu.usbmodem5ABA0115671 1a86:55d3 USB Single Serial

$ curl -s http://127.0.0.1:8080/api/health
{"status":"ok"}
```

Forward-deployed back to `20260512-170755` afterwards to set up 12.8.

## 12.8 — backup launchctl drill

```
$ sudo launchctl kickstart -k system/com.isales.backup
$ sudo launchctl print system/com.isales.backup | grep -E 'state|last exit'
        state = not running
        last exit code = 0
                state = active
                state = active

$ ls -la /opt/isales/backups/{pg,redis}/
/opt/isales/backups/pg/2026-05-12.sql.gz     9340  May 12 17:26
/opt/isales/backups/redis/2026-05-12.rdb.gz   205  May 12 17:26

$ gunzip -t /opt/isales/backups/pg/2026-05-12.sql.gz    # OK
$ gunzip -t /opt/isales/backups/redis/2026-05-12.rdb.gz # OK
$ gunzip -c /opt/isales/backups/redis/2026-05-12.rdb.gz | file -
/dev/stdin: Redis RDB file, version 0013
$ gunzip -c /opt/isales/backups/pg/2026-05-12.sql.gz | head -c 80
PGDMP  5                    ~            isales    16.13 (Homebrew)
```

**Caveat noted during drill**: the first two `launchctl kickstart -k`
re-fires after manual `kill` of the prior backup PID left the bash
`-c` wrapper hanging with no children, no stdout, no tmp file. The
third kickstart (after a clean `kill`) completed in ~5 s. Suspected
launchd zombie state from `kickstart -k`; the daily 02:30 cron path
will not encounter this since each fire starts from a fresh state.

## Out-of-scope deferred items

- 12.4 / 12.5 — end-to-end mock-provider campaign + 3-turn real
  conversation → split into stage-8 change `impl-real-at` (modem-
  controller `main.py` still hard-codes `MockATClient`; real
  `SerialATClient` adapter bridging `drivers.ModemDriver` ↔
  `at_client.ATClient` Protocol belongs to that change).
- 12.6 hardware p95 gate — see hardware-gap note above.
