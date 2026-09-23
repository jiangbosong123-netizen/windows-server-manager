# Windows Server Manager

这是 Windows 常驻电脑的独立项目管理器。它与 InfoHub 以及其他业务系统分开，自动识别同级目录中带有 Docker Compose 配置的项目。

Mac 开发、GitHub PR、Windows 正式运行、Tailscale 访问及数据边界的完整约定见
[Mac 与 Windows Server 协作说明](docs/MAC-WINDOWS-WORKFLOW.md)。

建议目录结构：

```text
C:\Users\serveradmin\Server\
├── manager\          本仓库
├── infohub\          InfoHub
└── another-project\  以后的其他系统
```

## 第一次安装

1. 在 GitHub Desktop 中克隆本仓库。
2. Local path 选择 `C:\Users\serveradmin\Server\manager`。
3. 双击 `create-desktop-shortcut.cmd`，桌面会出现 **Windows Server Manager**。

以后双击桌面入口即可管理所有项目。管理器启动时会先尝试更新自己；没有网络时仍会使用现有版本打开。

## 菜单功能

- 查看所有项目和容器状态
- 拉取某个项目的最新代码并重新部署
- 启动、停止或重启某个项目
- 查看最近 100 行日志
- 一次更新并部署全部项目
- 开启或关闭后台自动部署

部署时会把项目当前的 Git 提交号传给 Docker。支持该字段的系统可以在健康页显示正在运行的准确版本。

## 自动部署

在管理器中选择 **8. Enable automatic deployment** 一次即可。它会随 `serveradmin`
登录 Windows 自动启动，每 5 分钟检查同级项目的 GitHub 分支。发现远端有新提交后，
自动执行安全的 fast-forward 拉取并重新构建容器。锁屏不影响运行；需要保持该 Windows
用户登录，Docker Desktop 和 Tailscale 正常运行。

如果项目目录存在未提交的本地代码，或本地与 GitHub 分支分叉，自动部署会跳过该项目，
避免覆盖文件。记录保存在 `manager\logs\auto-deploy.log`。菜单 9 可以关闭自动部署。

项目数据和 `.env` 仍留在各自的项目目录中。停止项目不会删除数据。更新前如果发现业务代码有本地修改，管理器会取消拉取，防止覆盖文件。

## 新增系统

每个新系统只需完成一次准备：把仓库克隆到 `Server` 文件夹，并提供 `compose.yaml`（或兼容的 Compose 文件）及所需的 `.env`。之后管理器会自动发现它，无需修改管理器代码。
