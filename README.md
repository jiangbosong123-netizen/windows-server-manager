# Windows Server Manager

这是 Windows 常驻电脑的独立项目管理器。它与 InfoHub 以及其他业务系统分开，自动识别同级目录中带有 Docker Compose 配置的项目。

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

部署时会把项目当前的 Git 提交号传给 Docker。支持该字段的系统可以在健康页显示正在运行的准确版本。

项目数据和 `.env` 仍留在各自的项目目录中。停止项目不会删除数据。更新前如果发现业务代码有本地修改，管理器会取消拉取，防止覆盖文件。

## 新增系统

每个新系统只需完成一次准备：把仓库克隆到 `Server` 文件夹，并提供 `compose.yaml`（或兼容的 Compose 文件）及所需的 `.env`。之后管理器会自动发现它，无需修改管理器代码。
