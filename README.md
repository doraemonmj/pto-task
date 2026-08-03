# NPU TaskQueue

Shared Ascend NPU task queue. The daemon allocates and locks NPU devices, then
runs submitted work as the submitting user. The command-line options and task
workflow of `task-submit` are unchanged. `task-submit` remains supported for
existing users, and `pto-task` is the pypto-tools entry point.

## Install and update

```bash
# First install: creates the application layout and an initial local config.
sudo bash setup.sh --init-config

# Update code only. Config and all queue state are preserved.
sudo bash setup.sh
```

The default installation is:

```text
/home/pypto-tools/pto-task/
├── app/       # deployed programs: task-submit, task-daemon, npu_lock.sh
├── config/    # local taskqueue.conf; never overwritten by an update
├── state/     # pending, running, done, locks, FIFO and daemon state
├── logs/      # task and daemon logs
└── tmp/       # temporary files
```

Use `--tools-root DIR` to install below another root, for example
`sudo bash setup.sh --tools-root /srv/pypto-tools --init-config`. Installation
must be run as root from an administrator-reviewed checkout. It copies files
and creates missing directories, but does not start, restart, or signal the
task daemon. `/home/pypto-tools` is the default tools root.

`/usr/local/bin/task-submit` and `/usr/local/bin/pto-task` are symbolic links
to the same `<tools-root>/pto-task/app/task-submit` program. No
`npu-lock` or daemon command alias is installed in `/usr/local/bin`.

Start the private daemon separately when the host is ready:

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

## Configuration and security

`config/taskqueue.conf` is Bash-style `KEY=value` configuration. Keep it
administrator-writable and never place passwords, access tokens, or other
credentials in it. The software does not store or print credentials.

| Key | Default | Meaning |
|---|---:|---|
| `MAX_CONCURRENT` | `10` | Maximum simultaneously running jobs |
| `MAX_TIME_HARD_CAP` | `0` | Server maximum task duration; `0` means unlimited |
| `KILL_GRACE` | `5` | Seconds from SIGTERM to SIGKILL |
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
initialized configuration. The installer records the source repository's Git
`origin` after removing embedded HTTP credentials. It follows the configured,
access-controlled branch:

```bash
AUTO_UPDATE_REPOSITORY="git@github.com:pypto-tools/npu-taskqueue.git"
AUTO_UPDATE_BRANCH="main"
```

Restrict repository write and merge access because the updater executes the
selected branch's `setup.sh` as root. To opt out of installing the timer:

```bash
sudo bash setup.sh --disable-auto-update
```

The timer starts at 03:17 daily. It fetches first into `tmp/`, then takes an
exclusive update reservation and waits up to
six hours for both `state/pending` and `state/running` to be empty, checking
every five minutes. It updates only `app/`, preserves `config/` and `state/`,
and never restarts the daemon; the update is recorded in `logs/auto-update.log`.
For private repositories, configure host Git/SSH credentials outside this
configuration file; never put tokens or passwords in it.

For a concise Chinese usage guide, see [GUIDE_ZH.md](GUIDE_ZH.md). AI agents
can use [skills/pto-task-operations/SKILL.md](skills/pto-task-operations/SKILL.md).
