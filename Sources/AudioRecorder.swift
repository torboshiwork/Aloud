import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?
    @Published var level: Float = 0   // 0...1 real-time audio level for waveform

    /// Audio kept from *before* the hotkey press. `AVAudioEngine.start()` alone measured
    /// 580–790 ms on this Mac, and nothing is captured until it returns — so without a
    /// pre-roll the first syllable is never recorded at all, no matter how the user speaks.
    private let preRollFrames = 12_000                      // 0.75 s @ 16 kHz

    /// How long the mic — and the macOS mic indicator — stays on after a dictation.
    /// The pre-roll only exists while the engine is running, so this is the knob that
    /// decides whether the fix applies at all:
    ///   .infinity → mic stays on for the session after your first dictation (default)
    ///   180       → stays warm 3 min, then releases; a dictation after that clips again
    ///   0         → mic only on while recording; pre-roll disabled, old behaviour
    private let warmIdleSeconds: TimeInterval = .infinity

    // Whisper requires 16kHz mono
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var idleTimer: Timer?
    private var tempFileURL: URL?

    // Written from the audio thread — guarded by `lock`.
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var capturing = false
    private var preRoll: [Int16] = []

    // MARK: - Engine lifecycle (deliberately outlives a single recording)

    /// Starts the mic if it isn't already running. Safe to call repeatedly.
    @discardableResult
    private func startEngine() -> Bool {
        if audioEngine != nil { return true }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Use actual hardware format (never guess — tap would get silent buffers otherwise)
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            print("❌ Invalid input format (sampleRate = 0) — microphone permission may not be granted")
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("❌ Cannot create AVAudioConverter: \(inputFormat) → \(targetFormat)")
            return false
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            print("🎙️ Mic warm [in: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch]")
            return true
        } catch {
            print("❌ Failed to start engine: \(error)")
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            return false
        }
    }

    private func stopEngine() {
        idleTimer?.invalidate(); idleTimer = nil
        guard audioEngine != nil else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        lock.lock(); preRoll.removeAll(); lock.unlock()
        print("🎙️ Mic released")
    }

    /// Release the mic after `warmIdleSeconds` of no dictation.
    private func scheduleIdleStop() {
        idleTimer?.invalidate(); idleTimer = nil
        guard warmIdleSeconds.isFinite else { return }      // .infinity → stay warm
        guard warmIdleSeconds > 0 else { stopEngine(); return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: warmIdleSeconds, repeats: false) { [weak self] _ in
            self?.stopEngine()
        }
    }

    // MARK: - Recording

    func startRecording() {
        idleTimer?.invalidate(); idleTimer = nil
        guard startEngine() else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: tempURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
        } catch {
            print("❌ Failed to create audio file: \(error)")
            return
        }
        tempFileURL = tempURL

        // Flush the pre-roll and arm the tap in one critical section, so a live buffer
        // can't land ahead of the pre-roll and scramble the order.
        lock.lock()
        let preRollCount = preRoll.count
        if let head = Self.makeBuffer(from: preRoll, format: targetFormat) {
            try? file.write(from: head)
        }
        preRoll.removeAll(keepingCapacity: true)
        audioFile = file
        capturing = true
        lock.unlock()

        isRecording = true
        print("✅ Recording started → \(tempURL.lastPathComponent) [pre-roll \(preRollCount * 1000 / 16_000) ms]")
    }

    func stopRecording() {
        lock.lock()
        capturing = false
        audioFile = nil                 // closing the last reference finalises the WAV header
        preRoll.removeAll(keepingCapacity: true)
        lock.unlock()

        isRecording = false
        DispatchQueue.main.async { self.level = 0 }

        if let url = tempFileURL {
            print("✅ Recording stopped → \(url.path)")
            DispatchQueue.main.async { self.recordedFileURL = url }
        }
        tempFileURL = nil

        scheduleIdleStop()              // keep the mic warm so the *next* press has a pre-roll
    }

    // MARK: - Audio thread

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        // Calculate output frame count based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outFrameCapacity
        ) else { return }

        var fedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            fedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            print("❌ Convert error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard outBuffer.frameLength > 0 else { return }

        lock.lock()
        let isCapturing = capturing
        if isCapturing, let file = audioFile {
            do { try file.write(from: outBuffer) }
            catch { print("❌ Write buffer error: \(error)") }
        } else {
            appendPreRollLocked(outBuffer)
        }
        lock.unlock()

        // Waveform level — only while recording, so the overlay doesn't dance to room
        // noise while the mic is merely warm.
        guard isCapturing, let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        let p = ch[0]
        for i in 0..<n { sum += p[i] * p[i] }
        let lvl = min(1, (sum / Float(n)).squareRoot() * 8)   // scale for visibility
        DispatchQueue.main.async { self.level = lvl }
    }

    /// Keep only the most recent `preRollFrames` samples. Caller holds `lock`.
    /// ponytail: O(n) trim of a 12 000-sample (24 KB) array ~10×/s — free at this size.
    /// Switch to a circular index only if the pre-roll ever grows to whole seconds.
    private func appendPreRollLocked(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.int16ChannelData else { return }
        preRoll.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buf.frameLength)))
        if preRoll.count > preRollFrames {
            preRoll.removeFirst(preRoll.count - preRollFrames)
        }
    }

    private static func makeBuffer(from samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.int16ChannelData else { return nil }
        samples.withUnsafeBufferPointer { dst[0].update(from: $0.baseAddress!, count: samples.count) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return buf
    }
}

// MARK: - Self-check
// Runs without a microphone: `WHISPER_SELFCHECK=1 Whisper.app/Contents/MacOS/WhisperApp`
// Guards the two things that would silently corrupt a recording: the ring keeping the
// *newest* 0.75 s (not the oldest), and the pre-roll surviving the copy into the file.
extension AudioRecorder {
    static func selfCheck() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                channels: 1, interleaved: false)!
        let r = AudioRecorder()

        func chunk(_ start: Int, _ count: Int) -> AVAudioPCMBuffer {
            makeBuffer(from: (start..<(start + count)).map { Int16(truncatingIfNeeded: $0) }, format: fmt)!
        }

        // 3 × 8 000 frames = 24 000 in, ring caps at 12 000 and must hold the LAST ones.
        r.lock.lock()
        for i in 0..<3 { r.appendPreRollLocked(chunk(i * 8_000, 8_000)) }
        let ring = r.preRoll
        r.lock.unlock()
        assert(ring.count == 12_000, "ring should cap at 12 000, got \(ring.count)")
        assert(ring.first == Int16(truncatingIfNeeded: 12_000), "ring kept the oldest samples, not the newest")
        assert(ring.last == Int16(truncatingIfNeeded: 23_999), "ring lost the newest sample")

        // Round-trip into the buffer that gets written to the WAV.
        let buf = makeBuffer(from: ring, format: fmt)!
        assert(buf.frameLength == 12_000, "frameLength not set")
        assert(buf.int16ChannelData![0][0] == ring[0], "first sample corrupted")
        assert(buf.int16ChannelData![0][11_999] == ring[11_999], "last sample corrupted")

        // Empty ring must not produce a zero-length buffer for the file writer.
        assert(makeBuffer(from: [], format: fmt) == nil, "empty ring should yield nil, not an empty buffer")

        print("✅ AudioRecorder self-check passed (ring 12 000 frames = 750 ms, newest-first, round-trip clean)")
    }
}
