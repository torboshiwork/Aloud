import Foundation

/// Transcribe audio via cloud STT — supports multiple providers (ElevenLabs Scribe / OpenAI / Groq / Custom)
/// via STTSettings — see STTProvider.swift
class CloudTranscriptionService {
    /// Why the last transcribe returned nil — an API failure must not read as silence.
    private(set) var lastFailure: String?

    private var provider: STTProvider { STTSettings.current }

    var isAvailable: Bool { STTSettings.key(for: provider) != nil }

    /// Convert app language → language code based on provider style.
    /// - elevenlabs uses ISO 639-3 (tha/eng)  ·  openAI/Groq uses ISO 639-1 (th/en)
    /// - "auto" → nil (let the provider auto-detect)
    private func langCode(_ language: String, style: STTProvider.Style) -> String? {
        guard let lang = Languages.find(language) else { return nil }
        if lang.code == "auto" { return nil }
        return (style == .elevenlabs) ? lang.iso3 : lang.code
    }

    func transcribe(fileURL: URL, language: String, completion: @escaping (String?) -> Void) {
        let p = provider
        guard let key = STTSettings.key(for: p) else {
            print("❌ No key found for \(p.name) (configure in Settings or set env \(p.envKey))")
            completion(nil); return
        }
        guard let endpoint = STTSettings.endpoint(for: p) else {
            print("❌ Invalid endpoint for \(p.name)")
            completion(nil); return
        }
        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(nil); return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120

        // Auth header + field names vary by style
        switch p.style {
        case .elevenlabs:
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Field names differ: ElevenLabs = model_id/language_code, OpenAI-style = model/language
        let modelField = (p.style == .elevenlabs) ? "model_id" : "model"
        let langField  = (p.style == .elevenlabs) ? "language_code" : "language"

        field(modelField, STTSettings.model(for: p))
        if let lang = langCode(language, style: p.style) {
            field(langField, lang)
        }

        // Bias the decoder toward the user's own vocabulary (proper nouns, brand names).
        // Whisper's `prompt` caps at 224 tokens — 300 chars stays under that even for Thai,
        // and a term clipped mid-word is harmless in what is only conditioning context.
        // ponytail: openAI-style only. ElevenLabs has `keyterms` (up to 1000 terms) but its
        // multipart serialization is undocumented — verify before sending, a 422 kills the call.
        if p.style == .openAI {
            let terms = CorrectionDictionary.shared.sttBiasTerms.joined(separator: ", ")
            if !terms.isEmpty { field("prompt", String(terms.prefix(300))) }
        }

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        self.lastFailure = nil
        let model = STTSettings.model(for: p)
        DebugLog.log("☁️ POST \(endpoint.host ?? "?") model=\(model) lang=\(langCode(language, style: p.style) ?? "auto") body=\(body.count)B")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                self?.lastFailure = "network: \(error.localizedDescription)"
                DebugLog.log("❌ \(p.name) network error: \(error.localizedDescription)")
                completion(nil); return
            }
            // Never log the transcript itself — that is the user's speech sitting in a
            // plaintext file. Only failures print a body, and those carry an API error.
            if code == 200 {
                DebugLog.log("☁️ HTTP 200 · \(data?.count ?? 0)B transcript")
            } else {
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DebugLog.log("☁️ HTTP \(code) · \(bodyText.prefix(300))")
            }
            guard code == 200 else {
                self?.lastFailure = "HTTP \(code)"
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.lastFailure = "unparseable response"
                completion(nil); return
            }
            // Both styles return { "text": "..." }
            if let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(trimmed.isEmpty ? nil : trimmed)
            } else {
                self?.lastFailure = "no text field in response"
                completion(nil)
            }
        }.resume()
    }
}
