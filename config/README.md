# Installed configuration

The installer creates this file only with `--init-config`:

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

`USAGE_SAMPLING_ENABLED` defaults to `false`; set it to `true` and rerun
`setup.sh` to install and enable the independent usage-sampling timer.

For a source checkout, put equivalent local configuration in the ignored
`runtime/config/taskqueue.conf`; source execution uses `runtime/state` and
`runtime/logs` by default.
