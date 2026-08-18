# Installed configuration

The installer creates this file automatically when it is missing:

```text
/home/pypto-tools/pto-task/config/taskqueue.conf
```

It is local machine configuration and is never copied or overwritten during an
update. Set `MAX_CONCURRENT`, `MAX_TIME_HARD_CAP`, `KILL_GRACE`, and
`AVAILABLE_DEVICES` there. `TASK_EXECUTION_MODE` defaults to `HwHiAiUser`: a
task keeps its submitting user's UID and gains the `HwHiAiUser` NPU group. Set
it to `root` only for a fully trusted queue; every submitted command will then
run with root privileges. `STATE_DIR` and `LOGS_DIR` normally remain the paths
written by the installer.

`SCHEDULER_MODE` selects a root-managed scheduler module. `backfill` is the
default and preserves the historical behavior: a blocked task is skipped so
later runnable tasks may use otherwise idle resources. Unknown modes are
rejected instead of silently falling back to another policy. The mode is read
when the daemon starts; change it only while the queue is idle, then restart
the service.

`MAX_CONCURRENT_8_CARD_TASKS` defaults to `0`, which preserves the historical
scheduler behavior. Set it to `1` only in a host's local configuration when
that server should keep additional eight-card jobs pending without blocking
later smaller jobs. Automatic updates preserve the local configuration and do
not enable this policy elsewhere.

`USAGE_SAMPLING_ENABLED` defaults to `false`; set it to `true` and rerun
`setup.sh` to install and enable the independent usage-sampling timer.

For a source checkout, put equivalent local configuration in the ignored
`runtime/config/taskqueue.conf`; source execution uses `runtime/state` and
`runtime/logs` by default.
