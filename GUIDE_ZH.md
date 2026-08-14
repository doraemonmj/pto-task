# TaskQueue 使用说明

> 项目结构、安装和完整配置见 [README.md](README.md)。

共享 NPU 机器的任务队列。提交你的命令，系统给你分一张卡并锁住，不用再和别人抢。

## 管理员部署

首次安装和后续手动升级都只需一条命令；它会初始化但不覆盖已有配置，完成
systemd 重载、启动/安全重启、开机自启和状态验证：

```bash
sudo bash deploy.sh
```

在交互式终端首次执行时，部署脚本会询问本机 NPU 卡数量和最大并发数；直接
回车即可接受自动检测/推荐值。无人值守部署可加 `--non-interactive`，也可以用
`--available-devices` 和 `--max-concurrent` 直接指定而不回答问题。

部署时会一次性创建完整运行目录，不依赖首个用户在使用过程中临时创建：

```text
/home/pypto-tools/pto-task/
├── app/
├── config/
├── state/{pending,running,done,locks,kill,fifo,usage}/
├── logs/
└── tmp/
```

重复部署会保留配置和队列数据，同时校正 `pending/`、`locks/`、`kill/`、
`fifo/` 等多用户共享目录及已有设备锁的权限。管理目录和锁文件统一由
`root:root` 持有；共享目录为 `1777`，设备锁为 `0666`，所以所有用户都能使用，
也不需要普通用户修改锁权限。部署会按照最终卡列表预先创建每张卡的持久锁文件，
后续任务只打开并复用同一个锁，不再由首个用户创建。

常用配置可以直接随部署命令传入，不必手改配置文件：

```bash
sudo bash deploy.sh --max-concurrent 8 --available-devices 0,1,2,3 \
  --ptoas-base /usr/local/ptoas --task-execution-mode HwHiAiUser
```

升级时若仍有任务运行，脚本不会杀任务，只更新程序文件并提示任务结束后重新执行。
旧版 `/etc/taskqueue.conf` 中安全的 `BASE_DIR` 和 `MAX_CONCURRENT` 会自动迁移，
`taskqueue.service` 也保留为 `pto-task.service` 的兼容名称。

自动更新会先阻止新任务提交，等待 pending 和 running 都为空后再安装并安全重启
正在运行的 daemon。重启失败会保留待激活标记，在下次定时更新时继续重试；原本
处于停止状态的 daemon 不会被自动启动。安装 revision 只在 systemd service/timer
链接完成且 timer 已启用、运行后才写入 `.pto-task-release`；失败时保留旧 revision
供下次重试，完整安装输出和退出码写入 `logs/auto-update.log`。管理员和普通用户可用
`task-submit --version` 查看当前安装 revision。

定时器固定在北京时间（`Asia/Shanghai`）每天凌晨 03:17，使用服务器经 NTP
同步后的系统时钟，不受服务器本地时区影响。若服务器夜间关机，白天启动时不会
补跑错过的更新。等待队列空闲的单次上限为 2 小时，每 5 分钟检查一次；新版的
2 小时硬上限也会限制仍保存旧版 6 小时配置的服务器。

如需关闭自动更新，部署时使用 `sudo bash deploy.sh --disable-auto-update`；后续
手动升级也继续携带该选项，因为普通部署默认会重新安装并验证自动更新 timer。

如果某台共享开发服务器需要限制 8 卡用例并发，可仅在该机的
`/home/pypto-tools/pto-task/config/taskqueue.conf` 中设置：

```bash
MAX_CONCURRENT_8_CARD_TASKS=1
```

默认值为 `0`（关闭），其他服务器自动更新代码后不会自动开启。开启后，
已有一个 8 卡用例运行时，后续 8 卡用例保持 pending；daemon 会跳过它
继续调度后面的小卡任务。

从旧版（自动更新从不重启 daemon）迁移时，第一次定时运行会安装新版并留下待激活
标记，下一次定时运行完成激活；如果希望发布后立即生效，在已有服务器上手动执行
一次 `sudo bash deploy.sh` 即可。

## 提交

