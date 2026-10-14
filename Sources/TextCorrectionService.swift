import Foundation

/// Send raw transcription text to LLM (cloud) to fix typos, punctuation, and sentence structure.
/// Supports multiple providers (DeepSeek, OpenAI, Groq, OpenRouter, Gemini, Anthropic, Custom)
/// via LLMSettings — see LLMProvider.swift
class TextCorrectionService: ObservableObject {
    @Published var isEnabled = true
    @Published var isCorrecting = false

    private var provider: LLMProvider { LLMSettings.current }
    private var apiKey: String? { LLMSettings.key(for: provider) }

    var isAvailable: Bool { apiKey != nil }

    func correct(text: String, language: String, completion: @escaping (String?) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        let p = provider
        guard let key = LLMSettings.key(for: p) else {
            print("❌ No key found for \(p.name) (configure in Settings or set env \(p.envKey))")
            completion(nil); return
        }

        let langHint: String
        if language == "auto" {
            langHint = "The text may be in any language — keep the original language"
        } else if let name = Languages.find(language)?.name {
            langHint = "The text is in \(name)"
        } else {
            langHint = "The text may be in any language — keep the original language"
        }

        // Minimal-edit only. The old prompt also asked for punctuation and readability,
        // which the model took as licence to rephrase; this one was tested on Thai and
        // code-switched takes and changed at most 1.4% of characters, never for the worse.
        var systemPrompt = """
        You fix speech-recognition errors in a dictation that may mix in English words.
        Change ONLY words that are clearly misheard — a word that is not a real word, or one that makes no sense in context — into the similar-sounding word the speaker meant.
        Keep every other character exactly as given: wording, order, spacing, numbers, particles (ครับ/ค่ะ/นะ/นึง), and English words in English letters.
        Do not rephrase, reorder, add, remove, translate, or tidy anything. When unsure, leave it unchanged.
        Output only the text.
        \(langHint)
        """

        // User's own known corrections — helps with proper nouns / brand names the model
        // wouldn't otherwise know. (A deterministic pass also runs before paste, so exact
        // matches always land even if the model ignores this.)
        let hint = CorrectionDictionary.shared.hintForPrompt
        if !hint.isEmpty {
            systemPrompt += "\n\nThe user's own known corrections for their speech — apply these where the meaning matches:\n" + hint
        }

        let endpoint = LLMSettings.endpoint(for: p)
        let model = LLMSettings.model(for: p)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any]
        switch p.style {
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var openAIBody: [String: Any] = [
                "model": model,
                "temperature": 0,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": text],
                ],
            ]
            // Reasoning models think before answering: on Groq that is 1–7 s for a one-line
            // fix (gpt-oss measured), so turn it off where the model allows it.
            if model.hasPrefix("qwen/") { openAIBody["reasoning_effort"] = "none" }
            if model.hasPrefix("openai/gpt-oss") { openAIBody["reasoning_effort"] = "low" }
            body = openAIBody
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var anthropicBody: [String: Any] = [
                "model": model,
                "max_tokens": 8192,
                "temperature": 0.2,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": text],
                ],
            ]
            // GLM-5 enables thinking by default → disable for fast text correction
            if model.lowercased().contains("glm") {
                anthropicBody["thinking"] = ["type": "disabled"]
            }
            body = anthropicBody
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil); return
        }
        req.httpBody = httpBody

        DispatchQueue.main.async { self.isCorrecting = true }

        let style = p.style
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.isCorrecting = false }

            if let error = error {
                print("❌ Correction error: \(error.localizedDescription)")
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("❌ Correction: could not parse response")
                completion(nil); return
            }

            let content = Self.extractText(from: json, style: style)
            guard let raw = content else {
                print("❌ Correction response: \(json)")
                completion(nil); return
            }

            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !cleaned.isEmpty else { completion(nil); return }
            // A fix touches a word or two. Past this much change the model has rewritten the
            // sentence, and the user's own words beat its version — keep the original.
            let changed = Self.changeRatio(text, cleaned)
            let kept = changed <= Self.maxChange
            DebugLog.log(String(format: "✨ correction changed %.1f%% → %@", changed * 100,
                                kept ? "applied" : "rejected, kept original"))
            completion(kept ? cleaned : nil)
        }.resume()
    }

    static let maxChange = 0.15

    /// Edit distance over the longer length, whitespace ignored. Counted in code points, not
    /// Characters: Swift folds "ตั้" into one Character, so a dropped tone mark would cost
    /// as much as a whole wrong consonant cluster.
    static func changeRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars.filter { !$0.properties.isWhitespace })
        let y = Array(b.unicodeScalars.filter { !$0.properties.isWhitespace })
        if x.isEmpty || y.isEmpty { return x.count == y.count ? 0 : 1 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diag = row[0]; row[0] = i
            for j in 1...y.count {
                let up = row[j]
                row[j] = min(up + 1, row[j - 1] + 1, diag + (x[i - 1] == y[j - 1] ? 0 : 1))
                diag = up
            }
        }
        return Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// Extract text from the response based on the provider's API style
    private static func extractText(from json: [String: Any], style: LLMProvider.Style) -> String? {
        switch style {
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return content
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        }
    }
}
