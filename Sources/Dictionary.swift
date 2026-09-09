import Foundation

/// User-maintained find→replace dictionary for words the STT keeps mis-transcribing.
///
/// Backed by a plain-text file at `~/.whisperapp/dictionary.txt`:
///
///     # one rule per line:  wrong -> right      (# = comment)
///     เกมส์ -> Game
///     gamezxz -> Gamezxz
///     บิทคอย -> Bitcoin
///
/// Used two ways:
///  - `hintForPrompt`: appended to the LLM correction system prompt so it knows the
///    user's own terms (handles fuzzy/garbled cases the deterministic pass can't).
///  - `apply(to:)`:    deterministic phrase replace as the final pass before paste,
///    guaranteeing the user's certain corrections always land — even with correction off.
///
/// Matching rules:
///  - `from` is pure ASCII  → `\b`-bounded, case-insensitive regex (English proper nouns).
///  - `from` has non-ASCII  → exact substring, case-sensitive (Thai has no word boundaries).
/// Rules apply in file order.
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private struct Rule { let from: String; let to: String; let isASCII: Bool }

    private static var path: String { KeyStore.dir + "/dictionary.txt" }

    private var rules: [Rule] = []
    private var lastMtime: Date? = nil
    private let lock = NSLock()

    private init() { reload(force: true) }

    // MARK: - Loading (reloads only when the file's mtime changes)

    private func reload(force: Bool) {
        let path = Self.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date
        if !force, mtime == lastMtime { return }
        lastMtime = mtime

        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // Same 0600 as the key files: it holds the user's own vocabulary — client names,
        // internal jargon — and had been left world-readable at 0644.
        if !raw.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        rules = Self.parse(raw)
    }

    private static func parse(_ raw: String) -> [Rule] {
        var out: [Rule] = []
        out.reserveCapacity(64)
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let arrow = trimmed.range(of: "->") else { continue }
            let from = String(trimmed[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let to   = String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            if from.isEmpty || to.isEmpty { continue }
            let isASCII = from.unicodeScalars.allSatisfy { $0.isASCII }
            out.append(Rule(from: from, to: to, isASCII: isASCII))
        }
        return out
    }

    private func snapshot() -> [Rule] {
        lock.lock(); reload(force: false); let r = rules; lock.unlock()
        return r
    }

    // MARK: - Public

    /// Deterministic replacement applied to the final text before paste.
    func apply(to text: String) -> String {
        let active = snapshot()
        guard !active.isEmpty else { return text }
        var result = text
        for r in active {
            if r.isASCII {
                // word-boundary, case-insensitive (escape both pattern & replacement template)
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: r.from) + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let template = NSRegularExpression.escapedTemplate(for: r.to)
                result = re.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            } else {
                // Thai / mixed: exact substring, case-sensitive
                result = result.replacingOccurrences(of: r.from, with: r.to)
            }
        }
        return result
    }

    /// Hint appended to the LLM correction prompt. Empty string when there are no rules.
    var hintForPrompt: String {
        let active = snapshot()
        guard !active.isEmpty else { return "" }
        return active.map { "- \($0.from) → \($0.to)" }.joined(separator: "\n")
    }

    /// The correct spellings (the `to` side), deduped, in file order — sent to the STT so it
    /// can produce these words in the first place. `apply(to:)` only repairs what the STT
    /// already got close to; a word it never heard can't be pattern-matched back.
    var sttBiasTerms: [String] {
        var seen = Set<String>()
        return snapshot().compactMap { seen.insert($0.to).inserted ? $0.to : nil }
    }
}
