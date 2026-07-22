# 交互模式（Interactive Mode）

## 用法

```bash
task-submit -i --run "python interactive_script.py"
```

`-i` 必须搭配 `--run`，且需要真实终端（不能从管道调用）。

## 原理

普通模式下任务的 stdin 接的是 `/dev/null`，没法接收输入。
交互模式通过一根 **命名管道（named FIFO）** 搭了一条 stdin 通道：

1. daemon 在 `$FIFO_DIR/` 下为这个任务 `mkfifo` 创建一根管道
2. 任务进程启动时把这根管道接到自己的 stdin（`< $fifo_path`）
3. 客户端发现管道出现后，进入转发循环：每秒尝试 `read` 一行终端
   输入，读到就 `printf '%s\n' > $fifo_path` 写进管道
4. 管道另一头的任务进程正常 `read`/`input()` 就能收到这行内容

本质上就是用文件系统里的一根管道，把两个不相关的进程（你的终端
shell 和 daemon fork 出来的任务子进程）的 stdin 串起来：

```
你的终端                                daemon
────────                            ──────────────
键盘输入                            创建 FIFO 管道
   │                                     │
   │  每秒读一行                          │  keeper 持有写端防 EOF
   │                                     │
   └──写入 FIFO ───────────────────> FIFO ──> 任务进程 stdin
                                         │
                              任务 stdout/stderr ──> 日志文件
                                                       │
你的终端: tail -f 日志  <──────────────────────────────┘
```

简单说就是两条通道：
- **输入**：键盘 → FIFO → 任务 stdin（按行转发）
- **输出**：任务 stdout → 日志文件 → tail -f → 你的终端

## keeper 是什么

daemon 会启动一个 `sleep infinity > fifo` 进程，唯一作用是**始终
持有 FIFO 的写端**。没有它的话，客户端两次输入之间 FIFO 写端无人
持有，任务进程会收到 EOF 直接退出。

## Ctrl+C

- 任务排队中：直接取消
- 任务运行中：发送终止请求，等待 daemon 杀掉进程

## 限制

- **按行转发**：敲回车才发送，不支持逐字符交互（方向键、Tab 补全
  等不行）
- **单客户端**：断开后无法重连输入（但任务不会挂，keeper 兜底）
