import Foundation
import CryptoKit

private let log = FileLog("Anchor")

/// Who the credential currently sitting in the keychain actually belongs to.
enum LiveCredentialOwner: Equatable {
    /// The live credential is known to be this account's.
    case owned(UUID)
    /// The live credential belongs to `credential`, but `~/.claude.json` names
    /// someone else. Usage still attributes to `credential` — that is the token
    /// every API call is billed against — while the identity block is wrong.
    case desynced(claimed: UUID?, credential: UUID)
    /// No credential, or nothing left tying it to a known account.
    case unknown

    /// The account the live credential belongs to, if that is knowable at all.
    var credentialAccountId: UUID? {
        switch self {
        case .owned(let id): return id
        case .desynced(_, let id): return id
        case .unknown: return nil
        }
    }
}

/// Tracks which account the live keychain credential belongs to.
///
/// The obvious answer — `~/.claude.json`'s identity block — is not trustworthy:
/// every running Claude Code session rewrites that block from its own cached
/// profile, so it can name account B seconds after a switch while the keychain
/// still holds account A's token. Everything downstream then misfiles A as B:
/// A's usage reading lands on B's card, and the next switch backs A's token up
/// as B's stored credential, permanently swapping the two accounts.
///
/// So pair the account with a fingerprint of the credential instead, taken at
/// the one moment the two halves are known to agree: when CCSwitcher itself
/// wrote them. An unchanged fingerprint proves the credential did not change,
/// whatever the identity block now claims.
///
/// Residual ambiguity, deliberately left: if the credential rotates in the same
/// window as an identity change, a local check cannot tell an external login
/// from a desync, and the identity block is believed. Rotation without a
/// matching identity change is the common case and stays anchored.
final class CredentialAnchorStore {
    private struct Anchor: Codable {
        var accountId: UUID
        var fingerprint: String
        /// Set once the identity block has been seen disagreeing with a
        /// credential that did not change. Sticky on purpose: clearing it on the
        /// next rotation would let the desync resume misfiling the moment the
        /// token rolls, which is exactly how the original swap went unnoticed.
        var isDesynced: Bool
    }

    private let defaults: UserDefaults
    private let key = "com.ccswitcher.credentialAnchor"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Hash rather than the token itself: this lands in UserDefaults, which is
    /// not a credential store.
    static func fingerprint(of accessToken: String) -> String {
        SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Record that `accountId` owns the live credential.
    ///
    /// Call this only where CCSwitcher established the pairing itself — a
    /// switch, a login, a re-authentication — never from something the identity
    /// block merely asserts. This is also the only way out of a desync.
    func anchor(accountId: UUID, accessToken: String) {
        let anchor = Anchor(accountId: accountId, fingerprint: Self.fingerprint(of: accessToken), isDesynced: false)
        save(anchor)
        log.info("[anchor] Live credential anchored to \(accountId) (\(short(anchor.fingerprint)))")
    }

    /// Drop the anchor if it points at `accountId` (the account was removed).
    func forget(accountId: UUID) {
        guard let stored = load(), stored.accountId == accountId else { return }
        defaults.removeObject(forKey: key)
        log.info("[anchor] Dropped anchor for removed account \(accountId)")
    }

    /// Resolve who the live credential belongs to.
    ///
    /// - Parameters:
    ///   - accessToken: the access token currently in the keychain, if any.
    ///   - claimedAccountId: the account `~/.claude.json` says is signed in.
    func resolveOwner(accessToken: String?, claimedAccountId: UUID?) -> LiveCredentialOwner {
        guard let accessToken else { return .unknown }
        let fingerprint = Self.fingerprint(of: accessToken)

        guard var stored = load() else {
            // Nothing anchored yet (first run, or the account was re-added):
            // the identity block is all there is to go on.
            guard let claimedAccountId else { return .unknown }
            save(Anchor(accountId: claimedAccountId, fingerprint: fingerprint, isDesynced: false))
            return .owned(claimedAccountId)
        }

        if stored.fingerprint == fingerprint {
            // The credential has not moved since it was anchored, so it still
            // belongs to the anchored account no matter what the file says.
            if stored.isDesynced {
                return .desynced(claimed: claimedAccountId, credential: stored.accountId)
            }
            if let claimedAccountId, claimedAccountId != stored.accountId {
                stored.isDesynced = true
                save(stored)
                log.warning("[anchor] Identity block flipped to \(claimedAccountId) while the credential stayed \(stored.accountId)'s")
                return .desynced(claimed: claimedAccountId, credential: stored.accountId)
            }
            return .owned(stored.accountId)
        }

        // The credential itself changed.
        if stored.isDesynced {
            // It rolled while the identity block was already untrustworthy, so
            // nothing ties it to an account any more. Only a CCSwitcher-performed
            // write can re-establish the pairing.
            stored.fingerprint = fingerprint
            save(stored)
            log.warning("[anchor] Credential rotated while desynced; owner is now unknown")
            return .unknown
        }

        // Ordinary rotation by a running Claude Code session, or a login done
        // outside CCSwitcher: the identity block moved with the credential.
        guard let claimedAccountId else { return .unknown }
        save(Anchor(accountId: claimedAccountId, fingerprint: fingerprint, isDesynced: false))
        return .owned(claimedAccountId)
    }

    // MARK: - Persistence

    private func load() -> Anchor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: data)
    }

    private func save(_ anchor: Anchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        defaults.set(data, forKey: key)
    }

    private func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix(8))
    }
}
