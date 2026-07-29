import Foundation

/// Pure, UI-agnostic auto-switch decision logic.
///
/// Mirrors the proven design in `claude-swap` (threshold + hysteresis): when the
/// active account's *binding window* (the higher of its 5h / weekly utilization)
/// reaches the configured threshold, pick the same-provider account with the most
/// quota left — but only one that sits at least `hysteresisPct` below the threshold,
/// so two accounts hovering at the line never ping-pong. All guardrails that need
/// state (cooldown, re-entrancy) live in `AppState`; this stays a pure function.
enum AutoSwitchEngine {

    /// The binding utilization for an account = max of the windows we watch.
    /// We watch the 5-hour (session) and 7-day (weekly-all) windows — the two
    /// that the `/api/oauth/usage` endpoint still populates as top-level fields.
    /// Returns nil when we have no usage sample for the account.
    static func bindingUtilization(_ usage: UsageAPIResponse?) -> Double? {
        guard let usage else { return nil }
        let windows = [usage.fiveHour?.utilization, usage.sevenDay?.utilization]
        return windows.compactMap { $0 }.max()
    }

    /// Decide whether to switch, and to which account.
    ///
    /// - Parameters:
    ///   - active: the currently active account.
    ///   - candidates: every other account (already filtered to the same provider).
    ///   - usageByAccount: latest usage sample per account id.
    ///   - isSwitchable: whether an account can actually be switched to right now
    ///     (has a stored backup token and isn't flagged expired).
    ///   - threshold: switch when the active binding utilization is >= this (e.g. 90).
    ///   - hysteresisPct: a candidate must sit at least this far below the threshold
    ///     to be eligible (e.g. 10 -> candidate must be <= threshold - 10).
    /// - Returns: the best account to switch to, or nil to stay put.
    static func chooseTarget(
        active: Account,
        candidates: [Account],
        usageByAccount: [UUID: UsageAPIResponse],
        isSwitchable: (Account) -> Bool,
        threshold: Double,
        hysteresisPct: Double
    ) -> Account? {
        // 1) Only act once the active account has reached the threshold on a
        //    window we watch. Unknown active usage -> do nothing (can't decide).
        guard let activeUtil = bindingUtilization(usageByAccount[active.id]),
              activeUtil >= threshold else {
            return nil
        }

        // 2) Keep only switchable candidates that sit safely below the threshold.
        //    Unknown-usage candidates are allowed as a failover fallback (they may
        //    simply not have been sampled yet), but they sort last (see step 3).
        let ceiling = threshold - hysteresisPct
        let viable = candidates.filter { candidate in
            guard candidate.id != active.id, isSwitchable(candidate) else { return false }
            guard let util = bindingUtilization(usageByAccount[candidate.id]) else { return true }
            return util <= ceiling
        }

        // 3) Prefer the account with the most headroom (lowest known utilization);
        //    accounts with no usage sample sort last as a fallback.
        return viable.min { lhs, rhs in
            let lhsUtil = bindingUtilization(usageByAccount[lhs.id]) ?? .greatestFiniteMagnitude
            let rhsUtil = bindingUtilization(usageByAccount[rhs.id]) ?? .greatestFiniteMagnitude
            return lhsUtil < rhsUtil
        }
    }
}
