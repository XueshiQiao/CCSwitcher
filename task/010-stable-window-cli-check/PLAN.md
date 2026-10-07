# PLAN -- 稳定窗口与官方 CLI 主动检查

## Status: done
## Task: 010
## Related: 009
## Baseline Commit: 1c48c06

## Goal
- 修复弹窗随内容变化跳动及菜单栏锚点位移，简化账号与额度界面。
- 核实官方 CLI 会话检查额度的可行路径，并实现只由用户主动触发、仅当前账号的入口。

## Non-goals
- 不自动轮询、不自动切换账号，不新增直接官方 API 请求，不发送模型测试提示。
- 不修改未获确认的 ccstatusline 外部配置，不扩大修复登录事务。

## Acceptance Criteria
- 打开期间窗口尺寸稳定，内容和页签变化使用内部滚动，适配所在屏幕高度。
- 当前账号与历史账号结构清晰，保留邮箱、Fable、恢复时间及管理入口。
- CLI 主动检查只走经证实的官方内置命令，并如实说明会由 CLI 联网。
- 相关离线检查、假数据预览及 Release 构建通过，备份后本地替换。

## Decisions
- 窗口稳定与 CLI 命令核查由独立子代理并行，UI 样式主代理处理。

## Validation
| Check | Required | Done |
|---|---|---|
| 固定弹窗几何离线验证、浅深色预览 | yes | yes |
| CLI 启动路径及当前账号/冷却隔离检查、4阶段持久化 | yes | yes |
| Release 66.9 构建与本地安装核验 | yes | yes |

- 根因：内容测高持续改变 NSHostingController preferredContentSize，叠加动画造成重定位；菜单栏宽度刷新同时改变锚点。
- 固定宽420、高600或所在屏幕高度上限；打开期间延迟状态栏宽度变化，关闭后应用。
- 当前账号置顶展开，历史账号默认折叠；紧凑系统控件、原生分段页签、小按钮，登录入口固定底部。
- 本机2.1.289已证实 --safe-mode /usage 走内置local-jsx命令、不调用模型；官方CLI仍会进行额度/鉴权网络活动。仅用户点击时打开可见Terminal，每账号15分钟启动间隔，不复用本地同步限制。
- 安全模式禁用hooks、状态栏、插件及MCP；启动前校验当前身份和认证覆盖配置，脚本执行时再次核对身份和环境。

- 独立复核发现遗漏的 CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR 已补入拒绝列表并通过离线边界验证；没有把仅用于Linux远程的来源标签误当环境变量。
- 实际NSPopover几何验证通过：0到12账号、加载/错误、锚点内容扩宽、语言与页签切换、回空列表均固定，关闭后才应用宽度。日志 build/stable-popover-check/check.log。
- 420×600浅深色预览通过：build/current-account-preview/main-light.png 与 main-dark.png。

## Delivery
- 已安装并启动66.9，签名通过，主app及helper二进制与构建产物哈希一致。旧版备份 /Applications/.CCSwitcher-before-stable-cli-20261008.app。
- Launcher离线Swift6边界检查通过：特殊字符引用、身份变化、auth FD/env覆盖、备用凭据、退出码和临时文件清理。
- AppState全套检查通过，含当前/非当前账号、15分钟持久间隔、打开失败不设冷却、冷却不影响本地同步、4阶段持久化。
- 独立复核通过。没有运行真实CLI、打开真实检查会话、发起真实额度请求，也未修改ccstatusline外部配置。
- 真机app屏幕采集工具失败；界面验证使用真实NSPopover+假数据几何检查与浅深色离线渲染，没有冒充实际账号联网验收。
