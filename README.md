# NPU TaskQueue

Shared Ascend NPU task queue. The daemon allocates and locks NPU devices, then
runs submitted work as the submitting user. The command-line options and task
workflow of `task-submit` are unchanged. `task-submit` remains supported for
existing users, and `pto-task` is the pypto-tools entry point.

## Install and update

```bash
# First install or manual update: install, activate, and verify everything.
sudo bash deploy.sh

# Install code/configuration links without starting or restarting the daemon.
sudo bash setup.sh
```

`deploy.sh` replaces the former manual `daemon-reload`, config initialization,
service start, status, and `task-submit --list` sequence. It enables the daemon
at boot and keeps `taskqueue.service` as an alias of `pto-task.service`. During
an upgrade it restarts the daemon only when no task is running; otherwise it
updates the files, leaves the running task untouched, and asks you to rerun the
same command after the queue drains.

The initial configuration is created automatically. Common host settings can
be supplied without editing a file:

```bash
sudo bash deploy.sh --max-concurrent 8 --available-devices 0,1,2,3 \
  --ptoas-base /usr/local/ptoas --task-execution-mode HwHiAiUser
```

On a first install from an interactive terminal, the installer prompts for the
NPU card count and maximum concurrency; Enter accepts the detected/recommended
value. Use `--non-interactive` for unattended provisioning. Explicit command
line options always take precedence.

On migration, a safe root-owned `/etc/taskqueue.conf` is detected automatically;
its legacy `BASE_DIR` queue state and `MAX_CONCURRENT` value are retained.

The default installation is:

```text
/home/pypto-tools/pto-task/
├── app/       # deployed programs: task-submit, task-daemon, npu_lock.sh
├── config/    # local taskqueue.conf; never overwritten by an update
├── state/     # pending, running, done, locks, FIFO, usage and daemon state
├── logs/      # task and daemon logs
└── tmp/       # temporary files
```

Deployment creates this complete tree up front. Re-running it preserves local
configuration and queue data while repairing the required sticky permissions
on shared state directories and the modes of existing device lock files. It
also pre-creates one persistent, root-owned lock per configured/detected device;
tasks reuse those files instead of creating them on first use.

Use `--tools-root DIR` to install below another root, for example
`sudo bash deploy.sh --tools-root /srv/pypto-tools`. Deployment must be run as
root from an administrator-reviewed checkout. `/home/pypto-tools` is the
default tools root. Use `setup.sh` instead when only copying files and installing
system integration without starting or restarting the main daemon is desired.

`/usr/local/bin/task-submit` and `/usr/local/bin/pto-task` are symbolic links
to the same `<tools-root>/pto-task/app/task-submit` program. No
`npu-lock` or daemon command alias is installed in `/usr/local/bin`.

The one-command deployment manages the systemd service. For diagnostics, the
private daemon can also be run directly when systemd is intentionally not used:

```bash
TOOLS_ROOT=/home/pypto-tools  # or the value passed to --tools-root
sudo "$TOOLS_ROOT/pto-task/app/task-daemon"
```

## Usage

Both commands are equivalent; existing users can keep using `task-submit`.
Every option and argument pattern is retained.

```bash
task-submit --device auto --run "python train.py"
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"
task-submit --ptoas 0.54 --device auto --run "python train.py"
pto-task --device 3 --run "python train.py --device 3"
task-submit --run "pytest tests/"
task-submit --list
pto-task --status <task-id>
task-submit --log <task-id>
task-submit --wait <task-id>
task-submit --cancel <task-id>
task-submit --kill <task-id>
pto-task --stats --days 7
```

`--max-time` defaults to 300 seconds; `--timeout` defaults to 600 seconds and
only controls client waiting. Project-local `task-submit.conf` device policies
and the existing `TASKQUEUE_DEVICE_*` environment controls continue to work.
`--ptoas VERSION` validates `PTOAS_BASE/VERSION`, sets `PTOAS_ROOT`, and
prepends both the version root and its `bin` directory to the submitted `PATH`.
The root takes precedence so legacy wrapper scripts can configure their
matching libraries. `PTOAS_BASE` is a
server-side default (`/usr/local/ptoas`) that a submitter may explicitly
override in their environment for a host with a separately installed tree.
Without `--ptoas`, the submitter's existing `PTOAS_ROOT` and `PATH` are
preserved unchanged. A non-empty exported `PTOAS_ROOT` also takes precedence
over a conflicting `--ptoas` option, leaving both `PTOAS_ROOT` and `PATH`
unchanged for that task.

## Configuration and security

`config/taskqueue.conf` is Bash-style `KEY=value` configuration. Keep it
administrator-writable and never place passwords, access tokens, or other
credentials in it. The software does not store or print credentials.

