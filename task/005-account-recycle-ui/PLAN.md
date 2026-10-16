# PLAN -- Account recycling and clearer usage display

## Status: done
## Task: 005
## Related: 004
## Baseline Commit: 1c48c06

## Goal
Improve account/usage layout, allow reversible account recycling with a top-level recycled-account view, and show quota reset intervals in cumulative hours and minutes.

## Acceptance Criteria
- Clear card hierarchy, readable complete emails, consistent controls without crowding.
- Recycling preserves authorization and saved usage; recycled accounts are excluded from normal listings, automatic quota polling and auto-switch candidates.
- A top navigation entry shows recycled accounts and restores the same account identity; persistence survives restart and never silently re-adds recycled accounts.
- Each available quota window shows hours/minutes until reset, including windows longer than 24 hours, without network requests for ticking labels. Missing or past reset dates are explicit.
- Build, offline state regressions and visual verification pass; backup and replace local application.

## Non-goals
Permanent deletion, new network polling, credential changes on recycle/restore, committing or updating the existing upstream PR without a new request.

## Decisions
- Interpret 回收 as a reversible recycle bin. Preserve credentials and quota cache; disable automatic refresh on recycle and leave it off on restore.
- Existing exploration covers the visual components. Delegate a focused state/identity architecture trace before implementation.
- UI uses native SwiftUI controls, a wider 420pt popover, quieter card styling, and relative reset labels rather than dates.

## Implementation Map
| Files | Intent |
|---|---|
| Models/Account.swift, AppState.swift, AppState+Login.swift, AppState+Usage.swift | One persisted account list with optional recycledAt; local reversible transitions and visibility/request guards |
| Views/AccountSwitcherView.swift, Views/MainMenuView.swift, Services/StatusItemController.swift | Top-level recycled tab, separate row actions, readable full emails, 420pt width |
| Views/UsageDashboardView.swift, Models/UsageData.swift, Models/AppStyle.swift, Views/Components/CountdownLabel.swift | Clear cards, complete quota windows, local cumulative-hour countdowns |
| Localizable.strings | English and Simplified Chinese |
| Tools/check_account_actions.py, Tools/check_usage_countdown.py | Offline state and countdown regressions |

## Validation
- Offline recycle/restore/restart and credential-safety regression checks.
- Offline reset-time boundary checks where needed.
- Independent review, localization validation and git diff --check.
- Release build/signature, visual fixture inspection, local backup/install/startup verification.

## Architecture
- Explorer confirmed one existing accounts array plus optional recycledAt is backward-compatible and avoids two-store moves. All identity matching continues over all accounts; normal display, polling, widget entries and switch candidates use visibleAccounts.
- Recycled current account keeps the actual active identity; auto-switch exits while active is recycled. Explicit login may restore a matching recycled account under its original UUID; timer/cancel synchronization does not restore it.
- Top-level recycled view shares account rows with restore controls; no permanent deletion is introduced. Existing successful usage and request deadlines are preserved.

## Verification Results
- Tools/check_account_actions.py passed existing login/manual/background checks, recycled source/target auto-switch exclusion with restored positive controls, and four independent processes for cache/recycle persistence. Backup, UUID, sample timestamp and cooldown remain intact.
- Tools/check_usage_countdown.py passed cumulative hours, minute rounding, unknown/elapsed states and reset timestamp parsing.
- Independent core-review/diff-guard found no blocking issues.
- Final Release 66.5 build succeeded and codesign --verify --deep --strict passed; localization plists and git diff --check passed.
- Eight light/dark Chinese previews rendered through NSHostingView passed visual inspection, including complete long emails, all reset states, account actions and the recycled tab. Fixtures use fake accounts without network or credential access.
- Installed and launched build 66.5 at /Applications/CCSwitcher.app. Installed binary SHA-256 matches the verified Release artifact (f4d9549521809b7e50abe55814b57f0f5beac0ca142cccdc7b35bcbc45d8e124); installed signature passes deep/strict verification.
- Previous application preserved at /Applications/.CCSwitcher-before-recycle-ui-20261007.app and build/before-recycle-ui/CCSwitcher.app. No live quota requests or real-account recycle/restore operations were used for validation.
