# 部署状态机与恢复规范

## 状态文件

每个登记项目在 `state/<id>.json` 有一份原子写入的本地状态：

| 字段 | 含义 |
|---|---|
| `desiredSha` | 当前远端 `main` 指向、准备发布的固定提交 |
| `deployedSha` | 最近一次完成部署流程的提交 |
| `healthySha` | 最近一次连续通过健康检查的提交 |
| `previousHealthySha` | 上一个健康提交，用于审计和人工恢复 |
| `failureCount` | 当前目标 SHA 连续失败次数 |
| `nextRetryAt` | UTC 退避截止时间 |
| `lastAttemptAt` / `lastHealthyAt` | UTC 尝试与成功时间 |
| `lastError` | 已截断并写入状态的失败原因 |

状态文件不进入 Git。删除它不会删除容器或业务数据，但会丢失发布判断依据，因此不应把删除
状态当作故障修复。

## 状态含义

- `never_deployed`：管理器尚未验收过该项目；第一次会对当前 `main` 做完整接管发布。
- `waiting_ci` / `blocked_ci`：指定检查尚未完成或失败，不构建。
- `blocked_dirty_worktree`、`blocked_wrong_branch`、`blocked_non_fast_forward`：本地检出不安全。
- `deploying`：已经记录尝试，可能正在隔离构建或切换。
- `failed` / `backoff`：发布失败，仍会对同一 SHA 重试。
- `paused`：同一 SHA 连续三次失败；人工检查后可从菜单强制再试。
- `healthy`：目标 SHA 与最近健康 SHA 相同。
- `recovery_required`：自动回滚也失败；自动和普通强制重试都停止，先按运行手册人工恢复。

出现新的远端 SHA 会重置旧 SHA 的失败次数，但不会绕过 dirty、分叉或 CI 门禁。

## 安全发布顺序

1. 确认本地 `main` 干净，fetch 后本地是远端目标的祖先。
2. 查询目标 SHA 的所有指定 GitHub check-runs；重跑时以最新开始的那次为准。
3. 为目标 SHA 建立隔离 Git worktree，复制白名单运行时文件。
4. 解析 Compose 服务，为候选 SHA 生成不可变镜像标签。
5. 按旧 Compose 的实际服务列表保存当前镜像，并标成独立的 `rollback-<目标SHA>`；即使首次
   接管时新旧 SHA 相同也不会覆盖，新版新增的服务也不会污染旧版回滚配置。
6. 在隔离 worktree 构建候选；失败时保持正式检出和容器不变。
7. fast-forward 式把正式检出重置到已验证目标 SHA。
8. 仅在显式配置且声明 `rollbackSafe: true` 时执行项目迁移 hook。
9. 以候选镜像启动服务，健康接口必须连续成功并报告目标 SHA。
10. 成功后原子记录健康状态；失败则重置检出并用保留的旧镜像启动。

项目级 OS mutex 覆盖以上整个过程，也用于菜单中的启动、停止、重启和日志操作。

## 迁移 hook 合同

P01只提供接口，InfoHub 当前配置仍是 `null`。启用前，项目必须证明：

- 命令幂等，失败时自身事务完整回滚；
- 运行前创建并验证一致性备份；
- 迁移是兼容扩展，旧健康镜像可以读取迁移后的数据库；
- 命令不把密钥或整份数据库输出到日志；
- 已在生产数据导出副本上重复运行并完成恢复演练。

不满足旧版本兼容性的迁移不能把 `rollbackSafe` 设置为 true，应先扩展状态机支持停写、双阶段
切换或专用降级流程。

## 日志与故障处理

事件日志位于 `logs/auto-deploy.log`，超过 2 MB 轮换一次。换行被压平，常见 token、密码、
Authorization 和 API key 值会隐藏，单条消息最多 2,000 字符。

`paused` 时先看最后错误、Docker 日志和 GitHub 检查，再用菜单手动重试同一 SHA。出现
`recovery_required` 时不要继续发布或删除数据：记录当前容器和状态文件，检查保存的 rollback
override 与镜像，恢复最后健康 SHA，再验证健康接口。正式的主机重启与隔离恢复演练属于
InfoHub P23，在完成之前不宣称无人值守灾难恢复已经验收。

## 当前限制

- Docker Desktop 和观察器依赖 `serveradmin` 登录会话；断电后无人登录的自动恢复尚未验收。
- GitHub API 不可用时按 pending 处理，不部署；公共 API 限额可能延迟发布。
- 回滚镜像会占用磁盘；本版不自动 prune，以免清除最后健康镜像。磁盘保留策略需单独 PR。
- 本 PR 的测试使用模拟发布 hook，不接触正式 Docker 和数据库；Windows 真实故障注入仍要在合并
  后按运行手册执行。
