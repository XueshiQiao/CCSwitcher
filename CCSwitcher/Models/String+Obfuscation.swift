import Foundation

extension String {
    /// Masks a string that is KNOWN to be an email address. No pattern
    /// matching happens — the string is split at its last "@" — so quoted
    /// local parts (`"user"@x.com`), non-ASCII addresses (用户@example.com),
    /// punycode TLDs (`example.xn--p1ai`) and domain literals
    /// (`user@[192.0.2.1]`) all mask correctly. Detection and masking are
    /// deliberately separate jobs: use this when the field IS an address,
    /// and `obfuscatedEmail()` when an address may be embedded in free text.
    ///
    /// Anything unusual on the domain side masks entirely — hiding more than
    /// necessary is always the safe direction for a privacy toggle.
    func maskedAsEmailAddress() -> String {
        guard let at = lastIndex(of: "@"), at != startIndex else { return self }
        let local = String(self[..<at])
        let domain = String(self[index(after: at)...])

        let visibleCount = max(1, min(3, local.count))
        let visible = local.prefix(visibleCount)

        // Domain literals ([192.0.2.1]) and dotless/degenerate domains: mask fully.
        if domain.hasPrefix("[") { return "\(visible)*@*" }
        guard let dot = domain.lastIndex(of: "."),
              dot != domain.startIndex,
              domain.index(after: dot) != domain.endIndex else {
            return "\(visible)*@*"
        }
        return "\(visible)*@*.\(domain[domain.index(after: dot)...])"
    }

    /// Finds email addresses embedded in free text (org names, custom labels)
    /// and masks each via `maskedAsEmailAddress()`. Returns the string
    /// unchanged when nothing matches.
    ///
    /// The detector is deliberately conservative: the TLD class is
    /// letters-only, because free text is full of email-shaped non-emails —
    /// `package@1.20.30` (a version string in an org name) must NOT be
    /// mangled by the mask. The cost is that exotic addresses (punycode TLD,
    /// quoted local part, domain literal) go unmasked when embedded in free
    /// text; the account's own email field never takes this path, so those
    /// forms still mask on every email-labeled surface.
    func obfuscatedEmail() -> String {
        let emailRegex = "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}.-]+\\.[\\p{L}]{2,64}"
        do {
            let regex = try NSRegularExpression(pattern: emailRegex, options: .caseInsensitive)
            let nsString = self as NSString
            let results = regex.matches(in: self, options: [], range: NSRange(location: 0, length: nsString.length))

            guard !results.isEmpty else { return self }

            var modifiedString = self
            // Replace from the end to the beginning so ranges remain valid.
            // `result.range` is an NSRange (UTF-16 offsets); it must be converted
            // with `Range(_:in:)`, never fed to `String.index(_:offsetBy:)`, which
            // counts grapheme clusters — any emoji or non-ASCII text before the
            // match would shift the range and trap on out-of-bounds.
            for result in results.reversed() {
                let matchedEmail = nsString.substring(with: result.range)
                let obfuscated = matchedEmail.maskedAsEmailAddress()

                guard let range = Range(result.range, in: modifiedString) else { continue }
                modifiedString.replaceSubrange(range, with: obfuscated)
            }
            return modifiedString
        } catch {
            return self
        }
    }
}
