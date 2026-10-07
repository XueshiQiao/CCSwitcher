# FIX -- Stop bundling the unused legacy collector

## Status: done
## Task: 017
## Related: 009
## Baseline Commit: 1c48c06

## Problem
The app reads the official CLI cache, but project.yml still embeds the previous standalone collector. Upstream's release signing process does not sign that extra binary with Developer ID.

## Root Cause
An obsolete tool target and post-build copy remain after switching quota sources.

## Fix Plan
- [x] Remove the unused tool target, dependency and embedding script; leave CI unchanged.
- [x] Retain standalone tool sources and uninstall support. Require an explicit helper for legacy installation.
- [x] Ignore Python bytecode rather than publishing generated files.

## Verification
- [x] Run the existing offline regression checks, including standalone install/uninstall.
- [x] Build a fresh Release app and verify its signature and executable contents.
- [x] Independent review and diff/localization checks.

- All nine offline regression scripts passed; standalone install/uninstall was rechecked after the explicit helper change.
- Fresh arm64 Release build passed; signature verified and legacy helper absent. Existing CI and release version settings unchanged.
