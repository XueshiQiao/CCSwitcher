# PLAN -- 统一五分钟本地读取

## Status: done
## Task: 013
## Related: 012
## Baseline Commit: 1c48c06

## Goal
只保留每五分钟一次本地缓存/日志读取，取消其他周期任务。

## Non-goals
不修改账号授权、用量计算、手动操作或登录进程取消的超时保护。

## Acceptance Criteria
- 唯一App周期任务固定300秒，启动读取一次；保留当前账号自动同步开关。
- 取消5秒额度读取、可配置间隔、菜单栏3秒及预览/倒计时60秒轮询。
- Widget只由主App推送更新，Sparkle仅手动检查；缓存扫描不后台下载价表。
- 构建、离线账号行为检查和本地替换验证通过。

## Decisions
- 主代理已逐个追踪Timer/Timeline及调用链，直接采用原有refresh路径和StatusItemController事件驱动刷新；无需额外探索/架构轮次。
- 主代理实现刷新与UI，子代理负责独立的更新检查/Widget区域，并进行最终只读审查。
- 纯定时配置与UI移除不新增常量/源码断言；运行已有离线账号行为检查覆盖本地读取及开关边界。

## Validation
- [x] 离线账号行为检查
- [x] 定时/网络入口审查、diff检查
- [x] Release构建及本机备份替换核验

- Tools/check_account_actions.py通过：本地身份/样本归属、账号自动同步开关、登录取消、历史持久化、后台不调用CLI或切换账号。
- 定时扫描已确认App仅剩一个300秒Timer；登录取消的单次超时保护保留。Widget改为.never由App更新数据时通知。

- 独立审查Approved：Sparkle手动检查后仍不会建立自动轮询，现有状态事件驱动菜单栏，剩余延时仅为进程等待/取消保护。
- Release66.12已安装并启动，签名及主程序/CLI哈希一致。旧版66.11备份：/Applications/.CCSwitcher-before-five-minute-refresh-20261008.app。
- 未提交或推送代码；本轮验证未请求额度或运行真实Claude会话。
