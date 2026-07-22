# TaskQueue: NPU 共享机器轻量任务队列

## Summary

Implement a lightweight task queue for shared Ascend NPU machines, enabling multi-user job scheduling with automatic device allocation, mutual exclusion, and privilege separation. Users submit commands via `task-submit`, a root-privileged daemon dispatches them with flock-based NPU locking and `runuser` de-escalation, ensuring no two tasks compete for the same device.

## Motivation / Use Case

Shared NPU machines with multiple users face a core conflict:

```
User A: python train.py -d 0    ← occupies NPU 0
User B: python train.py -d 0    ← same device, silent corruption or crash
User C: python train.py -d 0    ← unaware of A and B
```

Without coordination:
- Users manually check `npu-smi` and pick a card — error-prone, race-prone
- No mutual exclusion — two jobs on the same NPU cause silent data corruption or OOM kills
- No privilege separation — users need direct device access, can't enforce policies
- No queuing — if all cards are busy, users busy-wait or give up

TaskQueue solves this with:
- **Automatic device allocation**: daemon picks a free NPU from a whitelist, user code just uses logical device 0
- **flock-based mutual exclusion**: `npu-lock` holds a file lock per device, released on process exit (even crashes)
- **Privilege separation**: daemon runs as root, tasks run as the submitting user via `runuser`
- **Queueing**: tasks wait in pending/ until a device is free, FIFO order

## Current Architecture

### Three-Layer Design

| Layer | Component | Mechanism | Purpose |
|---|---|---|---|
| Terminal isolation | `profile.d/taskqueue-npu.sh` | `ASCEND_RT_VISIBLE_DEVICES` | Hide protected cards from user shells |
| Device mutex | `npu-lock` / flock | Per-device lock files | Prevent concurrent NPU access |
| Device allocation | daemon / `available_devices` | Whitelist (currently `12,13,14,15`) | `--device auto` only assigns from protected pool |

**Environment**: 16 NPU cards (physical 0-15), 50 restricted users, `MAX_CONCURRENT=15`.

### Task Lifecycle

```
User                        Daemon                      AICore
  │                           │                           │
  ├─ task-submit "cmd" ──►  pending/task_xxx             │
  │   (snapshot env,          │                           │
  │    write task file)       │                           │
  │                         ┌─┤ poll: mv pending→running  │
  │                         │ ├─ resolve_device(auto→12)  │
  │                         │ ├─ npu-lock 12 flock()      │
  │                         │ ├─ inject TASK_DEVICE=12    │
  │                         │ ├─ runuser -u $USER -- cmd ─┼──► execute on NPU 12
  │                         │ │   (watchdog: max-time)    │
  │  --wait ──► tail -f log │ │                           │
  │                         │ ├─ wait $pid; exit_code=$?  │
  │                         │ ├─ write done/task_xxx      │
  │                         │ └─ release flock            │
  │  ◄── exit $exit_code ──┘                              │
```

### Components

| File | Role |
|---|---|
| `task-submit.sh` | User CLI: submit, wait, log, cancel, kill, list, maintenance, device management |
| `task-daemon.sh` | Root daemon: poll pending/, allocate devices, de-escalate, timeout watchdog |
| `npu_lock.sh` | flock-based device mutex, multi-card deadlock-free (ascending lock order) |
| `taskqueue-npu.sh` | profile.d script: terminal device visibility control |
| `setup.sh` | First-time install (system-level or `--local` user-level) |
| `deploy.sh` | One-command redeploy after source changes |

### What's Working

**Core**: task-submit → daemon dispatch → npu-lock → runuser execution → done, full lifecycle with `--wait`/`--status`/`--log`/`--cancel`/`--kill`. Ctrl+C during `--wait` auto-cancels pending or sends kill request to running tasks.

**Device management**: `--device auto` allocates from whitelist, `--device-num N` for multi-card, `--devices "2,3,4,5"` hot-reloads whitelist via SIGHUP. npu-lock supports multi-card ascending-order locking with reentry detection.

