import Foundation
import AVFoundation

/// Append-only diagnostic log at ~/.whisperapp/debug.log — the app is a menu-bar
/// LSUIElement, so print() goes nowhere a user can reach.
enum DebugLog {
    private static let lock = NSLock()
    private static var path: String { KeyStore.dir + "/debug.log" }
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// The log lives next to the API keys, so it gets the same 0600 the keys get, and it
    /// is capped — an append-only file on a dictation app that runs all day grows forever.
    private static let maxBytes = 512 * 1024

    private static func fileSize(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    }

    static func log(_ msg: String) {
        print(msg)
        let line = "[\(stamp.string(from: Date()))] \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: KeyStore.dir, withIntermediateDirectories: true)
        guard let data = line.data(using: .utf8) else { return }

        let size = fileSize(path)
        if size > maxBytes {
            // Keep the newest half: a truncated tail beats losing the run in progress.
            if let old = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                let kept = old.suffix(maxBytes / 2)
                let header = "[log trimmed at \(stamp.string(from: Date()))]\n".data(using: .utf8) ?? Data()
                try? (header + kept).write(to: URL(fileURLWithPath: path))
            }
        }

        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Read the WAV back through AVAudioFile rather than assuming a 44-byte header —
    /// AVAudioFile writes a JUNK padding chunk, and parsing past it by hand reported the
    /// padding as 126 ms of loud audio in a file that actually held nothing.
    static func wavPeak(_ url: URL) -> (bytes: Int, frames: Int, peak: Float)? {
        let bytes = fileSize(url.path)
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let n = AVAudioFrameCount(f.length)
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n),
              (try? f.read(into: buf)) != nil else { return (bytes, 0, 0) }
        var peak: Float = 0
        if let ch = buf.floatChannelData {
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[0][i])) }
        } else if let ch = buf.int16ChannelData {
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(Float(ch[0][i]) / 32767)) }
        }
        return (bytes, Int(buf.frameLength), peak)
    }
}
