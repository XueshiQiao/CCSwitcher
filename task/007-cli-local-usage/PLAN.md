# PLAN -- Passive CLI quota cache

## Status: done
## Task: 007
## Related: 006
## Baseline Commit: 1c48c06

## Goal
Display quota from local Claude Code statusline output only. CCSwitcher must not request Anthropic quota, token refresh or latest-version endpoints.

## Non-goals
No simulated CLI prompts, automatic CLI launches to obtain quota, HTTP fallback, real account requests, commits or pushes. Existing explicit CLI login/account switching remains available. GitHub pricing/app update traffic is outside the Anthropic quota boundary.

## Acceptance Criteria
- Delete every direct Anthropic HTTP implementation and background auth-status subprocess.
- Preserve saved usage and account data; label historical versus CLI records honestly.
- Collect only official statusline rate_limits, never raw stdin/credentials; bind sessions to a verified local account identity and reject ambiguous changes.
- Preserve existing ccstatusline command/output and unrelated settings/hooks with a reversible installation.
- Missing/invalid data never means zero usage and never triggers network fallback; repeated statusline redraws never fake freshness.
- Offline collector/state regressions, independent review and Release build pass; backup and replace local app, install integration.

## Decisions
- Dev exploration delegated for request paths and CLI integration; use their completed trace as implementation design.
- Native Foundation helper embedded in the app avoids a runtime Python dependency. Installer is a development Python3 tool run through uv.
- SessionStart establishes immutable session-to-account binding; each statusline callback rechecks identity. Cache only quota windows with an observed-output timestamp, not a claimed server sample timestamp.
- Per-account automatic toggle now controls only local cache synchronization; preserve the user's saved choice. Manual sync reads local files. Periodic local reads run without launching the CLI.
- Automatic switching is disabled in local-only mode: independent review found it could invoke background CLI auth verification. Explicit manual switching remains available.
- Existing user authorization covers local integration and app replacement; settings are backed up and installation is reversible.

## Implementation Map
| Owner | Files | Intent |
|---|---|---|
| root | AppState, AppState+Usage, local cache reader, usage/settings UI, localization | Local import and honest state display |
| design | CLIUsageBridge, project.yml, installer, bridge checks | Passive capture, identity/duplicate protections and reversible integration |
| usage_cache_checks | ClaudeService, CLI settings, obsolete HTTP checks, account checks | Remove direct HTTP and migrate regression coverage |

## Validation
- Existing process and login checks (passed by independent agent).
- Offline collector/install and account/cache regressions.
- Independent core-review/diff-guard.
- Release build, native UI verification, installed signature/binary/process check.
- Integration ownership/backup verification without real quota requests.

## Verification Results
- Offline process/login regressions passed (8 process checks and 4 login checks); no real CLI authorization invoked.
- Collector/installer regression passed using fake homes and stdin, including identity mismatch invalidation, multi-session redraw deduplication, unchanged stdin/stdout/exit code, profile overrides and failed settings-write rollback.
- CLIUsageStore boundary check passed for missing windows, account mismatch, corrupt/range/future-date records and truthful expired readings.
- AppState regression passed including local-only sync, opt-in persistence, missing/older/corrupt snapshots, provenance, login cancellation, recycle/restore and independent-process persistence. Legacy auto-switch settings cannot start CLI; explicit manual switch still works.
- Independent review found one background auto-switch CLI path; it was removed and the reviewer approved the repair.
- Chinese light/dark native-view fixture verification passed for CLI/historical/missing/error states and long emails.
- Release 66.7 build succeeded. Installed application and embedded helper match Release binaries; deep/strict signature verification and running process checks passed.
- Installed bridge in ~/.claude/settings.json, preserving original ccstatusline object and all unrelated settings/hooks. Backups and manifest are mode 0600 in ~/.ccswitcher/cli-usage/.
- Previous app retained at /Applications/.CCSwitcher-before-local-cli-20261008.app. Installation is reversible via Tools/install_cli_usage_bridge.py uninstall; existing quota records are retained.
- No real quota requests or synthetic Claude sessions were used for verification. A new user-started Claude Code session is required for the first live local record. Automatic local sync continues to respect each saved account switch.
- No commit/push performed.
