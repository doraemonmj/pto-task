---
name: pto-task-operations
description: Operate, diagnose, install, or update the pypto NPU TaskQueue. Use when working with task-submit or pto-task submissions, its daemon, deployment layout, configuration, queue state, logs, or device allocation.
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

Start the daemon only when explicitly requested, using `<root>/app/task-daemon`.
Starting it requires root; normal `task-submit`/`pto-task` client commands stay
unprivileged. The installer intentionally does not start or restart the daemon.

## Install or update

Run installation and updates as root from an administrator-reviewed checkout.

First install: `sudo bash setup.sh --init-config`.

Update code only: `sudo bash setup.sh`.

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
for an idle queue, updates only `app/`, and never restarts the daemon. Keep
Git/SSH credentials outside configuration and logs.

## Source mode

For direct checkout execution, use the ignored `runtime/` tree. Configuration
is `runtime/config/taskqueue.conf`; mutable state and logs belong in
`runtime/state` and `runtime/logs`. Do not use `/data` or a user's home as an
implicit runtime location.