**Environment**: full env snapshot at submit time (`env -0`), `--env`/`--env-file` overrides, `~/.task-env` user-level setup script sourced before execution. `ASCEND_RT_VISIBLE_DEVICES` injected by daemon (not passed from user), `TASK_DEVICE` exposes physical card number.

**Operations**: systemd service with PID singleton, maintenance mode, `--clean`, log rotation (1MB cap), colored `--list` output.

## Known Issues

### P0 — Correctness / Security

1. **Orphaned tasks on daemon restart** — `cleanup()` kills running processes but never writes `done/` records. Tasks remain in `running/` after daemon restart: not rescheduled, not cleared, invisible to users. (task-daemon.sh:322-338)

2. **Env snapshot world-readable** — `pending/` has permission 1777. The `.env` file captures the user's full environment (potentially including `*_API_KEY`, `*_SECRET`, `*_TOKEN`). Any user on the machine can read it. (task-submit.sh:320-329)

3. **`parse_task_file` truncates values containing `=`** — Uses `IFS='=' read key value`, so `COMMAND=python train.py --lr=0.01` parses `value` as `python train.py --lr`. The scheduling path uses `cut -d= -f2-` (correct), but `run_task` calls `parse_task_file` (broken). (task-daemon.sh:21-41)

4. ~~**Unknown option silently becomes the task command → CI passes without running anything**~~ — **RESOLVED (2026-07-14)**: the option loop ended in `*) break`, so an unrecognized flag stopped parsing and everything after it — including `--run` — was dropped. `$1` then fell through the main `case` to `submit_task "$1"`, submitting the literal flag string as the command; with `RUN_MODE` unset, `task-submit` printed a task-id and exited **0**.

   Hit in production: `task-submit.sh` was deployed from this repo on 2026-07-13, silently rolling the installed binary back from the 07-07 build (which had `--ignore-whitelist`) to the 06-29 build (which did not) — the 07-03/07-07 changes had only ever been copied into `/usr/local/bin`, never committed back here. The pypto-serving CI action calls `--device auto --device-num 8 --ignore-whitelist ... --run "<pytest>"`, so from 07-13 until the fix it locked 8 cards, ran the string `--ignore-whitelist`, skipped pytest entirely, and reported **green**.

   Fix: unknown `--*` now exits 1 with a "本机 task-submit 过旧，请重新部署" hint; real subcommands (`--wait`/`--list`/…) break out explicitly; `submit_task` refuses any command starting with `--`. **Always `deploy.sh` from this repo — never edit `/usr/local/bin/task-submit` in place.**

11. ~~**Descendants that call `setsid()` escape every kill path**~~ — **RESOLVED (2026-07-14)**: all four sweep sites found victims by session id (`session_pids`) or process group. Both are escapable: a descendant that calls `setsid()` becomes its own session *and* group leader, so its SID is no longer `TASK_PID` and it is invisible to all of them. `process_kills` even carried a comment claiming it "covered re-setsid'd descendants" — it did not.

    Hit in production: pypto-serving's accuracy test starts the inference engine with `subprocess.Popen(start_new_session=True)` (so it can `killpg` the engine's own workers). When the task is killed — `--max-time` watchdog or a cancelled/re-run CI job — pytest dies without running its `finally`, and the engine survives in its own session. Four had accumulated by the time it was noticed, holding **~800 GiB of shared memory** and all 8 NPU cards; the queue was starving with `no free device` while 1.5 TiB of RAM sat unusable. The cards had been released (npu-lock traps its shell), so nothing in `--list` or `running/` hinted at it — only `free -h` did.

    Fix: daemon injects `TASKQUEUE_TASK_ID=<task_id>` into every task's environment. `environ` is inherited across fork/exec and `setsid()` does not rewrite it, so it is the one mark a descendant cannot shed — unlike session and process group, which it can. `marked_pids` greps `/proc/*/environ` for it (single grep over all of `/proc`, not one fork per pid — see the `session_pids` lesson), `task_pids` unions that with `session_pids`, and all four sweep sites (`run_task` post-exit, `process_kills`, `reconcile_running`, `reap_orphans`, plus `cleanup`) now use the union. The session half is still needed: tasks submitted before the upgrade have no marker in their environment.

    The test side is fixed separately — CPython leaves SIGTERM at `SIG_DFL`, so `finally`/`atexit` never run on a plain `kill`; the test now installs a SIGTERM handler that raises, and sets `PR_SET_PDEATHSIG` as a backstop for SIGKILL.

