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

**Full Changelog**: https://github.com/XueshiQiao/CCSwitcher/compare/v2.1.0...v2.1.1
