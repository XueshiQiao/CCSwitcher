# PLAN -- 当前账号本地额度与合并展示

## Status: done
## Task: 009
## Related: 007, 008
## Baseline Commit: 1c48c06

## Goal
- 手动刷新及自动同步只更新当前账号，其他账号保留历史数据。
- 合并账号管理与额度展示，保留回收账号、编辑、登录和完整邮箱复制。
- 展示可信本地数据中可获取的 Fable 额度；缺失时明确未获取。

## Non-goals
- 不请求官方额度接口、不通过 CLI 发起额外额度请求，不自动切换账号。
- 本轮不扩大到独立的登录/凭据写入修复，不提交或推送。

## Acceptance Criteria
- 非当前账号在界面及 AppState 入口均不能刷新；同步不会切换账号、调用 CLI 或读取 token。
- 读取时验证当前本地身份，防止旧活动标记导致跨账号读取。
- 单一账号卡片包含额度和管理操作；历史记录保留真实时间。
- Fable 只映射经代码或本地数据确认的字段，不推算或伪造。
- 离线边界检查、macOS 构建、界面预览通过，备份后替换本地 app。

## Constraints
- 无真实额度请求、真实登录或凭据写入测试。
- 复用现有组件和存储，保留用户设置及其他本地修改。

## Decisions
- 独立探索确认官方 CLI 2.1.289 的 cachedUsageUtilization 包含 Fable scoped weekly limit；直接读取该官方缓存，不再使用 statusline bridge 作为数据来源。
- 一次读取配置内 oauthAccount 与 cachedUsageUtilization，UUID 必须一致，匹配目标邮箱；缓存属于其他账号时报错保留历史。
- Fable 使用 weekly_scoped / scope.model.display_name；保留真实 fetchedAtMs 时间，未知项不显示为零。
- 旧 bridge 来源首次迁移到官方来源可采用更早的真实采样时间，此后保持单调；来源及 Fable 均持久化。
- 合并页复用现有组件，保留回收页、编辑/登录/切换；本机统计默认折叠并标明非账号独立数据。
- 原 collector 已卸载，恢复原 statusLine 与其他 hooks。发现外部 ccstatusline block-timer 可自行请求额度，已询问用户是否备份后移除；未获回复前不修改外部工具配置。
- 独立代码复核通过：当前账号限定、缓存身份/Fable/时间、来源迁移与 UI 均无新高置信缺陷。
- 当前账号限定同时约束手动刷新与自动同步；历史数据只展示。

## Validation
| Command | Required | Done |
|---------|----------|------|
| 离线 AppState 账号操作检查（9 项含来源迁移及 Fable 跨进程持久化） | yes | yes |
| 官方 CLI store 边界检查（同账号、跨账号拒绝、Fable、时间、异常数据） | yes | yes |
| Release 66.8 构建与隔离假数据浅色/深色界面预览 | yes | yes |
| 安装副本签名、版本与运行进程核验 | yes | yes |

## Delivery
- 本地已安装 66.8，旧 app 备份于 /Applications/.CCSwitcher-before-current-account-quota-20261008.app。
- app 与 collector 二进制哈希和构建产物一致，codesign --verify --deep --strict 通过。collector 已从 CLI 设置卸载，不再被状态栏调用；旧缓存保留。
- 验证日志：build/current-account-build.log、build/current-quota-store.log；假数据界面：build/current-account-preview/。
- ccstatusline 的 block-timer 外部配置暂未修改，等待用户单独授权；此工具不属于 CCSwitcher 的读取路径，仍可能自行请求额度。
- 本轮没有发额度请求、运行真实登录、提交或推送。
