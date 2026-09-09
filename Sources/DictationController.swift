import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import ApplicationServices

/// Visual processing stage — drives the floating status overlay
enum Stage: Equatable {
    case idle
    case recording
    case transcribing
    case correcting
    case done(String)
    case error(String)
}

/// Orchestrates everything: record → transcribe (cloud/local) → correct (LLM) → paste into focused app
class DictationController: ObservableObject {
    @Published var isRecording = false
    @Published var status = ""
    @Published var stage: Stage = .idle
    @Published var useCloudSTT = true
    /// Off by default: it adds ~2 s on a long dictation, and the models available for it
    /// rewrite phrasing rather than just fixing words. Toggle it in the menu bar.
    @Published var useCorrection = false
    @Published var language = "th"

    let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cloud = CloudTranscriptionService()
    private let correction = TextCorrectionService()
    private var processing = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        recorder.$recordedFileURL
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.handleAudio(url) }
            .store(in: &cancellables)
    }

    func toggle() { recorder.isRecording ? stop() : start() }

    func start() {
        guard !processing, !recorder.isRecording else { return }
        recorder.startRecording()
        isRecording = recorder.isRecording
        if isRecording {
            status = "Listening…"
            stage = .recording
        } else {
            status = "❌ Microphone unavailable"
            stage = .error("Microphone unavailable")
        }
    }

    func stop() {
        guard recorder.isRecording else { return }
        recorder.stopRecording()
        isRecording = false
        status = "⏳ Processing…"
        stage = .transcribing
    }

    private func handleAudio(_ url: URL) {
        processing = true
        let lang = language

        let finishOnMain: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // แม้ correction ปิดอยู่ หรือ LLM มองข้ามคำเฉพาะ ก็ให้ dictionary เป็นเจ้าบทบาทสุดท้าย
                let final = CorrectionDictionary.shared.apply(to: text)
                let snippet = String(final.prefix(28))
                self.status = "✅ " + snippet
                self.stage = .done(snippet)
                self.processing = false
                Paster.paste(final)
                // กลับเป็น idle หลังโชว์สักครู่
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self = self else { return }
                    if self.stage == .done(snippet) { self.stage = .idle }
                }
            }
        }

        let afterSTT: (String?) -> Void = { [weak self] result in
            guard let self = self else { return }
            // ลบคำบรรยายเสียง/เหตุการณ์ที่ STT เติมมา เช่น (เสียงลม) (wind) [background noise]
            let text = (result.map { self.stripSoundAnnotations($0) }) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // An API failure is not silence — say which one it was.
                let why = self.useCloudSTT ? (self.cloud.lastFailure.map { "STT failed (\($0))" } ?? "No audio detected") : "No audio detected"
                DebugLog.log("⚠️ empty result → \(why)")
                DispatchQueue.main.async {
                    self.status = "⚠️ " + why
                    self.stage = .error(why)
                    self.processing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        if case .error = self?.stage { self?.stage = .idle }
                    }
                }
                return
            }
            if self.useCorrection {
                DispatchQueue.main.async {
                    self.status = "✨ AI correction…"
                    self.stage = .correcting
                }
                self.correction.correct(text: text, language: lang) { corrected in
                    finishOnMain(corrected ?? text)
                }
            } else {
                finishOnMain(text)
            }
        }

        DispatchQueue.main.async {
            self.status = self.useCloudSTT ? "☁️ Transcribing…" : "📝 Transcribing…"
            self.stage = .transcribing
        }

        if useCloudSTT {
            cloud.transcribe(fileURL: url, language: lang) { result in
                try? FileManager.default.removeItem(at: url)
                afterSTT(result)
            }
        } else {
            whisper.language = lang
            whisper.transcribe(fileURL: url) { result in afterSTT(result) }
        }
    }

    /// Sound/event tags the STT inserts — (เสียงลม) [applause] *laughs*.
    /// Only removes a bracketed group whose contents actually read as one of those: the old
    /// version stripped every bracket, so dictating "(สำคัญ)" silently lost the word.
    private static let annotationWord = try! NSRegularExpression(
        pattern: "เสียง|ดนตรี|หัวเราะ|ไอ|จาม|เงียบ|ปรบมือ|laugh|applaus|music|noise|silen|blank|"
               + "inaudible|cough|sigh|sneez|wind|typing|breath|throat|static|beep|crosstalk",
        options: [.caseInsensitive])

    private func stripSoundAnnotations(_ text: String) -> String {
        var result = text
        let patterns = [
            "\\(([^\\)]*)\\)",   // ( ... )   ASCII
            "（([^）]*)）",              // （ ... ） fullwidth
            "\\[([^\\]]*)\\]",   // [ ... ]
            "【([^】]*)】",              // 【 ... 】
            "\\*([^*]*)\\*",        // * ... *
            "‹([^›]*)›",
            "«([^»]*)»",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            var out = ""
            var last = result.startIndex
            for m in re.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
                guard let whole = Range(m.range, in: result),
                      let inner = Range(m.range(at: 1), in: result) else { continue }
                let content = String(result[inner])
                let isAnnotation = Self.annotationWord.firstMatch(
                    in: content, range: NSRange(content.startIndex..., in: content)) != nil
                out += result[last..<whole.lowerBound]
                if !isAnnotation { out += result[whole] }   // real speech — keep it
                else { out += " " }
                last = whole.upperBound
            }
            out += result[last...]
            result = out
        }
        return result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Copy text to clipboard and simulate ⌘V into the focused app (requires Accessibility permission)
enum Paster {
    private static var didPrompt = false

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // ไม่มีสิทธิ์ Accessibility → เก็บใน clipboard เงียบๆ ผู้ใช้กด ⌘V เอง
        // (ห้ามเด้ง dialog ตรงนี้ จะวนระหว่าง transcribe ไม่หยุด)
        guard AXIsProcessTrusted() else { return }

        // Small delay to ensure clipboard is set before simulating keystroke
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// ถามสิทธิ์ Accessibility แค่ครั้งเดียวต่อ session (เรียกตอนเปิดแอป)
    static func promptAccessibilityOnce() {
        guard !didPrompt, !AXIsProcessTrusted() else { return }
        didPrompt = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - Self-check
// WHISPER_SELFCHECK=1 Whisper.app/Contents/MacOS/WhisperApp
extension DictationController {
    static func selfCheckAnnotations() {
        let c = DictationController()
        func eq(_ input: String, _ want: String, _ note: String) {
            let got = c.stripSoundAnnotations(input)
            assert(got == want, "\(note): \(input) → '\(got)', wanted '\(want)'")
        }
        // Removed: the STT's own sound tags.
        eq("(เสียงลม) สวัสดีครับ", "สวัสดีครับ", "thai sound tag")
        eq("[applause] hello there", "hello there", "bracket tag")
        eq("*laughs* okay", "okay", "asterisk tag")
        eq("test [BLANK_AUDIO] done", "test done", "blank audio")
        // Kept: bracketed words the user actually dictated. The old strip-everything
        // version failed all three of these by silently deleting the content.
        eq("ราคา (สำคัญ) มาก", "ราคา (สำคัญ) มาก", "real parenthetical")
        eq("ดูข้อ [3] ด้วย", "ดูข้อ [3] ด้วย", "real bracket")
        eq("ค่า (x + y) เท่าไหร่", "ค่า (x + y) เท่าไหร่", "real formula")
        print("✅ stripSoundAnnotations self-check passed (4 tags removed, 3 real parentheticals kept)")
    }
}
