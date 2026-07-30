### Hide the head icon in the menu bar

**Settings → Menu Bar → Show head icon in menu bar** switches the brain icon off, so the strip shows only the readings you chose. Useful when your menu bar is crowded.

### Pick your own limit bar colors (opt-in)

Turn on **Customize limit bar colors** in Settings → Menu Bar and you can set the session bar, the weekly bar, and a low-remaining warning color separately — plus how much quota has to be left before the warning color takes over.

Off by default, and while it is off the bars look exactly as they always have: the menu-bar bars stay monochrome so they follow a light or dark menu bar and turn red only above 90% used, and the Usage dashboard keeps its green / orange / red steps at 60% and 90%.

### Thanks

- **[@kyoubelyu](https://github.com/kyoubelyu)** — the menu bar icon toggle and the custom limit bar colors ([#20](https://github.com/XueshiQiao/CCSwitcher/pull/20)).

### Included from v1.11.0

Released less than an hour before this one, so you may be updating straight past it.

#### Auto-switch before you hit the limit (opt-in)

Turn it on in **Settings → General → Auto-switch** and CCSwitcher moves you to the account with the most quota left once the active one reaches your chosen threshold (default 90%). Off by default — nothing changes unless you enable it.

It checks before it leaps: an account with no recent reading is never chosen, readings whose usage window has already reset are ignored, and the account it picked is re-checked immediately before the switch. After you switch or log in yourself, it leaves your choice alone for five minutes.

#### Usage polling that survives rate limits

The usage endpoint limits requests hard, and polling every account at once tripped it constantly — leaving *API Rate Limited* on screen instead of numbers. Accounts are now polled in turn, rate-limited accounts are left alone until the server says they may be asked again, and the last known figures stay on screen instead of vanishing.

Because of that, a card can be showing a reading from a few minutes ago, so cards now say **"Updated Xm ago"** once a figure is no longer fresh.

Backup accounts also refresh their own sign-in quietly now, instead of sitting in a permanent *Token expired* state between switches.

#### Account switching no longer fails for no reason

Since Claude Code 2.1.x, switching could fail with *"expected you@example.com but got unknown"*, and neither removing the account nor logging in again helped. Nothing was actually wrong: `claude auth status` simply omits the account identity when the CLI is authenticating through something other than your stored claude.ai login — an `ANTHROPIC_AUTH_TOKEN`, an `apiKeyHelper`, a token file, or a third-party provider. CCSwitcher now recognises that, verifies the switch against its own records, and tells you which credential source is taking precedence.

#### Your saved logins are much harder to lose

All accounts' saved logins live in one Keychain record. Previously a single failed *read* of that record — a denied Keychain prompt, a locked screen — was treated as "there is nothing there", and the next save would overwrite the record with just one account, permanently destroying every other account's saved login. The app now refuses to write when it could not read first, so the worst case is "try again shortly" rather than "log in to everything again".

A sign-in that gets renewed but cannot be saved is now reported honestly instead of being silently assumed to have worked, and a login token can no longer end up in the app's log file if Anthropic changes their response format.

#### Fixes

- The app could crash outright when an account or organisation name contained emoji or Chinese characters.
- Masking now works on the real email field, so non-ASCII and unusual address forms are hidden too — while organisation names that merely look email-shaped are never mangled.
- Logging into an account you had already added now marks it active immediately, instead of showing the previous account for up to ten minutes.
- Two account switches, or a switch and a login, can no longer run at once and leave credentials half-swapped.
- Error messages distinguish "you need to sign in again" from "this is temporary, it will retry".
- An account with no active subscription now says so, instead of showing a generic failure.
- Seven interface texts that always appeared in English are now translated in all five languages.

#### Thanks

- **[@AlexDesign420](https://github.com/AlexDesign420)** — traced the switching failure ([#18](https://github.com/XueshiQiao/CCSwitcher/issues/18)) to its root cause in the Claude Code CLI itself and fixed it ([#23](https://github.com/XueshiQiao/CCSwitcher/pull/23)).
- **[@appalexhu](https://github.com/appalexhu)** — rate-limit-resilient usage polling ([#22](https://github.com/XueshiQiao/CCSwitcher/pull/22)) and proactive auto-switch ([#21](https://github.com/XueshiQiao/CCSwitcher/pull/21)).

---

### 隐藏菜单栏上的头像图标

在**设置 → Menu Bar → 在菜单栏显示头像图标**中关掉它，菜单栏就只显示你选中的用量数据。菜单栏挤的时候很有用。

### 自定义额度条颜色（可选，默认关闭）

在设置 → Menu Bar 中开启**自定义额度条颜色**后，可以分别设定会话条、每周条、以及剩余额度不足时的警告色，还能调整「剩余多少才算不足」的阈值。

默认关闭，不开启时两个条的外观和以前完全一样：菜单栏里的条保持单色，会跟随菜单栏的明暗自动反色，只在用量超过 90% 时变红；用量面板里的条也保留 60% 与 90% 两档的绿 / 橙 / 红分级。

### 致谢

- **[@kyoubelyu](https://github.com/kyoubelyu)** —— 菜单栏图标开关与额度条颜色自定义（[#20](https://github.com/XueshiQiao/CCSwitcher/pull/20)）。

### 包含 v1.11.0 的更新

上一个版本发布至今不到一小时，你可能是直接跳过它更新过来的。

#### 达到限额前自动切换（可选，默认关闭）

在**设置 → General → Auto-switch** 中开启后，当前账户用量达到你设定的阈值（默认 90%）时，CCSwitcher 会自动切换到剩余额度最多的账户。默认关闭，不开启则一切照旧。

它会先核实再动手：没有近期用量数据的账户绝不会被选中，额度窗口已经重置的旧数据一律作废，选定的账户在切换前还会重新查一次。你自己手动切换或登录后，五分钟内它不会推翻你的选择。

#### 用量轮询不再被限流打垮

用量接口的请求频率限制很严，同时查询所有账户会频繁触发，导致界面上只剩 *API 请求频率受限* 而看不到数字。现在改为轮流查询，被限流的账户会等到服务器允许的时间再问，而且最后一次的有效数据会保留在界面上，不会直接消失。

正因为是轮流查询，卡片上的数字可能是几分钟前的，所以数据不再新鲜时会标注 **「X 分钟前更新」**。

备用账户现在也会自动续期自己的登录状态，不会在两次切换之间一直卡在*令牌已过期*。

#### 账户切换不再莫名其妙失败

从 Claude Code 2.1.x 开始，切换有时会失败并提示*「预期 you@example.com，但得到 unknown」*，删除账户重加或重新登录都无济于事。其实什么问题都没有：当 Claude Code 使用的不是你保存的 claude.ai 登录，而是 `ANTHROPIC_AUTH_TOKEN`、`apiKeyHelper`、令牌文件或第三方服务商时，`claude auth status` 就不会返回账户身份。CCSwitcher 现在能识别这种情况，改用自己的记录来核实切换是否成功，并告诉你是哪个凭据来源抢占了优先级。

#### 保存的登录信息不再容易丢失

所有账户的登录信息存放在钥匙串的同一条记录里。以前只要有一次**读取**失败——比如钥匙串弹窗被拒绝、屏幕处于锁定状态——就会被当成「里面什么都没有」，紧接着的一次保存就用仅剩一个账户的内容覆盖整条记录，其他账户的登录信息永久丢失。现在读不到就拒绝写入，最坏情况从「所有账户重新登录一遍」变成「过一会儿自动重试」。

登录信息续期成功但保存失败时，现在会如实告知，不再默认当作成功；即使 Anthropic 修改返回格式，登录令牌也不会再被写进日志文件。

#### 缺陷修复

- 账户名或组织名中含有 emoji、中文时，App 可能直接闪退。
- 打码改为直接作用于真实的邮箱字段，中文等特殊格式的地址也能隐藏；而只是长得像邮箱的组织名不会再被错误改写。
- 登录一个已添加过的账户，现在会立即标记为当前账户，不再最长十分钟仍显示旧账户。
- 两次账户切换、或切换与登录同时进行时，不会再互相干扰导致凭据只换了一半。
- 错误提示区分「需要重新登录」和「临时问题，会自动重试」。
- 没有有效订阅的账户会明确提示，不再显示笼统的失败信息。
- 7 处始终显示英文的界面文字，现已补齐五种语言的翻译。

#### 致谢

- **[@AlexDesign420](https://github.com/AlexDesign420)** —— 将切换失败问题（[#18](https://github.com/XueshiQiao/CCSwitcher/issues/18)）一路追查到 Claude Code CLI 本身的根因并修复（[#23](https://github.com/XueshiQiao/CCSwitcher/pull/23)）。
- **[@appalexhu](https://github.com/appalexhu)** —— 抗限流的用量轮询（[#22](https://github.com/XueshiQiao/CCSwitcher/pull/22)）与主动自动切换功能（[#21](https://github.com/XueshiQiao/CCSwitcher/pull/21)）。

---

**Full Changelog**: https://github.com/XueshiQiao/CCSwitcher/compare/v1.11.0...v1.12.0