### P1 — User Experience

5. **Blocked command filter false positives** — Substring regex matching: `passwd`, `shutdown`, `reboot` etc. have no word boundaries. `cat /etc/passwd`, `grep shutdown /var/log`, `python train.py --tag reboot-exp` all rejected. (task-submit.sh:257-279)

6. **`--max-time` defaults to 300s** — Most training jobs exceed 5 minutes. Users unaware of the default get silently killed. Documented in GUIDE.md but easily missed. (task-submit.sh:36)

7. **Auto-inject `-d` heuristic unreliable** — Daemon appends `-d $DEVICE` to command tail. Not all programs use `-d` for device; appending may cause CLI parse errors; user unaware of injection. Skip conditions (pipe, `&&`, `--device` present) are incomplete. (task-daemon.sh:203-222)

8. ~~**`--wait` silently truncates the first lines of task output**~~ — **RESOLVED (2026-07-14)**: `wait_task` followed the log with a bare `tail -f`, which starts at the **last 10 lines**. Anything the task printed before `tail` attached was dropped from the user's view — the log file itself was always complete.

   Surfaced as "the devices it says it locked don't match the ones it actually locked": an 8-card task emits 16 npu-lock lines (2 per device), so `tail -f` began at line 7 and the locks for the first 3 cards were invisible. Nothing was wrong with the locking. Fixed by `tail -n +1 -f`.

### P2 — Edge Cases

9. **task-id collision under concurrency** — `task_$(date)_${$}${RANDOM}`: same PID in a loop, `$RANDOM` range 0-32767, theoretical collision within one second. (task-submit.sh:302)

10. ~~**Non-interactive submit silently skips device check**~~ — **RESOLVED**: `--device auto` is now the default. No interactive prompt needed; both interactive and non-interactive paths behave identically.

## Implemented: Transparent Device Allocation

`--device auto` is now the default behavior. Users no longer need to specify `--device auto` explicitly:

```bash
# These are equivalent:
task-submit --run "python train.py"              # auto is implicit
task-submit --device auto --run "python train.py" # still works

# Opt out for non-NPU tasks:
task-submit --no-device --run "make build"
```

The `warn_no_lock` interactive prompt has been removed — no longer needed.

## Proposed Next Step: Privilege Separation via hwhiaiuser Group

### Goal

Enforce NPU access exclusively through `task-submit` by using Linux group-based device permissions.

### Design

Create a `hwhiaiuser` group that owns `/dev/davinci*` devices. Users' normal shells don't have this group, so they can't access NPU directly. The daemon injects the group via `runuser --supp-group hwhiaiuser` when executing tasks.

```
User shell (no hwhiaiuser group) → /dev/davinci* is 0660 → access denied
task-submit → daemon (root) → runuser -u $USER --supp-group hwhiaiuser → access granted
```

Steps:
1. `groupadd -f hwhiaiuser`
2. udev rule: `KERNEL=="davinci[0-9]*", GROUP="hwhiaiuser", MODE="0660"`
3. daemon: `runuser -u "$SUBMIT_USER" --supp-group hwhiaiuser -- ...`

Advantages:
- Task still runs as submitting user (can access user files/dirs)
- Only gains device access via supplementary group
- No complex ACL or two-phase switching needed
