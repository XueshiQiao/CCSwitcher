# FIX -- Independent account refresh controls and copyable login URL

## Status: done
## Task: 003
## Related: 002
## Baseline Commit: ed09ce518ab409f26781b7273c912370053ef0ed

## Problem
One account's cooldown or in-flight request disabled other accounts. Background quota refresh needed per-account opt-in. Login needed a copyable URL instead of opening a browser automatically.

## Resolution
- Track in-flight requests and persistent deadlines by account UUID. Ignore the obsolete global deadline.
- Preserve the minimum 15-minute per-account attempt interval and the complete server Retry-After deadline. This reduces polling; it does not guarantee protection from account restrictions.
- Store per-account automatic-refresh opt-ins, default off. Background cycles select at most one enabled, due account; manual refresh remains available independently.
- Capture the CLI's actual browser URL with a per-invocation BROWSER helper. Preserve the localhost callback and PKCE flow; do not use the manual-code fallback printed to stdout.
- Restrict the temporary directory/file to 0700/0600 and remove them on completion or cancellation.

## Verification
- Offline usage checks passed: independent accounts, duplicate requests, error responses, Retry-After variants and persisted deadlines.
- AppState checks passed: saved switches, disabled automatic refresh, manual refresh, cancellation and URL cleanup.
- Fake CLI URL checks passed: success, cancellation, invalid URL and early failure.
- Read-only inspection of the installed Claude CLI 2.1.289 confirmed BROWSER support and the distinction between automatic-callback and manual-code URLs.
- Release build, signature, strings and diff checks passed; independent review approved.
- No real login or quota requests were used for validation.
