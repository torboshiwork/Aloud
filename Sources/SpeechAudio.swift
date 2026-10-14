import Foundation
import AVFoundation

/// Decides whether a take holds speech, and squeezes out the silence before it is uploaded.
///
/// Whisper never answers "nothing was said": handed silence it writes a sentence anyway.
/// Measured on Groq: 1 s of room noise came back as "โอเค" three times out of three, and
/// 42 of 352 real takes with no speech in them all pasted text. Its own `no_speech_prob`
/// for that second was 0.509 — under the 0.6 it would need to discard it — so the check
/// has to happen here, on the samples, before anything is sent.
///
/// The same trick inside a take: a long pause mid-sentence is a stretch of silence the
/// model can fill with invented words. Pauses are cut down to `maxGap`, never removed, so
/// the words either side stay separate.
enum SpeechAudio {
    struct Prepared {
        let wav: Data
        let voicedSeconds: Double
        let totalSeconds: Double
    }

    private static let rate = 16_000
    private static let frame = 320                       // 20 ms
    /// Quietest frame that can count as voice: −44 dBFS. A real dictation in the log peaks
    /// around 0.26; the silent takes peaked under 0.04, and only for a click or two.
    private static let minVoiceRMS: Float = 0.006
    /// Less voice than this is a key click or a breath, not a word.
    private static let minVoicedSeconds = 0.25
    /// Audio kept on each side of voice. Soft onsets ("ส", "ฟ") sit under the threshold,
    /// so this is what keeps the first consonant; it also caps every pause at 2×pad.
    private static let padFrames = 15                    // 300 ms → pauses capped at 600 ms

    /// nil = no speech in the take (or the file could not be read).
    static func prepare(_ url: URL) -> Prepared? {
        guard let file = try? AVAudioFile(forReading: url),
              Int(file.fileFormat.sampleRate) == rate,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData?[0] else { return nil }
        let n = Int(buf.frameLength)
        let frames = n / frame
        guard frames > 0 else { return nil }

        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for i in f * frame ..< (f + 1) * frame { sum += ch[i] * ch[i] }
            rms[f] = (sum / Float(frame)).squareRoot()
        }
        // Relative to this take's own floor, so a fan or an air-con doesn't read as voice.
        let floor = rms.sorted()[frames / 10]
        let threshold = max(minVoiceRMS, floor * 3)
        let voiced = rms.map { $0 > threshold }
        let voicedSeconds = Double(voiced.filter { $0 }.count * frame) / Double(rate)
        let totalSeconds = Double(n) / Double(rate)

        guard voicedSeconds >= minVoicedSeconds else {
            DebugLog.log(String(format: "🔈 voiced %.2fs of %.2fs · floor %.4f — no speech",
                                voicedSeconds, totalSeconds, floor))
            return nil
        }

        // Keep a frame when voice is within padFrames of it.
        var keep = [Bool](repeating: false, count: frames)
        for f in 0..<frames where voiced[f] {
            for k in max(0, f - padFrames)...min(frames - 1, f + padFrames) { keep[k] = true }
        }
        // Quiet takes are brought up to a normal level. Measured: speech peaking at 0.05 with
        // the vocabulary prompt lost its first word ("พรุ่งนี้" → "ต้องมี"); the same audio
        // at 0.5 came back right twice. Gain only goes up, and at most 10×, so a quiet room
        // isn't turned into a loud one.
        var peak: Float = 0
        for f in 0..<frames where keep[f] {
            for i in f * frame ..< (f + 1) * frame { peak = max(peak, abs(ch[i])) }
        }
        let gain = peak > 0 ? min(10, max(1, 0.5 / peak)) : 1

        var pcm = Data(capacity: n * 2)
        for f in 0..<frames where keep[f] {
            for i in f * frame ..< (f + 1) * frame {
                var s = Int16(max(-1, min(1, ch[i] * gain)) * 32767).littleEndian
                withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
            }
        }
        DebugLog.log(String(format: "🔈 voiced %.2fs of %.2fs · sent %.2fs · gain %.1f×",
                            voicedSeconds, totalSeconds, Double(pcm.count) / 32_000, gain))
        return Prepared(wav: wavHeader(dataBytes: pcm.count) + pcm,
                        voicedSeconds: voicedSeconds, totalSeconds: totalSeconds)
    }

    private static func wavHeader(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
