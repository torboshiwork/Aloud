import Foundation
import AVFoundation

/// Transcribe audio via cloud STT — supports multiple providers (ElevenLabs Scribe / OpenAI / Groq / Custom)
/// via STTSettings — see STTProvider.swift
class CloudTranscriptionService {
    /// Why the last transcribe returned nil — an API failure must not read as silence.
    /// Set on a URLSession thread and read by the caller, so it goes through a lock rather
    /// than being a bare `var` two threads happen not to touch at once today.
    private let failureLock = NSLock()
    private var _lastFailure: String?
    private(set) var lastFailure: String? {
        get { failureLock.lock(); defer { failureLock.unlock() }; return _lastFailure }
        set { failureLock.lock(); _lastFailure = newValue; failureLock.unlock() }
    }

    /// Groq accepts 25 MB on the free tier; at 16 kHz mono Int16 (32 kB/s) that is ~13 min.
    /// Stop below it rather than spending the upload to be told no.
    private static let maxBytes = 24 * 1024 * 1024
    /// Below this a take is a mis-press, and the API answers "audio_too_short" anyway.
    private static let minSeconds = 0.3

    private var provider: STTProvider { STTSettings.current }

    /// `lastFailure` when the take held no speech — the caller shows this differently from
    /// an API failure, because nothing went wrong.
    static let noSpeech = "no speech"

    /// English words from recent results, newest first. Sent back as vocabulary so the next
    /// take spells them the same way. Words only, never sentences: a prompt sentence that
    /// matches what is then said makes Whisper skip that stretch of audio as already
    /// transcribed — measured, it dropped half a take. Memory only; nothing is written to disk.
    private var recentEnglish: [String] = []
    private let recentLock = NSLock()

    /// Telling Whisper up front that the speech mixes in English is what keeps English words
    /// in English letters. Measured on a code-switched sentence: "deadline / project /
    /// meeting" came back as "เด็ดไลน์ / พระเจ็ด / มีทิ้ง" without it, and correct with it,
    /// while the six pure-Thai test sentences came back identical either way.
    private static let mixedLanguageCue = "ภาษาไทยปนคำอังกฤษ: email, website, design, LINE, Google, ไฟล์"

    private func vocabularyPrompt() -> String {
        recentLock.lock(); let recent = recentEnglish; recentLock.unlock()
        var seen = Set<String>()
        // Dictionary first: those are the user's own words and must survive the cut.
        let terms = (CorrectionDictionary.shared.sttBiasTerms + recent)
            .filter { seen.insert($0.lowercased()).inserted }
        let line = terms.isEmpty ? Self.mixedLanguageCue
                                 : Self.mixedLanguageCue + ", " + terms.joined(separator: ", ")
        // Whisper's prompt caps at 224 tokens; 300 chars stays under it even for Thai.
        return String(line.prefix(300))
    }

    private func remember(_ text: String) {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { $0.count >= 3 && $0.unicodeScalars.allSatisfy { $0.isASCII } }
        guard !words.isEmpty else { return }
        recentLock.lock()
        for w in words.reversed() {
            recentEnglish.removeAll { $0.caseInsensitiveCompare(w) == .orderedSame }
            recentEnglish.insert(w, at: 0)
        }
        recentEnglish = Array(recentEnglish.prefix(30))
        recentLock.unlock()
    }

