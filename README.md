# TaskQueue

面向 Ascend NPU 共享机器的轻量任务队列，解决多人抢卡冲突。

## 设计方案

### 设备分区

本机共 16 张 NPU 卡（物理编号 0-15）：

| 区域 | 物理卡号 | 终端可见 | `--device auto` 可分配 | 说明 |
|---|---|---|---|---|
| 自由卡 | 0-11 | 是 | 否 | 用户终端可直接使用 |
| 保护卡 | 12-15 | 否 | 是 | 只能通过 `task-submit` 使用 |

### 三层机制

| 层 | 负责组件 | 机制 | 作用 |
|---|---|---|---|
| 终端隔离 | `profile.d/taskqueue-npu.sh` | `ASCEND_RT_VISIBLE_DEVICES=0,...,11` | 用户终端看不到保护卡 |
| 设备互斥 | `npu-lock` / flock | 文件锁 | 队列任务之间不抢卡 |
| 设备分配 | daemon / `available_devices` | 白名单 `12,13,14,15` | `--device auto` 只选保护卡 |

### 任务执行流程

1. 用户通过 `task-submit` 提交任务，自动快照环境变量
2. daemon 从白名单分配空闲设备（auto 模式）或使用指定设备
3. `npu-lock` 获取设备文件锁
4. `runuser` 降权，以提交用户身份执行任务
5. 任务结束后释放锁，记录结果

### 环境变量处理

- 提交时快照用户完整环境（排除 `ASCEND_RT_VISIBLE_DEVICES`，由 daemon 控制）
- daemon 注入 `ASCEND_RT_VISIBLE_DEVICES=<分配的物理卡号>`，CANN runtime 重映射为从 0 开始的逻辑编号
- `TASK_DEVICE` 环境变量告知程序分配了哪张物理卡
- 代码里永远用逻辑编号 0, 1, 2...，不要硬写物理卡号

## 组件

| 文件 | 用途 |
|---|---|
| `task-submit.sh` | 用户入口：提交、等待、查看日志、管理任务 |
| `task-daemon.sh` | 常驻调度：扫描队列、分配设备、降权执行、超时管理 |
| `npu_lock.sh` | 设备互斥锁：基于 flock，进程退出自动释放 |
| `taskqueue-npu.sh` | profile.d 脚本：登录时注入 `ASCEND_RT_VISIBLE_DEVICES` |
| `99-npu-taskqueue.rules` | udev 规则（当前已禁用，仅靠环境变量隔离） |
| `taskqueue.service` | systemd 服务 |
| `setup.sh` | 首次安装 |
| `deploy.sh` | 一键部署更新 |

## 目录结构

### 源码目录

```
taskqueue/
├── conf/                          # 配置文件（修改这里）
│   ├── taskqueue.conf             # BASE_DIR, MAX_CONCURRENT
│   ├── available_devices          # --device auto 白名单（当前: 12,13,14,15）
│   └── restricted-users           # 受限用户名单
├── task-daemon.sh
├── task-submit.sh
├── npu_lock.sh
├── taskqueue-npu.sh
├── 99-npu-taskqueue.rules
├── taskqueue.service
├── deploy.sh
├── setup.sh
├── GUIDE.md                       # 用户使用说明
└── README.md                      # 本文档
```

### 运行目录（BASE_DIR）

```
/var/lib/taskqueue/
├── pending/           待调度任务
├── running/           正在执行的任务
├── done/              已完成任务元数据
├── logs/              任务日志
├── locks/             NPU 锁文件
├── kill/              终止请求标记
├── available_devices  设备白名单
├── taskqueue.log      daemon 日志（自动轮转，上限 1MB）
└── task-daemon.pid
```

## 部署

### 部署位置

| 源文件 | 部署位置 |
|---|---|
| `task-daemon.sh` | `/usr/local/sbin/task-daemon` |
| `task-submit.sh` | `/usr/local/bin/task-submit` |
| `npu_lock.sh` | `/usr/local/bin/npu-lock` |
| `taskqueue.service` | `/etc/systemd/system/taskqueue.service` |
| `99-npu-taskqueue.rules` | `/etc/udev/rules.d/` |
| `taskqueue-npu.sh` | `/etc/profile.d/` |
| `conf/taskqueue.conf` | `/etc/taskqueue.conf` |
| `conf/available_devices` | `/var/lib/taskqueue/available_devices` |
| `conf/restricted-users` | `/etc/taskqueue-restricted-users` |

### 首次安装

```bash
sudo bash setup.sh --max-concurrent 15
```

### 更新

修改源码或配置后，一键同步：

```bash
sudo bash deploy.sh
```

### 常用管理

```bash
# daemon 状态
sudo systemctl status taskqueue

# daemon 日志
cat /var/lib/taskqueue/taskqueue.log

# 重启 daemon
sudo systemctl restart taskqueue
```

### 管理受限用户

编辑 `conf/restricted-users`，然后 `sudo bash deploy.sh`。用户需重新登录生效。

### 修改保护卡范围

1. 编辑 `conf/available_devices`（auto 白名单）
2. 编辑 `taskqueue-npu.sh`（终端可见设备）
3. `sudo bash deploy.sh`
4. 用户重新登录生效

### 维护模式

```bash
sudo task-submit --maintenance on "升级驱动"
sudo task-submit --maintenance status
sudo task-submit --maintenance off
```
