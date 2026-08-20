---
name: pto-task-operations
description: Operate, diagnose, install, update, or modify scheduling for the pypto NPU TaskQueue. Use when working with task-submit or pto-task submissions, task-submit.conf device pools, SCHEDULER_MODE, multi-card starvation or reservation, the daemon, deployment layout, configuration, queue state, logs, or device allocation.
---

# TaskQueue operations

Use either `task-submit` (existing user command) or `pto-task` (pypto-tools
entry point). Both links execute the same app program and accept identical
options.

## Locate the installation

Default root: `/home/pypto-tools/pto-task`.

- Run clients: `/usr/local/bin/task-submit`, `/usr/local/bin/pto-task`
- Verify them: `readlink -f /usr/local/bin/task-submit` and `readlink -f /usr/local/bin/pto-task`
- Program files: `<root>/app/`
- Local config: `<root>/config/taskqueue.conf`
- Queue state: `<root>/state/`
- Logs: `<root>/logs/`

Treat `config/` and `state/` as persistent. Never overwrite config or remove
state as part of an upgrade. Do not place or expose credentials in config,
state, logs, commands, or responses.

`TASK_EXECUTION_MODE` defaults to `HwHiAiUser`: tasks run as their submitter
with the `HwHiAiUser` NPU group. Change it to `root` only when all submitters
are trusted; it grants root execution to every queued command and requires a
daemon restart.

## Scheduler policies

Select the root-managed policy with `SCHEDULER_MODE` in
`<root>/config/taskqueue.conf`; change it only while pending and running are
empty, then restart the daemon.

- `backfill` is the default historical policy. Skip blocked tasks and run later
  work whenever its resources are free. It maximizes opportunistic throughput
  but can starve a multi-card request under continuous smaller traffic.
- `pool_aware_reservation` is the pool-aware reservation policy. Configure its
  threshold with `POOL_AWARE_RESERVATION_MIN_DEVICES` (default `2`).

Preserve these `pool_aware_reservation` invariants when diagnosing or changing
the scheduler:

1. Process pending tasks in filename/FIFO order. If an earlier request fits,
   start it before considering later work. Thus five free cards admit `3+2`,
   while `4+2` starts the four-card task and leaves the two-card task pending.
2. When the oldest satisfiable request at or above the threshold cannot get
   enough cards, protect its effective `DEVICE_POOL`. This field is already the
   client-computed intersection of the global auto pool and repository
   `task-submit.conf` policy; do not rediscover repository policy in the daemon.
3. For a younger auto request, subtract the protected pool from its own
   effective pool. Start it only when the remaining free cards satisfy the
   entire request. Allow explicit device requests only when disjoint from the
   protected devices.
4. Allow device-free tasks while keeping one `MAX_CONCURRENT` slot for the
   reserved task. Do not let the eight-card admission cap itself create a
   reservation. Do not let an impossible `auto:N` request become a barrier.
5. Never pre-lock or launch placeholder processes for accumulated cards. The
   reservation is a scheduling decision recomputed from pending/running state;
   real tasks alone acquire `npu_lock.sh`. Do not describe this policy as strict
   FIFO, preemption, or a physical device lock.

The policy module is `app/schedulers/pool_aware_reservation.sh` after install
and `schedulers/pool_aware_reservation.sh` in a checkout. Keep task claiming,
atomic state transitions, process launch, and in-tick resource accounting in
daemon core through `start_pending_task()`.

## Operate safely

Use `task-submit --list` before maintenance. Submit with the existing syntax,
for example `task-submit --device auto --run "python train.py"`. Use
`--status`, `--log`, `--wait`, `--cancel`, and `--kill` with a task id.
Use `--ptoas VERSION` to select `PTOAS_BASE/VERSION`; the client canonicalizes
the path within the configured root, requires an executable `ptoas` or
`bin/ptoas`, injects the matching `PTOAS_ROOT`, and prepends the version root
followed by its `bin` directory to `PATH`. Root-first ordering preserves legacy
wrappers that configure the matching libraries.
`PTOAS_BASE` has a server default in `taskqueue.conf` (`/usr/local/ptoas`); an
explicitly exported submitter value takes precedence for a host with a
separately installed PTOAS tree.
Omitting `--ptoas` preserves the submitter's existing `PTOAS_ROOT` and `PATH`.
A non-empty exported `PTOAS_ROOT` also takes precedence over a conflicting
`--ptoas`, in which case the client leaves both variables unchanged.

Use `pto-task --stats --days 7` for read-only usage reporting. Sampling is
independent of the daemon and disabled by default. Set
`USAGE_SAMPLING_ENABLED=true` in `<root>/config/taskqueue.conf` to enable it;
rerun `sudo bash setup.sh` to install and enable its timer. The task daemon does
not need a restart.

Start the daemon only when explicitly requested. `deploy.sh` is the explicit
one-command install/update-and-activate entry point; `setup.sh` intentionally
does not start or restart the daemon. Starting it requires root; normal
`task-submit`/`pto-task` client commands stay unprivileged.

## Install or update

Run installation and updates as root from an administrator-reviewed checkout.

First install or manual activated update: `sudo bash deploy.sh`.

Install code only, without daemon activation: `sudo bash setup.sh`.

The configuration is initialized automatically when missing. Common settings
can be supplied with `--max-concurrent`, `--max-time-hard-cap`,
`--available-devices`, `--task-execution-mode`, and `--ptoas-base`. Existing
configuration and state remain preserved except for keys explicitly selected
by these options. A safe legacy `/etc/taskqueue.conf` is migrated automatically.

Use `--tools-root DIR` when a non-default root is explicitly required. Confirm
that both public commands resolve to `<root>/app/task-submit` after
installation. `npu_lock.sh` and the daemon remain private app components.

## Automatic updates

The automatic-update timer is enabled by default for root installations with
initialized config. It follows the access-controlled branch configured by
`AUTO_UPDATE_BRANCH` (default `main`), so repository write and merge access must
remain restricted. Use `sudo bash setup.sh --disable-auto-update` to opt out.
The official `pypto-tools/npu-taskqueue` repository is the default;
administrators may override `AUTO_UPDATE_REPOSITORY` in installed config. The
updater retries twice at five-minute intervals after a fetch failure, then waits
for an idle queue, updates only `app/`, and safely restarts an active daemon.
Failed activation remains marked for retry; an intentionally inactive daemon is
not started. The timer runs at 03:17 Asia/Shanghai using the host's synchronized
clock, does not replay missed runs during daytime, and caps idle waiting at two
hours. Keep Git/SSH credentials outside configuration and logs.

## Source mode

For direct checkout execution, use the ignored `runtime/` tree. Configuration
is `runtime/config/taskqueue.conf`; mutable state and logs belong in
`runtime/state` and `runtime/logs`. Do not use `/data` or a user's home as an
implicit runtime location.
