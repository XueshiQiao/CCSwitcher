# PLAN -- Persist usage and inspect saved account authorization

## Status: done
## Task: 004
## Related: 003
## Baseline Commit: ed09ce518ab409f26781b7273c912370053ef0ed

## Goal
Restore successful quota readings after restart, expose a read-only authorization viewer from account editing, and copy full email addresses independently of display masking.

## Final Decisions
- Store the complete Codable quota response and its original sample time in a per-account UserDefaults snapshot. Restore without a network request; preserve the snapshot after failures and remove it when deleting the account.
- Missing snapshots represent accounts without saved readings. Corrupt snapshots produce an explicit error rather than fabricated empty usage.
- The account editor preserves label editing. Expanding the authorization section reads only the selected account's saved backup, with no fallback to live CLI credentials.
- Disable legacy-store migration for the viewer: valid legacy files are read without writing or removing them; unreadable files report unavailability without renaming them.
- Show authorization JSON only after expansion. Do not log or export credentials.
- Reuse a full-email copy button in the usage card, account list and editor. Each receives the original email regardless of masking. Full-email display itself uses the existing application preference.

## Verification
- `uv run python3 Tools/check_account_actions.py` passed existing state regressions and a three-process save/fail/restore sequence, including complete response fields, original sample time, deletion, absent/corrupt cache and no network requests on restore.
- `uv run python3 Tools/check_stored_authorization.py` passed selected-account JSON fidelity, missing/unavailable states, no live fallback and real legacy-store read behavior against isolated filesystem/keychain boundaries.
- Legacy checks preserved file bytes, paths, directory contents and modification times; any keychain write failed the test. Symbol inspection confirmed no real home/keychain calls were linked into the fixture.
- Independent review, final macOS arm64 Release build, ad-hoc signature, strings validation and diff checks passed. Local installation started and completed statistics refresh.
- No real credentials or quota API calls were used for tests. Native editor interaction was not exercised against real credentials.
- Readings that existed only in the prior application's memory cannot be recovered; successful refreshes in this version begin persistent storage.
