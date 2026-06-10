### More accurate usage cost

CCSwitcher now matches the latest `ccusage` (20.0.9) to the cent. Anthropic bills **1-hour** prompt-cache writes at 2× the base rate, and Claude Code uses 1-hour caching for almost all of its cache writes — the previous calculation priced them at the lower 5-minute rate, undercounting your daily cost by roughly **9%**. Costs are now correct, and duplicate streaming rows are counted the same way ccusage 20.x counts them.

### Fable shows up by name

The new Claude **Fable** model now appears as "Fable" in the cost breakdown, the activity dashboard, and the widget — instead of the raw model id.

### Faster refreshes

Fixed a bug where the parsed-session cache never saved, forcing a full re-parse of every session log on each refresh. The cache now persists, so refreshes are near-instant.

---

### 用量费用更准确

CCSwitcher 现在与最新版 `ccusage`(20.0.9)逐分对齐。Anthropic 对**「1 小时」**提示词缓存写入按基础价的 2× 计费,而 Claude Code 几乎所有缓存写入都使用 1 小时缓存——之前按更低的「5 分钟」价计算,导致每日费用少算约 **9%**。现已修正,重复的流式记录也按 ccusage 20.x 的方式计数。

### Fable 正确显示

全新的 Claude **Fable** 模型现在会以「Fable」显示在费用明细、活动面板和小组件中,不再显示原始模型 id。

### 刷新更快

修复了解析缓存从不落盘的问题——之前每次刷新都要全量重新解析所有会话日志。现在缓存正常持久化,刷新接近瞬时。

---

**Full Changelog**: https://github.com/XueshiQiao/CCSwitcher/compare/v1.9.0...v1.10.0
