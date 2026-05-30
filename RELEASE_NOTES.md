### Accurate cost tracking for newly released models

- **Fixed under-reported daily cost after a new model launch.** When a new Claude model (such as Opus 4.8) was released while CCSwitcher was running, its usage was priced at $0 — so the day's total collapsed to a tiny number until you quit and reopened the app. Pricing now updates live, with no restart needed.
- **Faster, lighter pricing updates.** Pricing data is now revalidated every refresh cycle using lightweight conditional requests (ETag). New model prices are picked up within minutes instead of up to a day, and when nothing has changed the check uses almost no network traffic.

---

### 新发布模型的费用统计修复

- **修复了新模型发布后当天费用被严重低估的问题。** 当有新的 Claude 模型(如 Opus 4.8)在 CCSwitcher 运行期间发布时,它的用量会被按 $0 计算,导致当天费用骤降到一个很小的数字,必须退出并重新打开 App 才能恢复。现在价格会实时更新,无需重启。
- **价格更新更及时、更省流量。** 价格数据改为每个刷新周期通过轻量的条件请求(ETag)进行校验,新模型的价格几分钟内即可生效(此前最长需 24 小时);在数据没有变化时,这次检查几乎不消耗任何流量。

---

**Full Changelog**: https://github.com/XueshiQiao/CCSwitcher/compare/v1.8.3...v1.9.0
