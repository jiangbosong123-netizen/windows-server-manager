# Mac 与 Windows Server 协作说明

这套环境把开发、代码审核和正式运行分开。Mac 负责开发，GitHub 保存和审核代码，
Windows 负责长期运行。以下约定适用于 InfoHub，也适用于以后放到 Windows 上的其他系统。

## 整体关系

```text
Mac 开发与测试
      │ 推送功能分支
      ▼
GitHub Pull Request（修改说明、差异、自动测试）
      │ 检查通过并合并
      ▼
GitHub main（可部署的正式版本）
      │ Windows 每 5 分钟检查
      ▼
Windows Server Manager → Docker 构建并运行
      │
      ▼
Mac、手机等设备通过 Tailscale 私有访问
```

## 各部分的任务

### Mac：开发端

- 阅读和修改代码。
- 在独立功能分支上完成一个明确任务。
- 运行测试、页面检查和数据副本验证。
- 把功能分支推送到 GitHub 并创建 PR。
- 不把 Mac 的开发数据库当作正式数据。

Mac 上保存文件不会自动改变 Windows。代码必须提交并推送到 GitHub；只有合并到
`main` 的版本才会进入正式服务器。

### GitHub：代码中心与审核记录

- 保存仓库、分支、提交历史和 PR。
- 在 PR 中展示改了什么、为什么改、测试是否通过。
- `main` 始终代表准备部署的正式代码。
- 不负责运行网站，也不保存生产数据库和 `.env` 密钥。

### Windows：生产服务器

- 使用 `serveradmin` 账户长期运行 Docker Desktop、Tailscale 和自动部署。
- 每个系统位于 `C:\Users\serveradmin\Server` 下的独立文件夹。
- 保存正式数据库、上传文件、运行日志和每个项目自己的 `.env`。
- 锁屏不会停止服务；注销 `serveradmin` 会停止依赖该登录会话的 Docker Desktop 和自动部署。

### Windows Server Manager：部署端

- 自动发现 `Server` 下带 Docker Compose 配置的项目。
- 每 5 分钟检查项目当前 Git 分支的远端版本。
- 发现 `main` 有新提交后执行安全的 fast-forward 拉取、Docker 构建和重启。
- 项目存在未提交修改或分支发生分叉时跳过部署，避免覆盖文件。
- 自动部署日志位于 `manager\logs\auto-deploy.log`。

### Tailscale：私有连接

- 给自己的设备提供加密的私人网络。
- Mac 通过 Windows 的 Tailscale IP 访问正式网站。
- Tailscale 不同步代码、不保存数据，也不执行部署。

InfoHub 当前正式入口：`http://100.69.211.16:8000/`。
Windows 本机也可以使用 `http://localhost:8000/`。

## PR 工作流程

PR 是 Pull Request，即一组准备合并到正式版本的修改及其审核记录。一个明确的功能、
修复或底层逻辑调整通常对应一个 PR。

1. 从最新 `main` 创建 `codex/<任务名称>` 分支。
2. 完成修改，并运行与改动相关的测试。
3. 提交并推送该分支。
4. 创建 PR，写明问题、修改后的行为和验证结果。
5. 检查代码差异与自动测试。
6. 通过后把 PR 合并到 `main`。
7. Windows 自动部署程序在约 5 分钟内发现新提交并更新项目。
8. 通过项目健康接口或页面核对运行版本和状态。

开发分支和未合并 PR 不会部署到 Windows。小型文案修正也可以走 PR；紧急且风险很低的
修复可以直接提交 `main`，但应保持例外而非常态。

## InfoHub 的验收方式

- 健康页面：`http://100.69.211.16:8000/health`
- 机器接口：`http://100.69.211.16:8000/api/health`
- 接口中的 `version` 应等于 GitHub `main` 最新提交的前 12 位。
- 同时检查信息源异常数、AI 待处理量、主题/事件索引队列和最新日报日期。

如果 GitHub 已合并但版本长时间没有变化，依次检查：

1. Windows 的 `serveradmin` 是否仍处于登录状态。
2. Docker Desktop 和 Tailscale 是否正常运行。
3. Windows Server Manager 是否显示 `Automatic deployment: enabled and running`。
4. `manager\logs\auto-deploy.log` 是否记录拉取或构建错误。

## 数据与密钥边界

- 代码进入 GitHub；正式数据库和 `.env` 不进入 GitHub。
- Docker 重建不会删除映射到项目 `data` 文件夹的数据。
- 每个项目单独保存自己的 `.env`，管理器不集中复制密钥。
- 数据库迁移前先备份；部署工具负责更新程序，不代替数据备份。
- Windows 是正式数据源。Mac 上的数据只用于开发、测试或经过确认的迁移。

## 新项目接入

新项目第一次接入仍需完成初始化：克隆到 `Server` 文件夹、准备 Compose 配置、创建
`.env`、初始化数据并验证端口。完成这一次准备后，管理器会自动发现项目，后续合并到
该项目正式分支的更新可以沿用相同的自动部署流程。