```bash
# NPU 任务 —— 自动分配空闲卡，并自动在命令末尾追加 "--device <卡号>"
task-submit --device auto --run "python train.py"

# NPU 任务 —— 自己指定卡号（不会自动追加，卡号由你自己传给程序）
task-submit --device 9 --run "python train.py -d 9"

# 多卡
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"

# 指定 PTOAS 版本；自动设置 PTOAS_ROOT，并依次把版本根目录和 bin 放到 PATH 前面
task-submit --ptoas 0.54 --device auto --run "python train.py"

# 非 NPU 任务 —— 不写 --device 就不分配卡
task-submit --run "make build"
task-submit --run "pytest tests/test_foo.py"

# 长训练（默认 300 秒会被 kill，必须加 --max-time 0）
task-submit --device auto --max-time 0 --run "python train.py"

# 一直等到任务结束（--timeout 0 = 客户端不超时）
task-submit --device auto --max-time 0 --timeout 0 --run "python train.py"

# 交互式任务（执行过程中可以从终端输入）
task-submit -i --device auto --run "python interactive_script.py"
```

未指定 `--ptoas` 时保留提交者已有的 `PTOAS_ROOT` 和 `PATH`，不自动切换版本。
指定版本必须在服务器配置项 `PTOAS_BASE` 下包含可执行的 `ptoas` 或 `bin/ptoas`；
版本根目录优先，以便旧版包装脚本自动加载对应的 `lib/`。当前默认
根目录为 `/usr/local/ptoas`。管理员可在 `taskqueue.conf` 中为服务器单独配置；
提交用户显式导出的 `PTOAS_BASE` 优先级更高。
如果已经导出了非空的 `PTOAS_ROOT`，它的优先级也高于冲突的 `--ptoas` 参数，
此时任务会保留原有的 `PTOAS_ROOT` 和 `PATH`。

### 怎么把卡号告诉你的程序

`--device auto` 时 daemon 默认在命令末尾追加 `--device <卡号>`。如果你的程序用
别的参数名，改用 `{}` 占位符或 `TASK_DEVICE` 环境变量：

```bash
# {} 占位符 —— daemon 替换为实际卡号（双引号即可）
task-submit --device auto --run "python train.py -d {}"
task-submit --device auto --run "python train.py --npu-id {}"

# $TASK_DEVICE 环境变量（必须用单引号，否则提交时就被你的 shell 展开了）
task-submit --device auto --run 'python train.py -d $TASK_DEVICE'

# 代码里读取: device = os.environ.get("TASK_DEVICE", "0")
```

拿到的是**物理卡号**，原样用即可。

## 查看

```bash
task-submit --list                  # 所有任务
task-submit --status <task-id>      # 单个任务状态
task-submit --log <task-id>         # 任务日志
task-submit --wait <task-id>        # 重新连上并跟到结束
task-submit --devices               # 当前设备白名单
task-submit --find "<子串>"          # 按完整命令匹配，只输出 task-id（给脚本用）
```

脚本里要定位任务请用 `--find`，不要解析 `--list`：`--list` 的命令列会在 77 个
字符处截断。

## 管理

```bash
task-submit --cancel <task-id>      # 取消排队中的任务
task-submit --kill <task-id>        # 终止运行中的任务（Ctrl+C 同样可以）
task-submit --clean                 # 清理 1 天前完成的任务
task-submit --clean --days 7        # 清理 7 天前完成的任务
```

## 时间参数

| 参数 | 作用 | 默认 | `0` 的含义 |
|---|---|---|---|
| `--max-time N` | 服务端的任务最大运行时间，超时被 kill | `300` 秒 | 不限时 |
| `--timeout N` | 客户端等待时间 | `600` 秒 | 一直等 |

`--timeout` 只是断开等待，**任务仍在运行**，可以用
`task-submit --wait <task-id>` 重新连上。

## 注意事项

1. **用系统给你的卡号。** 它是物理卡号，通过自动追加的 `--device`、`{}` 占位符
   或 `$TASK_DEVICE` 传给你。系统不会把卡重映射成逻辑 0，所以写死卡号意味着
   锁着一张卡、算在另一张卡上。
2. **长训练记得加 `--max-time 0`**，默认 300 秒会被 kill。
3. **不要自己包 `npu-lock`**，daemon 会锁卡；命令里手写 `npu-lock` 会被拒绝。
4. **不要在任务内部再调 `task-submit`**，嵌套提交会被拒绝（防队列死锁）。
5. **不要绕过队列**直接跑 NPU 任务，会和队列里的任务抢卡。
6. **危险命令在提交时被拦截**（`rm -rf /`、`mkfs`、`reboot` 等）。匹配是子串
   匹配，所以正常命令里带上这些词也会被拒，改个写法即可。
7. **交互式任务用 `-i`**，必须搭配 `--run` 且需要真实终端。只支持按行输入，
   断开后无法重连 stdin（日志仍可用 `--wait` 继续看）。
