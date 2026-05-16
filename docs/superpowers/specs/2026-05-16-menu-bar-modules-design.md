# Configurable Menu Bar Modules — Design

**Date:** 2026-05-16
**Status:** Approved (pending user review)
**Author:** brainstorming session

## Goal

Replace the single "Show account name in menu bar" toggle with an iStats-style
multi-selectable, reorderable set of compact modules that show account identity
and live usage signals directly in the macOS menu bar.

## Motivation

Today the menu bar can only optionally show the account name. Power users want
glanceable access to:

- How much of the 5-hour rate-limit window they've consumed
- How much of the weekly quota they've consumed
- How much they've spent today
- Time until the next reset

Forcing them to open the dropdown to see those numbers defeats the point of a
menu-bar app.

## Non-Goals

- Per-account menu bar configuration (the active account drives all modules).
- Opus-specific weekly bar, overage credits bar — deferred.
- Burn-rate / token-count modules — deferred. The enum-based architecture makes
  these trivial to add later.
- A new fetch path for usage or cost data — we reuse `AppState.refreshTimer`.

## User-facing behavior

### Modules (6 total)

| Module | Type | Render | Source |
|---|---|---|---|
| `account` | text | obfuscated email or full email (per `showFullEmail`) | `appState.activeAccount.effectiveDisplayName(obfuscated:)` |
| `sessionBar` | bar + % | `▓▓▓░ 73%` (28×8pt capsule) | `accountUsage[id].fiveHour.utilization` |
| `weeklyBar` | bar + % | `▓▓░░ 42%` | `accountUsage[id].sevenDay.utilization` |
| `dailyCost` | text | `$4.20` | `CostParser` output, cached on AppState as `todayCost: Double?` |
| `sessionReset` | text | `2h 14m` | `fiveHour.resetsAt` → countdown |
| `weeklyReset` | text | `4d 6h` | `sevenDay.resetsAt` → countdown |

### Empty / unknown values

