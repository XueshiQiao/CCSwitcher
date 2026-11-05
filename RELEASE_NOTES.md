### Much lower CPU use while the app sits idle

With the panel closed, CCSwitcher kept about 3–8% of a CPU core busy, and one report measured it climbing to 97% after 18 hours of uptime. The cause was that the closed panel's content stayed alive and kept redrawing itself with nothing on screen, on every refresh and for every spinner and pulsing dot. Now the panel's content is only built while the panel is open, so a closed panel costs almost nothing. On our test Mac, the 60-second average CPU use with the panel closed went from about 3.0% to about 0.1%.

Other small changes with the same goal:

- The menu bar strip updates once a minute instead of every 3 seconds.
- `claude --version` is not run on every refresh any more, only when the `claude` file changes. `claude auth status` still runs on every refresh, so which account is signed in is never out of date.
- Keychain and file reads during a refresh no longer block the panel.
- The widget reloads only when what it shows has changed.
- The refresh timer pauses while the Mac sleeps and refreshes right away on wake if one is due.

What you may notice: when you reopen the panel, the scroll position and an unfinished label edit are reset. The selected tab and the panel size are kept.

### Thanks

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** — the idle CPU work above ([#47](https://github.com/XueshiQiao/CCSwitcher/pull/47)).
- **[@FXeio](https://github.com/FXeio)** — for measuring the closed panel's CPU use over many hours and tracking it down to the panel content staying alive ([#56](https://github.com/XueshiQiao/CCSwitcher/pull/56)).

#### Included from v2.1.2

### Usage data no longer fails with "UNIQUE constraint failed"

Some people saw a SQLite error at the bottom of the panel after switching accounts (`19 UNIQUE constraint failed`), and deleting `usage.sqlite` did not help. The cause was the one-time import of the old usage cache (`session-parse-cache-v2.json`): when that cache listed the same message twice, or the same file under two paths, the import stopped, and it stopped again every time the app opened the database. The import now keeps the larger of two duplicate messages and skips a file it already imported, so it finishes. Thanks to **[@pbakkerasfaudits](https://github.com/pbakkerasfaudits)** for reporting it ([#55](https://github.com/XueshiQiao/CCSwitcher/issues/55)).

#### Included from v2.1.1

### Fixes and polish

- **Removing an account now asks first.** The Cancel and Remove buttons appear right in the row, in both the Classic and the 2.0 styles.
- **Your plan is read from your account profile**, so it no longer stays stale after you change plans.
- **"Account already exists - credentials refreshed" is shown as a success**, in green, and takes itself down after a few seconds. It used to look like an error and stay up.
- **Long error messages show up to three lines** in the footer, with the full text as a tooltip.
- **The Usage tab explains what to do when no account is added yet**, instead of "Usage data unavailable".
- **Keyboard shortcuts in the panel:** ⌘1, ⌘2 and ⌘3 pick the Usage, Costs and Accounts tabs, ⌘R refreshes, ⌘, opens Settings.
- **Better VoiceOver and Reduce Motion support**, and fainter text is easier to read.
- **Clicking the very top edge of the menu bar icon now closes the panel**, like clicking the middle does.
- **`~/.claude.json` is written more carefully:** it keeps its private permissions, a symlink to it is followed instead of replaced, and a change the Claude CLI makes while we write is not overwritten. Email addresses no longer appear in the log file.

### A smaller download

The app is about a third smaller (the signed download goes from about 10.8 MB to 7.2 MB). Debug symbols are stripped, two unused images are gone, and so are two Sparkle helper services that only sandboxed apps use. Updating still works the same way.

### Thanks

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** — the account removal confirmation, accessibility and keyboard fixes, the safer `~/.claude.json` write, the smaller build, the unit tests and the menu bar icon fix ([#48](https://github.com/XueshiQiao/CCSwitcher/pull/48), [#51](https://github.com/XueshiQiao/CCSwitcher/pull/51), [#52](https://github.com/XueshiQiao/CCSwitcher/pull/52), [#53](https://github.com/XueshiQiao/CCSwitcher/pull/53), [#54](https://github.com/XueshiQiao/CCSwitcher/pull/54)).

#### Included from v2.1.0

#### The classic interface is back

The menu bar panel looks like 1.x again by default. Everything added in 2.0 is still there, including the model-specific weekly limit, the Switch button on the Usage tab, and Copy Login URL / Cancel while logging in.

Prefer the 2.0 look? Pick it in **Settings → General → Appearance → Panel style**:

- **Classic** — the 1.x interface (default)
- **Warm** — the 2.0 design
- **Translucent** — the 2.0 layout on the system material, so the desktop shows through
- **Claude** — flat and neutral, with plain cards and quieter colours

#### Numbers in your language

Costs, token counts, percentages and dates now follow your language and region (for example `12,35 $` in German). The Daily History list names the currency once in its heading instead of on every row.

#### Translations

Text that was still in English in every language is now translated, and German, French, Japanese, Chinese and Spanish have every string.

#### Fixes

- Clicking the menu bar icon a second time now closes the panel.
- "1 sessions" now reads "1 session".

#### Thanks

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** — panel styles, locale formats, the translations and the second-click fix ([#43](https://github.com/XueshiQiao/CCSwitcher/pull/43), [#44](https://github.com/XueshiQiao/CCSwitcher/pull/44), [#45](https://github.com/XueshiQiao/CCSwitcher/pull/45), [#49](https://github.com/XueshiQiao/CCSwitcher/pull/49)).
- **[@binjto-boop](https://github.com/binjto-boop)** — for asking for the classic interface back ([#50](https://github.com/XueshiQiao/CCSwitcher/issues/50)).

---

### App 空闲时 CPU 占用大幅降低

面板关着的时候，CCSwitcher 一直占着一个 CPU 核的 3%–8%；有人实测开着 18 小时后涨到了 97%。原因是关掉的面板里的内容并没有销毁，屏幕上明明什么都看不见，每次刷新、每个转圈图标和闪烁的小圆点，它还是在不停地重新绘制。现在面板的内容只在面板打开时才会创建，面板关着就几乎不占 CPU。在我们的测试机上，面板关着时 60 秒内的平均 CPU 占用从约 3.0% 降到了约 0.1%。

同样为了省资源的其他小改动：

- 菜单栏条改为每分钟更新一次，原来是每 3 秒一次。
- 不再每次刷新都执行 `claude --version`，只有 `claude` 文件发生变化时才会执行。`claude auth status` 仍然每次刷新都会执行，所以当前登录的是哪个账号不会是过期的。
- 刷新时读取钥匙串和文件，不会再卡住面板。
- 小组件只在显示的内容变化时才会重新加载。
- 电脑睡眠时刷新定时器会暂停，唤醒后如果有刷新已经到期，会马上刷新。

你可能会注意到的变化：重新打开面板时，滚动位置和还没改完的名称编辑会被重置。选中的标签页和面板大小会保留。

### 致谢

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** —— 上面这些降低空闲 CPU 占用的改动（[#47](https://github.com/XueshiQiao/CCSwitcher/pull/47)）。
- **[@FXeio](https://github.com/FXeio)** —— 连续多个小时实测关着的面板占用的 CPU，并查到原因是面板的内容一直没有销毁（[#56](https://github.com/XueshiQiao/CCSwitcher/pull/56)）。

#### 包含 v2.1.2 的更新

### 用量数据不再因为「UNIQUE constraint failed」而失败

有人切换账号之后，面板底部会出现 SQLite 错误（`19 UNIQUE constraint failed`），删掉 `usage.sqlite` 也没用。原因是 app 会把旧版的用量缓存（`session-parse-cache-v2.json`）导入一次：缓存里同一条消息出现了两次，或者同一个文件用两个路径各记了一次，导入就会中断，而且之后每次打开数据库都会再中断一次。现在遇到重复的消息，会保留 output 更大的那一条；遇到已经导入过的文件，会直接跳过，所以导入可以正常完成。感谢 **[@pbakkerasfaudits](https://github.com/pbakkerasfaudits)** 报告这个问题（[#55](https://github.com/XueshiQiao/CCSwitcher/issues/55)）。

#### 包含 v2.1.1 的更新

### 缺陷修复与细节改进

- **删除账号前会先确认。** 取消和删除两个按钮直接出现在那一行里，经典界面和 2.0 样式都一样。
- **套餐名称改为从账号资料里读取**，换了套餐之后不会再显示旧的。
- **「账号已存在，凭证已刷新」现在显示成绿色的成功提示**，几秒后会自己消失。以前它看起来像报错，而且会一直留着。
- **较长的报错信息在底部最多显示三行**，完整内容放在鼠标悬停的提示里。
- **还没有添加账号时，用量标签页会告诉你下一步怎么做**，不再只写「用量数据不可用」。
- **面板里的键盘快捷键：** ⌘1、⌘2、⌘3 切换到用量、费用、账号标签页，⌘R 刷新，⌘, 打开设置。
- **改进了 VoiceOver 和「减弱动态效果」的支持**，浅色文字也更容易看清。
- **点菜单栏图标的最上边缘，现在也能关掉面板**，和点中间一样。
- **更谨慎地写入 `~/.claude.json`：** 保留它原来的私有权限；如果它是符号链接，会写到链接指向的文件里，不会把链接替换掉；Claude 命令行在我们写入的同时改了文件，也不会被我们覆盖。日志里不再出现邮箱地址。

### 安装包更小

应用体积大约小了三分之一（签名后的下载包从约 10.8 MB 降到约 7.2 MB）。去掉了调试符号、两张没用到的图片，以及 Sparkle 里两个只有沙盒应用才会用到的辅助服务。更新的方式不变。

### 致谢

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** —— 删除账号前的确认、无障碍和键盘快捷键、更安全的 `~/.claude.json` 写入、更小的安装包、单元测试，以及菜单栏图标边缘点击的修复（[#48](https://github.com/XueshiQiao/CCSwitcher/pull/48)、[#51](https://github.com/XueshiQiao/CCSwitcher/pull/51)、[#52](https://github.com/XueshiQiao/CCSwitcher/pull/52)、[#53](https://github.com/XueshiQiao/CCSwitcher/pull/53)、[#54](https://github.com/XueshiQiao/CCSwitcher/pull/54)）。

#### 包含 v2.1.0 的更新

#### 经典界面回来了

菜单栏面板默认恢复成 1.x 的样子。2.0 新增的功能都还在，包括单个模型的每周限额、用量标签页上的切换按钮，以及登录时的「复制登录链接」和「取消」。

更喜欢 2.0 的样子？可以在**设置 → 通用 → 外观 → 面板样式**里选择：

- **经典** —— 1.x 的界面（默认）
- **暖色** —— 2.0 的设计
- **半透明** —— 2.0 的版面，背景用系统材质，能透出桌面
- **Claude** —— 扁平、中性，卡片样式简单，颜色更安静

#### 数字按你的语言显示

费用、token 数、百分比和日期现在会按你的语言和地区来写（比如德语写成 `12,35 $`）。「每日历史」把货币单位写在标题里，每一行只显示数字。

#### 翻译

之前在所有语言里都还是英文的文字，现在都翻译了；德语、法语、日语、中文和西班牙语的翻译都已补全。

#### 缺陷修复

- 再点一次菜单栏图标，现在可以关掉面板。
- 英文界面里的「1 sessions」改成了「1 session」。

#### 致谢

- **[@ANGELBERRIOS23](https://github.com/ANGELBERRIOS23)** —— 面板样式、按地区显示数字、翻译，以及再点一次关闭面板的修复（[#43](https://github.com/XueshiQiao/CCSwitcher/pull/43)、[#44](https://github.com/XueshiQiao/CCSwitcher/pull/44)、[#45](https://github.com/XueshiQiao/CCSwitcher/pull/45)、[#49](https://github.com/XueshiQiao/CCSwitcher/pull/49)）。
- **[@binjto-boop](https://github.com/binjto-boop)** —— 提出把经典界面加回来（[#50](https://github.com/XueshiQiao/CCSwitcher/issues/50)）。

---

**Full Changelog**: https://github.com/XueshiQiao/CCSwitcher/compare/v2.1.2...v2.1.3
