# Mac 与 Windows Server 协作说明

这套环境把开发、审核、发布和运行分开。Mac 负责开发，GitHub 保存代码与检查记录，Windows
负责长期运行，Windows Server Manager 负责把通过门禁的固定版本变成 Docker 服务。

```text
Mac 功能分支与测试
        │ push
        ▼
GitHub Pull Request ── 自动检查、差异与审核
        │ merge
        ▼
GitHub main 的固定 SHA
        │ 每 5 分钟检查一次；只接受所需检查全部成功的 SHA
        ▼
Windows Server Manager ── 隔离构建 ── 连续健康检查 ── 健康版本
        │                                      │失败
        ▼                                      └── 回滚已保存镜像
Docker 中的正式服务与 Windows 正式数据
        │
        ▼
Mac、手机等设备通过 Tailscale 私有访问
```

## 各部分的职责

### Mac

- 在 `codex/<任务>` 功能分支上修改代码并运行离线测试；
- 一个可独立审核和回滚的工作单元对应一个 PR；
- 提交并推送代码，查看 PR 差异和自动检查；
- 不把 Mac 开发数据库当成正式数据。

Mac 保存文件不会直接改变 Windows。只有提交被推送、PR 合并到 `main`，且该 SHA 的指定
检查全部成功，才具备自动发布资格。

### GitHub

- 保存仓库、提交、PR、审核和 CI 结果；
- `main` 表示允许部署的代码序列；
- 不运行正式网站，也不保存生产数据库或 `.env`。

如果仓库套餐无法强制 branch protection，发布管理器仍会在 Windows 侧逐个核对固定 SHA 的
检查结果。这是第二道门禁，不能替代 PR 审核。

### Windows 与 Docker

- `serveradmin` 长期运行 Docker Desktop、Tailscale 和自动发布观察器；
- 正式数据库、上传文件和每个项目的 `.env` 保存在项目目录；
- 锁屏不停止服务；注销该账户会停止依赖登录会话的 Docker Desktop 和观察器；
- 每个运行版本都应在健康接口报告准确提交 SHA。

### Windows Server Manager

- 只管理 `projects.json` 显式登记的项目和 `main`；
- 拒绝 dirty、错分支、分叉和 CI 未通过的检出；
- 跟踪目标 SHA 与最后健康 SHA，同一失败 SHA 可以重试；
- 在隔离目录构建固定 SHA，保存旧镜像，再切换并检查新版本；
- 自动和手动命令共用项目锁；三次失败暂停，回滚失败进入人工恢复状态。

### Tailscale

Tailscale只提供设备间的加密私人网络。它不传代码、不保存 InfoHub 数据、不执行发布。InfoHub
目前的私人入口是 `http://100.69.211.16:8000/`，Windows 本机可用
`http://localhost:8000/`。

## 一次正常 PR 到生产的过程

1. 从正确基线建立功能分支，完成一个明确改动和对应测试。
2. 推送分支并创建 PR；开发分支不会自动进入 Windows。
3. 自动检查通过，审核差异，然后把 PR 合并到 `main`。
4. 发布观察器发现新的 `main` SHA，确认检出、fast-forward 关系和全部指定检查。
5. 在隔离 worktree 构建候选镜像；构建失败不会移动正式检出。
6. 保存当前容器镜像，切换正式检出，运行已批准的迁移 hook（如果配置），再启动候选镜像。
7. 健康接口连续通过且返回目标版本后，状态写为 `healthy`。
8. 如果启动或健康检查失败，管理器恢复原检出和保存的旧镜像；回滚也失败则停止自动操作。

## 如何验收 InfoHub

- 门户：`http://100.69.211.16:8000/`
- 健康页：`http://100.69.211.16:8000/health`
- 机器接口：`http://100.69.211.16:8000/api/health`
- 接口中的 `version` 必须等于 GitHub `main` 目标 SHA（完整值或约定的前 12 位）。

还需检查采集、AI、主题/事件队列和日报是否新鲜。网页能打开只证明 web 存活，不证明信息
流水线健康；InfoHub P05 会进一步拆分 live、ready 和 pipeline 状态。

发布没有发生时，依次检查管理器显示的状态、`state\infohub.json`、
`logs\auto-deploy.log`、Docker Desktop 和 Tailscale。不要先删除数据库或执行 Compose down
的卷删除选项。

## 数据和密钥边界

- 代码进入 GitHub；生产数据库、原始材料、上传文件和 `.env` 不进入 GitHub；
- 管理器不复制数据库到候选 worktree，Docker 重建不得删除项目数据映射；
- 数据迁移由项目自己的受测命令完成，部署管理器只提供受控 hook；
- 正式迁移前必须有一致性备份、恢复验证和副本演练；
- Windows 是正式数据源，Mac 数据只用于开发、测试或经确认的一次迁移。

## 新项目接入

新项目第一次仍需初始化：克隆仓库、准备 Compose 和 `.env`、分配端口、建立带版本的健康
接口、定义 CI 与回滚条件。之后在 `projects.json` 显式登记并用测试 PR 验证一次失败与恢复，
才能开启自动发布。不同项目的数据和密钥继续各自保存。
