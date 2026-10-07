# FIX -- Compact quota cards

## Status: done
## Task: 006
## Related: 005
## Baseline Commit: 1c48c06

## Problem
Quota cards contain too many separate rows and repeated labels.

## Root Cause
CCSwitcher/Views/UsageDashboardView.swift:225 — provider header, reset labels, disabled extra usage, sample age and refresh controls each consume separate vertical space.

## Fix Plan
- [x] UsageDashboardView.swift — put email and badges in one wrapping header, reset labels beside quota labels, and sample age beside compact refresh controls; hide disabled extra usage.
- [x] Localizable.strings — shorter automatic-refresh label and explicit used-percentage wording.
- [x] CountdownLabel.swift — append whole days for reset intervals of at least 24 hours, retaining precise hours/minutes.
- Read-only investigation: current quota display uses saved OAuth usage snapshots; no live usage requests were sent. Request policy is unchanged.

## Verification
- [x] Compile Release and validate localization/diff.
- [x] Render real views with offline fake accounts; inspect Chinese light/dark layout and long-email/error cases.
- [x] Apply diff-guard to changed lines; preserve all refresh guards and account behavior.
- [x] Backup, install and verify the local application.

## Results
- Release 66.6 build, localization validation, git diff --check and existing offline countdown checks passed.
- Real SwiftUI fixture images checked in Chinese light/dark, including parenthesized days, explicit used percentage, long emails and error/unknown states. Independent visual review found no layout issues.
- Diff guard found no issues in the incremental UI diff; no request or persistence logic changed.
- Installed 66.6, verified its signature and binary equality with the build, and confirmed the app process is running.
- Backup: /Applications/.CCSwitcher-before-compact-quota-20261008.app.
- No live account quota requests were made for verification; no commit or push performed.
