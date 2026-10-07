# REVIEW -- Login and credential state

## Status: done
## Task: 008
## Related: 007
## Baseline Commit: 1c48c06 (current working tree, installed 66.7)

## Scope
- Focus: login delegation, cancellation, credential ownership, failure consistency and stored authorization.
- Files: AppState+Login.swift, AppState.swift account actions, ClaudeService.swift login/runner/switch/capture, CancelableProcess.swift, KeychainService.swift, AccountSwitcherView.swift.
- Read-only source review. No source/test/config changes, real credential reads, login, fault injection or network requests.
- Audit current behavior, including pre-existing defects; these are not claimed as regressions from the local CLI quota change.

## Findings
| Severity | Conf | Verified | File:Line | Issue | Suggestion |
|---|---|---|---|---|---|
| Critical / P1 | 99 | Fresh-context verifier confirmed | AppState+Login.swift:70; ClaudeService.swift:338 | A failed reauthentication to a different email leaves stale activeAccount; next login captures live B credentials under A UUID with no ownership check, replacing A backup. Unknown live identities are not cleared by AppState.swift:430. | Reconcile identity on every post-login exit; require expected account identity at capture boundary and refuse mismatch. |
| Critical / P1 | 99 | Fresh-context verifier confirmed | ClaudeService.swift:272; KeychainService.swift:114; AppState.swift:333 | Token delete/add and token/identity writes are not transactional. Add failure can remove current active token; identity-write failure leaves B token plus A identity; verification failure leaves UI stale. Source backup errors do not stop mutation. | Require preserved original state before mutation, update existing token in place, compensate both stores on failure and reconcile UI; surface rollback failure explicitly. |
| Non-critical / P2 | 100 | - | AppState.swift:194,221 | Add Current confirms CLI B but can keep A active, or returns on existing B without reconciling activity. | Always synchronize actual known identity after successful auth-status observation, including duplicates. |
| Non-critical / P2 | 99 | - | KeychainService.swift:79 | Legacy token-only file is deleted at initialization without preserving a recoverable copy or proving migration. | Preserve legacy data with restricted permissions; require explicit recovery/reauthentication when automatic mapping is impossible. |
| Non-critical / P2 | 95 | - | KeychainService.swift:328 | Failed deletion of migrated plaintext backups is swallowed; logging claims it was removed and future reads no longer revisit cleanup. | Surface cleanup failure and retain explicit pending cleanup state; do not misreport removal. |

### Filtered by Verification
- Do not claim token loss is always permanent: a successfully saved backup can recover it. Loss of the only usable copy requires missing/stale/failed backup.
- Cancellation itself is not the confirmed stale-identity trigger: CancellationError already reconciles local identity. Mismatch and ordinary failure exits do not.
- No evidence that any user's backup is currently corrupted; all findings are source-level reachable failure paths.

## Validation Results
| Method | Result | Details |
|---|---|---|
| Independent login-state review | Needs changes | Confirmed stale identity, unvalidated capture and Add Current inconsistency. |
| Independent credential-storage review | Needs changes | Confirmed partial writes, delete/add risk, ignored backup failures and legacy migration issues. |
| Fresh-context ownership verification | Confirmed 99% | A reauthenticates as unknown B, then Login New overwrites A backup before second browser login begins. |
| Fresh-context switch verification | Confirmed 99% | Token write followed by failed identity write lacks compensation; retry can compound mixed credentials. |
| Existing offline reports inspected | Previously passing, limited scope | Login URL success/cancel/bad URL/early failure and eight process/cancellation checks passed before this audit. No new tests run or authored in review mode; keychain fault paths are not established as covered. |
| Network boundary read | Confirmed | login invokes official CLI auth login; getAuthStatus invokes auth status. App does not implement OAuth code exchange or token refresh HTTP. |

## Normal Flow and Limits
- UI starts a guarded login; CLI's BROWSER points to a temporary URL capture helper (0700 directory/helper, restrictive umask). User copies the URL; the CLI owns authorization and localhost callback.
- On success, app runs CLI auth status, reads the CLI token and local oauthAccount, saves per-account backups into its own macOS Keychain item, then updates UI metadata.
- Cancellation cancels the owned login task, terminates/reaps the child, escalates to SIGKILL if needed, and reconciles current local identity. It does not revoke completed authorization or promise to restore the previous login.
- Cancel control ends when performBrowserLogin returns; later auth-status verification/capture has no equivalent cancel handle or runner timeout. Do not describe cancellation as covering every finalization step.
- Account switching restores saved credentials locally; it is not another browser OAuth login. Explicit operations may run official CLI verification.

## Conclusion
- Assessment: Needs changes.
- Priority: first guard credential ownership and reconcile every login outcome; next make credential switching compensatable and stop on backup failure. Repair Add Current activity synchronization and legacy-data cleanup afterward.
- No implementation or local installed application changed by this review.
