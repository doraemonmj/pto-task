# TaskQueue 使用说明

共享 NPU 机器的任务队列，解决多人抢卡冲突。

## 常用命令

### 提交

```bash
# NPU 任务 — 自动分配卡，daemon 自动追加 --device <卡号>
# 若是设置卡号不是--device 参数，可以直接参照下面的占位符，进行自动分配
task-submit --device auto --run "python train.py"

# NPU 任务 — 指定物理卡号（不会自动追加 --device，用户自己处理）
task-submit --device 9 --run "python train.py -d 9"

# 非 NPU 任务 — 不指定 --device，不分配卡
task-submit --run "make build"
task-submit --run "pytest tests/test_foo.py"

# 长训练（默认 300 秒会被 kill，必须加 --max-time 0）
task-submit --device auto --max-time 0 --run "python train.py"

# 一直等到任务结束（--timeout 0 = 客户端不超时）
task-submit --device auto --max-time 0 --timeout 0 --run "python train.py"

# 交互式任务（可在执行过程中通过终端输入 stdin）
task-submit -i --device auto --run "python interactive_script.py"
```

**自定义设备参数**：`--device auto` 时 daemon 默认追加 `--device <卡号>`。如果你的程序用其他参数名，可以用 `{}` 占位符或 `$TASK_DEVICE` 环境变量：

```bash
# {} 占位符 — daemon 替换为实际卡号（双引号即可）
task-submit --device auto --run "python train.py -d {}"
task-submit --device auto --run "python train.py --npu-id {}"

# $TASK_DEVICE 环境变量（必须用单引号，防止提交时展开）
task-submit --device auto --run 'python train.py -d $TASK_DEVICE'

# 在代码中读取: device = os.environ.get("TASK_DEVICE", "0")
```

### 查看

```bash
task-submit --list                  # 列出所有任务
task-submit --status <task-id>      # 单个任务状态
task-submit --log <task-id>         # 查看任务日志（实时）
task-submit --devices               # 查看当前设备白名单
```

### 管理

```bash
task-submit --cancel <task-id>      # 取消排队中的任务
task-submit --kill <task-id>        # 终止运行中的任务（可以 Ctrl+C 中止）
task-submit --clean                 # 清理 1 天前的过期任务（done + pending）
task-submit --clean --days 7        # 清理 7 天前的过期任务
```

## 时间参数

| 参数 | 作用 | 默认 | `0` 的含义 |
|---|---|---|---|
| `--max-time N` | 任务最大运行时间，超过被 kill | `300` 秒 | 不限时 |
| `--timeout N` | 客户端等待时间，超过放弃等待 | `600` 秒 | 一直等 |

`--timeout` 只是断开等待，**任务仍在运行**，可以 `task-submit --wait <task-id>` 重新连上。

## 注意事项

1. **代码里永远用逻辑编号 0, 1, 2...**，不要硬写物理卡号。
2. **长训练记得加 `--max-time 0`**，默认 300 秒会被 kill。
3. **不要手动包 `npu-lock`**，daemon 自动处理设备锁。
4. **不要在任务内部再调 `task-submit`**，会被拒绝（防嵌套死锁）。
5. **不要直接绕过队列跑 NPU 任务**，会和队列里的任务抢卡。
6. **危险命令会被拦截**，如 `rm -rf /`、`mkfs`、`reboot` 等。
7. **交互式任务用 `-i`**，必须搭配 `--run` 且需要终端 stdin。断开后无法重连 stdin（日志仍可 `--wait` 查看）。