| Key | Default | Meaning |
|---|---:|---|
| `MAX_CONCURRENT` | `10` | Maximum simultaneously running jobs |
| `MAX_TIME_HARD_CAP` | `0` | Server maximum task duration; `0` means unlimited |
| `KILL_GRACE` | `5` | Seconds from SIGTERM to SIGKILL |
| `PTOAS_BASE` | `/usr/local/ptoas` | Default root containing installed PTOAS versions; submitter environment takes precedence |
| `TASK_EXECUTION_MODE` | `HwHiAiUser` | Task identity: submitter with NPU group, or `root` |
| `AVAILABLE_DEVICES` | empty | Comma-separated automatic device pool; empty detects devices |

`STATE_DIR` and `LOGS_DIR` are set by the installer to the unified deployment
tree. Do not point them at `/data` or a user home directory.

### Task execution identity

The daemon itself must run as root to schedule work. By default,
`TASK_EXECUTION_MODE="HwHiAiUser"` runs a normal user's task as that submitting
user with the `HwHiAiUser` NPU device group; it does **not** run the task as
root. Set `TASK_EXECUTION_MODE="root"` in the installed configuration only
when every queue submitter is trusted: it makes every queued command root
privileged. Restart the daemon after changing this setting.

## NPU usage statistics

`pto-task --stats [--days N]` (or `task-submit --stats`) reports task count,
card-hours, and sampled NPU utilization. An unprivileged caller sees only their
own records; root sees the per-user aggregate. The report is read-only. Its
sampler is an independent timer; it only reads NPU utilization for cards owned
by running queue tasks and never participates in scheduling.

Sampling and its timer are disabled by default. Enable it in the local
configuration, then rerun `sudo bash setup.sh` to install and enable the timer;
the task daemon does not need a restart:

```bash
# /home/pypto-tools/pto-task/config/taskqueue.conf
USAGE_SAMPLING_ENABLED=true
```

Samples are stored in `state/usage/YYYYMMDD.csv`. The sampler uses a per-run
lock and a timeout for every `npu-smi` call, so a stalled device cannot block
the queue daemon.

## Source checkout mode

The Git checkout remains source only. Running `task-submit.sh`,
`task-daemon.sh`, or `npu_lock.sh` directly resolves configuration at the
ignored `runtime/config/taskqueue.conf`, and uses `runtime/state`,
`runtime/logs`, and `runtime/tmp`. Create that local configuration from the
template when needed:

```bash
mkdir -p runtime/config runtime/state runtime/logs runtime/tmp
cp config/default.conf runtime/config/taskqueue.conf
./task-submit.sh --help
```

`runtime/` is intentionally git-ignored. It keeps local test state out of both
Git and deployed installations.

## Automatic updates

The automatic-update timer is enabled by default for a root installation with
initialized configuration. New installations default to the official
`pypto-tools/npu-taskqueue` repository regardless of which development checkout
runs the installer. Administrators may override `AUTO_UPDATE_REPOSITORY` in the
installed configuration; the updater follows that repository's configured,
access-controlled branch:

```bash
AUTO_UPDATE_REPOSITORY="https://github.com/pypto-tools/npu-taskqueue.git"
AUTO_UPDATE_BRANCH="main"
```

Restrict repository write and merge access because the updater executes the
selected branch's `setup.sh` as root. To opt out of installing the timer:

```bash
sudo bash setup.sh --disable-auto-update
```

The timer starts daily at 03:17 `Asia/Shanghai` (Beijing time), independent of
the server's local timezone. It uses the host's NTP-synchronized system clock
and does not replay a missed nighttime run after a daytime boot. A failed
repository fetch is retried twice at five-minute intervals. After a successful
fetch into `tmp/`, the updater takes an exclusive update reservation and waits
up to two hours for both `state/pending` and `state/running` to be empty,
checking every five minutes. `AUTO_UPDATE_IDLE_WAIT_MAX_SECONDS=7200` also caps
older installed configurations that still contain the former six-hour value.
It updates only `app/`, preserves `config/` and `state/`,
then safely restarts an active daemon before allowing new submissions. A
persistent activation marker is cleared only after restart succeeds, so a
failed restart is retried by the next timer run. An intentionally inactive
daemon is not started automatically. The result is recorded in
`logs/auto-update.log`.

When upgrading from a release whose updater never restarted the daemon, the
first timer run installs this release and leaves the activation marker; the
next timer run activates it. Run `sudo bash deploy.sh` once on existing hosts
after publishing when immediate activation is preferred.
For private repositories, configure host Git/SSH credentials outside this
configuration file; never put tokens or passwords in it.

For a concise Chinese usage guide, see [GUIDE_ZH.md](GUIDE_ZH.md). AI agents
can use [skills/pto-task-operations/SKILL.md](skills/pto-task-operations/SKILL.md).
