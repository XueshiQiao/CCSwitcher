# FIX -- Process output pipe deadlock

## Status: done
## Task: 001
## Related: N/A
## Baseline Commit: ed09ce518ab409f26781b7273c912370053ef0ed

## Problem
CCSwitcher becomes unresponsive while reading Claude credentials or running the CLI.

## Root Cause
KeychainService.runSecurity waited for process exit before draining stdout. A captured main-thread stack waited in runSecurity while the security child blocked flushing stdout. ClaudeService.runClaude had the same ordering. Two bounded discovery/version probes also sent unused stderr to unread pipes.

## Resolution
- Drain output before waiting for process exit, including unsuccessful exits.
- Route unused probe stderr to nullDevice while retaining probe deadlines.
- Exercise real ClaudeService against fake CLI processes with output larger than pipe capacity.

## Verification
- Baseline: large stdout/stderr requests timed out; the noisy version probe returned nil.
- Local check: `uv run python3 Tools/check_process_pipes.py` passed.
- macOS arm64 Release build and ad-hoc signature verification passed.
- The installed repair completed refresh and returned to the normal AppKit event loop; Activity Monitor no longer reported it as unresponsive.
- Existing synchronous keychain prompts and bounded stdout probe behavior remain outside this fix.