    /// verbose_json carries per-segment confidence; keep only segments that read as speech.
    /// Thresholds are Whisper's own: it discards a segment with no_speech_prob > 0.6 and
    /// avg_logprob < -1, and treats compression_ratio > 2.4 as a repetition loop.
    /// Plain `{ "text": ... }` (ElevenLabs, or a server without segments) passes through.
    static func keptText(_ json: [String: Any]) -> String? {
        guard let segments = json["segments"] as? [[String: Any]], !segments.isEmpty else {
            return (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var dropped = 0
        let kept = segments.filter { seg in
            let noSpeech = seg["no_speech_prob"] as? Double ?? 0
            let logprob = seg["avg_logprob"] as? Double ?? 0
            let ratio = seg["compression_ratio"] as? Double ?? 0
            let invented = (noSpeech > 0.6 && logprob < -1) || ratio > 2.4
            if invented { dropped += 1 }
            return !invented
        }
        DebugLog.log("🧩 \(segments.count) segments · dropped \(dropped)")
        // Segments end where the speaker paused, which in Thai is where a space goes —
        // Groq's own `text` glues them ("2 โมงตอนนี้เว็บไซต์").
        return kept.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        guard let audio = SpeechAudio.prepare(fileURL) else {
            lastFailure = Self.noSpeech
            DebugLog.log("🔇 no speech — not uploaded")
            completion(nil); return
        }
        send(audio: audio, language: language, usePrompt: true, retriesLeft: 1) { [weak self] text in
            if let text = text { self?.remember(text) }
            completion(text)
        }
    }

    private func send(audio: SpeechAudio.Prepared, language: String, usePrompt: Bool, retriesLeft: Int,
                      completion: @escaping (String?) -> Void) {
        let p = provider
        guard let key = STTSettings.key(for: p) else {
            print("❌ No key found for \(p.name) (configure in Settings or set env \(p.envKey))")
            completion(nil); return
        }
        guard let endpoint = STTSettings.endpoint(for: p) else {
            print("❌ Invalid endpoint for \(p.name)")
            completion(nil); return
        }
        let fileData = audio.wav
        let seconds = Double(fileData.count - 44) / 32_000
        guard seconds >= Self.minSeconds else {
            lastFailure = String(format: "too short (%.2fs)", seconds)
            DebugLog.log("⏭ skipped upload: \(String(format: "%.2f", seconds))s < \(Self.minSeconds)s")
            completion(nil); return
        }
        guard fileData.count <= Self.maxBytes else {
            lastFailure = "too long (\(Int(seconds / 60)) min — limit is about 13)"
            DebugLog.log("⏭ skipped upload: \(fileData.count / 1024 / 1024)MB over the \(Self.maxBytes / 1024 / 1024)MB limit")
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

        // ponytail: openAI-style only. ElevenLabs has `keyterms` (up to 1000 terms) but its
        // multipart serialization is undocumented — verify before sending, a 422 kills the call.
        if p.style == .openAI {
            if usePrompt { field("prompt", vocabularyPrompt()) }
            field("temperature", "0")
            // Per-segment confidence, so invented segments can be dropped below.
            field("response_format", "verbose_json")
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
        DebugLog.log("☁️ POST \(endpoint.host ?? "?") model=\(model) lang=\(langCode(language, style: p.style) ?? "auto") prompt=\(usePrompt && p.style == .openAI) body=\(body.count)B")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // A dropped connection or a rate limit is worth one more try; a 4xx is not —
            // the request itself is wrong and resending only burns another second.
            let transient = error != nil || code == 429 || (500...599).contains(code)
            if transient, retriesLeft > 0 {
                DebugLog.log("↻ retrying after \(error.map { "network: \($0.localizedDescription)" } ?? "HTTP \(code)")")
                self?.send(audio: audio, language: language, usePrompt: usePrompt,
                           retriesLeft: retriesLeft - 1, completion: completion)
                return
            }
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
            guard let text = Self.keptText(json) else {
                self?.lastFailure = "no text field in response"
                completion(nil); return
            }
            // A prompt that happens to match what was said can make Whisper skip that stretch
            // as already written. Real takes in the log run 6.7 chars per second at the 5th
            // percentile; the measured skip came in at 3.2. Under 4, ask again without it.
            let rate = Double(text.filter { !$0.isWhitespace }.count) / max(audio.voicedSeconds, 0.5)
            if usePrompt, p.style == .openAI, rate < 4, let self = self {
                DebugLog.log(String(format: "↻ %.1f chars/s looks like skipped audio — retrying without prompt", rate))
                self.send(audio: audio, language: language, usePrompt: false, retriesLeft: 0) { plain in
                    let best = [text, plain ?? ""].max { $0.count < $1.count } ?? text
                    completion(best.isEmpty ? nil : best)
                }
                return
            }
            completion(text.isEmpty ? nil : text)
        }.resume()
    }
}
