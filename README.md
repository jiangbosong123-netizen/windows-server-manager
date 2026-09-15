# Windows Server Manager

这是 Windows 常驻电脑上的独立发布管理器。它不保存 InfoHub 业务数据，也不参与信息处理；
它只把 GitHub `main` 上通过指定检查的固定提交，安全地发布成 Docker 服务。

完整协作关系见 [Mac 与 Windows Server 协作说明](docs/MAC-WINDOWS-WORKFLOW.md)，发布状态、
失败恢复和接入约束见 [部署状态机](docs/DEPLOYMENT-STATE-MACHINE.md)。

```text
C:\Users\serveradmin\Server\
├── manager\          本仓库
├── infohub\          InfoHub 的部署检出与正式数据目录
└── another-project\  以后显式登记的其他系统
```

## 第一次安装

1. 在 GitHub Desktop 中把本仓库克隆到 `C:\Users\serveradmin\Server\manager`。
2. 双击 `create-desktop-shortcut.cmd`，桌面会出现 **Windows Server Manager**。
3. 检查 `projects.json` 中的项目路径、仓库、检查名称和健康接口。
4. 打开管理器，先执行一次 **Check and deploy a project**；确认状态为 `healthy` 后再开启自动部署。

管理器启动时会尝试用 fast-forward 更新自己。离线时仍使用已有版本打开。

## 发布规则

项目必须显式登记在 `projects.json`；管理器不会扫描并运行任意相邻目录。每个登记项目都必须：

- 只部署 `main`，且本地检出没有修改或分叉；
- 指定 GitHub 仓库和全部必需检查；
- 指定 Compose 项目、运行时文件和带版本字段的健康接口；
- 使用不可变提交 SHA 构建镜像，并在连续健康检查通过后才记录为健康版本。

每个项目的 `desiredSha`、`healthySha`、失败次数和下次重试时间保存在
`manager\state\<project>.json`。同一提交构建失败后会按 5、15、30 分钟退避重试；连续三次
失败会暂停，等待人工检查。自动和手动操作共用项目级互斥锁，不能重叠。

部署先在隔离的 Git worktree 构建候选镜像，并给当前运行镜像保存独立回滚标签。只有候选
构建成功后才移动正式检出。容器启动后必须连续通过配置的健康检查；失败会恢复旧检出和
旧镜像。自动回滚失败时进入 `recovery_required`，后续自动操作停止。

## 菜单功能

- 查看登记项目、容器与发布状态；
- 检查并发布一个或全部项目；
- 按已记录的健康镜像启动、停止或重启项目；
- 查看日志；
- 开启或关闭后台自动部署。

自动部署每 5 分钟检查一次。它只发起很小的 Git/GitHub 查询；没有新提交时不会构建镜像、
调用模型或抓取新闻。锁屏不影响运行，但当前 Docker Desktop 方案要求 `serveradmin` 保持登录。

## 数据和迁移

正式数据库、上传文件及 `.env` 留在各项目自己的目录，不进入本仓库或 GitHub。候选构建只
复制项目配置中列出的运行时文件，不复制数据库。

`migrationHook` 默认是 `null`。只有业务仓库已经提供备份、校验、幂等迁移，并确认旧镜像仍
可读取迁移后结构时，才能配置 hook 且显式设置 `rollbackSafe: true`。接口存在不代表生产迁移
已经获准；InfoHub 的真实迁移仍须按它自己的数据库规范演练。

## 新增系统

新系统不会被自动发现。先把仓库克隆到 `Server` 下，准备 Compose、`.env`、健康接口和 CI，
再给 `projects.json` 增加一条显式配置并通过 PR 审核。这样可防止下载目录或实验项目被意外
当作生产服务运行。

## 本地验证

Windows PowerShell 5.1：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

测试不连接真实 Docker、GitHub 或正式数据。
