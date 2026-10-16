# PLAN -- Cancel login and refresh individual account usage

## Status: done
## Task: 002
## Related: 001
## Baseline Commit: ed09ce518ab409f26781b7273c912370053ef0ed

## Goal
Make new-account login and reauthentication cancellable, and allow explicit per-account quota refresh without switching accounts.

## Final Decisions
- Own each CLI invocation with a cancellable process wrapper, drain both streams, terminate/reap on cancellation, and handle inherited pipes.
- Keep credential mutations serialized until cancellation completes. Reconcile local identity without capturing unknown credentials or rolling back completed browser authorization.
- Prevent implicit account discovery after cancellation until an explicit add or completed login; allow recovery by switching from an unknown active identity.
- Keep local statistics refreshing independently of quota requests. Auto-switch uses recent saved quota samples rather than extra verification requests.
- Preserve previous successful samples and their timestamps on failures.
- Initial shared cooldown/request controls were replaced by independent account controls in task 003.

## Verification
- `uv run python3 Tools/check_process_pipes.py`: large-output and cancellation regressions passed.
- `uv run python3 Tools/check_usage_requests.py`: offline HTTP and cooldown persistence checks passed.
- `uv run python3 Tools/check_account_actions.py`: real AppState with fake CLI, credential and filesystem boundaries passed.
- Release build, signature verification, strings validation and independent review passed.
- No real login, account switching or usage API requests were used as tests. Checks remain local, not CI jobs.
