# PLAN -- 模型费用与缓存命中率

## Status: done
## Task: 011
## Related: 010
## Baseline Commit: 1c48c06

## Goal
- 优化费用页：按具体模型区分费用及 token 用量。
- 显示整体和每模型缓存命中率，支持今日、近7天、近30天。

## Non-goals
- 不请求官方额度、不启动CLI，不改变账号、登录或窗口定位行为。
- 不修改既有逐请求定价、长上下文、快速模式或去重算法。

## Acceptance Criteria
- 保留原始模型ID，不把不同版本的Opus/Fable/Sonnet合并成同一模型。
- 缓存命中率按token计算：缓存读取 / (普通输入 + 缓存写入 + 缓存读取)。输出不进分母，无输入时为未适用。
- 显示普通输入、输出、缓存写入和读取token，汇总按token加权而非平均百分比。
- 缺少价格的模型显示未计价，不显示为免费；整体明确为本地日志API等价估算。
- 离线聚合检查、浅深色预览、构建及本地替换核验通过。

## Decisions
- 复用已有逐请求价格和四种token字段；派独立探索确认聚合位置后实现。
- 字段口径由官方公开提示缓存文档确认，未发送任何授权额度请求。

## Validation
| Check | Required | Done |
|---|---|---|
| 模型/时间范围/token加权/缺价格离线行为检查 | yes | yes |
| 420×600费用页浅深色预览 | yes | yes |
| Release构建、签名和安装运行核验 | yes | yes |

- 已完成探索与最小设计：聚合仍按现有逐请求max-output-wins去重和价格表计价；派生每日结果保留原始模型ID和四类token，不改变磁盘缓存schema。
- ModelCost.cost为可选，未知价格保留token并标未计价；CostPeriodSummary.knownCost是已知价格小计。
- 期间指标统一在CostSummary.period中聚合；今日/7天/30天同一条路径，缓存率按总量加权。
- UI复用SwiftUI原生Picker/DisclosureGroup，420×600固定窗口仅内部滚动。无需新增依赖或用户设计审批。

## Implementation Map
| File | Intent | Owner |
|---|---|---|
| Models/CostData.swift | 精确模型及期间聚合模型、加权缓存率 | explore_quota |
| Services/SessionParseCacheV2.swift | 保留精确模型及token输出、明确未计价 | explore_quota |
| Tools/check_model_costs.py | 离线聚合与时间边界行为验证 | explore_quota |
| Views/CostDetailView.swift | 时间范围、模型费用与缓存效率 | stable_popover |
| en/zh-Hans Localizable.strings | 新费用页文案 | root |

- 首轮Release 66.10构建通过；420×600假数据明暗预览已核对具体模型、未计价及零输入状态。
- 独立审查发现非公历系统的日期键与缓存公历键不一致，已修复并通过佛历回归；不改变token/定价口径。

## Result
- 按完整模型ID显示费用、整体/各模型缓存命中率，今日/7天/30天同口径筛选，Token明细可展开。
- 费用明确为本机全部账号日志的API等价估算；未知价格保留token并标未计价，不纳入已计价小计。
- 离线检查通过：精确模型、跨文件max-output去重、nil hash保留、1h/fast/200k逐请求计价、未知价、缓存加权、日期边界及佛历兼容。
- 独立只读审查Approved；git diff --check及中英文strings校验通过。
- build/model-cost-preview/包含今日/7天/30天/全未计价/空状态共10张420×600假数据明暗预览，主代理已目视核对今日明暗和全未计价。
- Release 66.10构建通过，日志build/model-cost-build.log。已替换/Applications/CCSwitcher.app并启动，codesign及主程序/CLI二进制SHA256与构建产物一致。
- 旧版66.9备份：/Applications/.CCSwitcher-before-model-cost-cache-20261008.app；另有build/before-model-cost-cache/CCSwitcher.app副本。
- 本轮未启动真实Claude会话或请求官方额度；未提交或推送代码。

- 预览限制：离屏自动化未成功驱动SwiftUI Token明细DisclosureGroup，未声称其展开截图已验证；未为此添加生产测试接口。
