---
name: pto-task-operations
description: Run only the on-device stage through the pypto TaskQueue; keep compilation and other CPU preparation outside task-submit. Also read queue and usage telemetry. Use when working with task-submit or pto-task submissions, device allocation, queue status/logs, device-usage sampling, --stats, or --usage-ranking. For install, deployment, scheduler policy or host configuration, see the repository README.
---

# TaskQueue operations

## First rule: CPU preparation outside, only the device run inside

**Compile, install dependencies and generate inputs before calling
`task-submit`. Submit only the innermost on-device stage, then aggregate results
and generate reports after the device task finishes. Never submit the whole
build-and-test workflow.** `task-submit` and `pto-task` are aliases and follow
the same rule.

“Innermost” describes the execution boundary: the submitted command must run
the prepared device workload. Inspect the scripts and subprocesses it invokes;
a single Python or shell entry point that also builds or prepares data still
violates this boundary. Having only one queue submission does not make a mixed
CPU/device workflow compliant. The scheduler holds every requested card for the
whole process, including time spent on CPU work.

- Correct: CPU build and preparation → `task-submit` (device run) → CPU reports.
- Forbidden: `task-submit` (CPU build → preparation → device run → reports).

When reviewing compliance, explicitly check whether compilation or other CPU
stages ran inside the submitted process. If JIT compilation cannot be separated,
report that limitation; do not claim it moved outside the allocation.

Device queries, architecture prechecks and ACL initialization are part of the
device stage and must stay inside the same allocated job as the test.

## Before submitting

Split preparation from the run. Build and prepare first, check the exit status,
then submit the smallest allocation that fits:

```bash
cmake --build build -j 8 &&
  task-submit --device auto --run './build/onboard_test --device "$TASK_DEVICE"'
```

- Keep each device task short. The scheduler holds every requested card for the
  whole submitted process; releasing a runtime handle inside it returns nothing.
  Related cases that share one configuration may run in a single submission, each
  keeping its own pass/fail result. Do not put builds, installs, input generation,
  aggregation, long sweeps or unrelated work in a device task.
- Architecture prechecks, `npu-smi`, DCMI and ACL initialization access devices
  and belong inside the same allocated job as the test, even though they look like
  preparation. Never run a hardware query from the submitter shell or a
  `--no-device` task.
- Use the card the queue gave you through the appended `--device`, the `{}`
  placeholder or `$TASK_DEVICE`. Card IDs are physical IDs; do not remap or
  hardcode them. Request cards with `--device auto` and `--device-num N`.
- A grouped `DEVICE_WHITELIST` (`0,1,2,3;4,5,6,7`) defines scheduling pools; auto
  multi-card requests use one pool only. `--ignore-whitelist` requires a
  comma-only whitelist. `--ignore-group-affinity` only when the workload really
  communicates across HCCS planes — pypto/simpler cross-group hangs and wedges
  the cards.

## While the task runs

- Do not submit from inside an already queued task or wrap an AI agent or runner
  that submits tasks in an outer submission. Only the innermost device runner
  owns submission; this also applies to `pto-task` and `--no-device`.
- CPU-only work stays outside `task-submit` by default. Use `--no-device` only
  when CPU work itself needs queueing; never put it in a device allocation.
- Use `--status`, `--log`, `--wait`, `--cancel` and `--kill` with the task id.
- Long runs need `--max-time 0`; the default 300 s kills the task.
- Interactive runs use `-i` with `--run` and a real terminal (line-based stdin
  only; stdin cannot be reconnected after a disconnect).
- Do not wrap `npu-lock` yourself; the daemon locks the cards.
- Dangerous commands (`rm -rf /`, `mkfs`, `reboot`, ...) are rejected by
  substring matching; rewrite the command instead of fighting the filter.
- `task-submit --help` lists every option, including `--ptoas`, `--env` and the
  device-pool flags.

## Reading usage telemetry

With sampling enabled, a device job samples its own cards every 15 seconds after
acquiring the device locks; CPU jobs never sample. `--stats [--days N]`,
`--device-usage TASK_ID` and `--usage-ranking` share one vocabulary:

- **Valid sample** — one successful per-card query. The count grows with cards ×
  duration; failed queries count only as attempts.
- **Actual card-use hours** — card-seconds with observed compute / 3600; compile,
  initialization and idle time are excluded.
- **Card-active-time ratio** — card-seconds with observed compute / recorded
  card-seconds, capped at 100%. Sampling gaps count for neither; no valid sample
  means unknown, never zero.
- **Suspected idle** — 60 continuous seconds of valid zero-compute samples from
  the moment all cards are held. A nonzero sample closes it; timeouts and gaps
  are unknown, never idle. Assessed per card.
- **Sampling completeness** — continuous valid sampled card-seconds / recorded
  card-seconds. It measures how trustworthy the sampling data is, not how busy
  the cards are: task head/tail and sampling gaps stay in the denominator while
  leaving the numerator, so it is usually below 100% and the active-time ratio
  can never exceed it.

`--stats` is own-user unless run as root; `--usage-ranking` aggregates all users
(default two days, lowest ratio first) and excludes tasks held 30 seconds or less
overall. Both are advisory: submitters can edit
their own record, and telemetry never cancels a task or releases cards. `--list`
annotates sampled running tasks with accumulated idle history and current state.
A3 and A5 use different mapping/query formats: never infer a mapping by dividing
card IDs by two or treating a logic ID as a physical ID.

## Administration

Install, update, scheduler policy, device pools and automatic updates are covered
in the repository README and `GUIDE_ZH.md`. Deploy as root only when the queue is
idle; `deploy.sh` updates files but skips the daemon restart while a task runs, and
must be rerun after the queue drains. Start the daemon, enable usage collectors,
or change scheduler configuration only on an explicit request.

Granting priority queueing is also an administrator action: `sudo task-submit
--priority grant <user> --days N` (at most 14 days, never extendable),
`--priority revoke <user>` and `--priority list`. It only changes waiting order;
it never preempts a running task or bypasses concurrency, device-pool or
reservation limits, and ordinary tasks join the priority bucket once they have
waited `PRIORITY_AGING_SECONDS`.


Only administrators set per-user card limits: `sudo task-submit --user-limit
set <user> <N>` or `remove <user>`; anyone may run `--user-limit list`.
The cap covers all of that user's running allocations combined. Oversized
requests are refused; requests within the cap wait for the user's quota to free
up. A zero cap permits CPU-only jobs but no device jobs. Do not set a user's
limit without the requested username and card count.