When data is unavailable (no active account, API hasn't returned yet, no token):

- Text modules render `–` (en-dash)
- Bar modules render an empty capsule (no fill) with `–` instead of `%`
- The `account` module hides entirely if there's no active account

This keeps widths stable and avoids flicker during launch.

### Bar coloring

- Default fill: `Color.primary` (adapts to light/dark menu bar)
- When `utilization > 0.9`: fill switches to `.red`
- When `utilization > 1.0` (overage): bar clamps at 100% fill, stays red

No green/orange/red threshold ladder — the user wants minimalism with a single
"danger" signal.

### Refresh cadence

- Bar `%` and `dailyCost` update whenever `AppState.refreshTimer` fires — no
  new timers, no new fetches.
- `sessionReset` and `weeklyReset` countdowns recompute every 60 seconds. The
  app holds a `@State private var menuBarTick = Date()` in `CCSwitcherApp` and a
  `Timer.publish(every: 60, on: .main, in: .common).autoconnect()` publisher
  that updates it. `MenuBarModuleView` receives `menuBarTick` as a parameter so
  reset modules re-render on each tick. The reset *timestamp* (`resetsAt`)
  comes from the same cached `UsageAPIResponse`; only the displayed "time
  remaining" is locally derived from `menuBarTick`.

### Settings UI

In `SettingsView.swift`, the existing `Toggle("Show account name in menu bar")`
becomes a section titled **Menu Bar Display**:

```
Menu Bar Display
┌─ Drag to reorder, toggle to enable ─────────────┐
│ ☑ ⋮⋮  Account name                              │
│ ☑ ⋮⋮  Session usage           ▓▓▓░ 73%          │
│ ☐ ⋮⋮  Weekly usage            ▓▓░░ 42%          │
│ ☑ ⋮⋮  Daily cost              $4.20             │
│ ☐ ⋮⋮  Session reset           2h 14m            │
│ ☐ ⋮⋮  Weekly reset            4d 6h             │
└─────────────────────────────────────────────────┘
Preview: [🧠] joey@…  ▓▓▓░ 73%  $4.20
```

- SwiftUI `List` with `.onMove` for drag-reorder
- Each row: `HStack { Toggle(""), Image("line.3.horizontal"), Text(label), Spacer(), samplePreview }`
- Sample previews are stable mock values so the user can see what each module looks like before enabling it
- A "live preview" row beneath the list shows exactly what will appear in the menu bar with the current selection

## Architecture

### Data model

```swift
// CCSwitcher/Models/MenuBarModule.swift
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case account
    case sessionBar
    case weeklyBar
    case dailyCost
    case sessionReset
    case weeklyReset

    var id: String { rawValue }
    var localizedLabel: String { /* L10n lookup */ }
}
```

### Storage

A single `@AppStorage("menuBarModules")` key holding a JSON-encoded
`[MenuBarModule]`. Array order = render order. Empty array = nothing shown
(replaces "off" state of the old toggle).

```swift
@AppStorage("menuBarModules") private var menuBarModulesData: Data = Data()

private var enabledModules: [MenuBarModule] {
    (try? JSONDecoder().decode([MenuBarModule].self, from: menuBarModulesData)) ?? []
}
```

### Migration

On first launch after upgrade:

1. If `menuBarModules` key is absent (data is empty), check legacy `showAccountName`
2. If legacy is `true`: persist `[.account]`
3. If legacy is `false` or absent: persist `[]`
4. Leave the legacy `showAccountName` key intact for one release as a safety net
   (in case we need to roll back).

Migration runs once in `CCSwitcherApp.init()`, guarded by `UserDefaults` bool
`menuBarModulesMigratedV1`.

### View hierarchy

```
CCSwitcherApp.menuBarLabel (CCSwitcherApp.swift:79)
└── HStack(spacing: 6)
    ├── Image(brain.head.profile[.fill])      // existing icon
    └── ForEach(enabledModules) { module in
          MenuBarModuleView(module: module,
                            appState: appState,
                            showFullEmail: showFullEmail,
                            now: timerTick)
        }
```

`MenuBarModuleView` is a `switch`-based view that renders the appropriate
sub-view per case. The `now: Date` parameter (driven by the 60s timer) is only
used by reset countdown cases — bars and text don't read it.

### Settings

```
SettingsView (replace Toggle at line 56)
└── Section("Menu Bar Display")
    └── MenuBarModulesEditor
        ├── List with .onMove + toggle per row
        └── live preview HStack
```

## Files touched

| File | Change | LOC est |
|---|---|---|
| `CCSwitcher/Models/MenuBarModule.swift` | NEW: enum + label helpers | ~40 |
| `CCSwitcher/Views/MenuBarModuleView.swift` | NEW: per-module rendering, threshold color | ~120 |
| `CCSwitcher/Views/MenuBarModulesSettingsView.swift` | NEW: drag-reorder list + preview | ~150 |
| `CCSwitcher/CCSwitcherApp.swift` | Edit `menuBarLabel`; add 60s timer publisher; add migration call | ~30 |
| `CCSwitcher/Views/SettingsView.swift` | Replace toggle with section | ~10 |
| `CCSwitcher/AppState.swift` | Publish `todayCost: Double?`, populate on refresh | ~20 |
| `CCSwitcher/Services/L10n.swift` | New keys (module labels, section title) | ~15 |
| `CCSwitcher/Models/UsageData.swift` | Add `compactResetString` (sibling of `resetTimeString`, always `Xd Yh` / `Xh Ym` / `Xm` — no date fallback) | ~10 |
| `project.yml` | None (no new targets, just new source files in existing groups) | 0 |

Run `xcodegen generate` after adding the new files (per CCSwitcher project rules).

## Edge cases

- **No active account** — all modules render placeholder; `.account` hides
- **API not yet returned (launch)** — placeholders, no spinner (too noisy in
  menu bar)
- **utilization > 1.0** — bar clamps at 100% fill, stays red
- **utilization == nil** — treated as unavailable, placeholder rendered
- **Very wide menu bar selection** — no truncation; macOS handles this by
  showing/hiding the app icon. Settings UI shows the preview so user can see
  before committing.
- **>24h reset countdown** — existing `resetTimeString` returns a date format
  (`EEE h:mm a`) for >24h, which is fine for the dropdown but too wide for the
  menu bar. We add a sibling `compactResetString` that always returns
  `Xd Yh` / `Xh Ym` / `Xm` / `"now"`. The existing `resetTimeString` is
  unchanged so the dropdown UI keeps its current behavior.
- **`showFullEmail` change** — `.account` module re-renders automatically
  because `MenuBarModuleView` takes it as a parameter.

## Localization

New L10n keys:

- `menubar.section.title` → "Menu Bar Display" / "菜单栏显示"
- `menubar.module.account` → "Account name" / "账户名"
- `menubar.module.sessionBar` → "Session usage" / "会话用量"
- `menubar.module.weeklyBar` → "Weekly usage" / "每周用量"
- `menubar.module.dailyCost` → "Daily cost" / "今日花费"
- `menubar.module.sessionReset` → "Session reset" / "会话重置"
- `menubar.module.weeklyReset` → "Weekly reset" / "每周重置"
- `menubar.editor.hint` → "Drag to reorder, toggle to enable" / "拖动排序，点击启用"

Reuses existing `resetTimeString` localization for countdown text.

## Testing

- Unit tests for `MenuBarModule` JSON encode/decode round-trip
- Unit tests for migration logic (`showAccountName=true` → `[.account]`,
  `showAccountName=false` → `[]`, absent → `[]`, already-migrated → no-op)
- Unit tests for extended `resetTimeString` (>24h, >0h<24h, <1h, expired)
- Manual: enable each module in turn, verify menu bar render
- Manual: drag-reorder, verify menu bar reorder live
- Manual: utilization crossing 90% threshold → bar turns red
- Manual: light + dark menu bar appearance
- Manual: zh-Hans locale → all strings localized

## Open questions

None — all clarifications resolved during brainstorming.

## Out of scope (deferred)

- Opus weekly bar (`sevenDayOpus.utilization` exists; trivial to add later)
- Overage credits bar (`extraUsage.utilization`)
- Per-account menu bar (active account only for now)
- Burn rate, token counts
- Custom module colors / per-module styling
