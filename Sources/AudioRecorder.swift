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
    // Cold-starting AVAudioEngine measured 372ms, paid on every keypress before the first
    // sample lands — that is the missing first word. Staying warm for a minute covers a
    // run of consecutive dictations and still releases the mic when the desk is empty.
    // 0 = release immediately (no pre-roll)  ·  .infinity = never release
    private let warmIdleSeconds: TimeInterval = 60

    // Whisper requires 16kHz mono
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    /// Hardware rate the current `converter` was built for. If the device moves off it,
    /// both the engine and the converter are stale.
    private var converterInputRate: Double = 0
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
        // A long-lived engine can be stopped underneath us: when the input device changes
        // sample rate (headset connects, another app grabs it, a call starts) AVAudioEngine
        // stops and the converter — built for the old rate — becomes wrong too. The old
        // one-engine-per-recording code got this healing for free; this has to do it itself.
        if let engine = audioEngine {
            let hz = engine.inputNode.inputFormat(forBus: 0).sampleRate
            if engine.isRunning && hz == converterInputRate { return true }
            DebugLog.log("♻️ engine stale (running=\(engine.isRunning) hw=\(hz)Hz vs converter \(converterInputRate)Hz) — rebuilding")
            stopEngine()
        }

        let t0 = CFAbsoluteTimeGetCurrent()
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
        self.converterInputRate = inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // AVAudioFile has no close(); it writes its header when ARC deallocs it. Reading
            // the `audioFile` property here retains+autoreleases it, and this thread's pool
            // drains at an unpredictable time — so without an explicit pool the file outlives
            // stopRecording() and ships to the STT with a header claiming 0 bytes of audio.
            autoreleasepool { self?.processBuffer(buffer) }
        }

        do {
            try engine.start()
            audioEngine = engine
            // Device reconfigured → drop the engine so the next press rebuilds it.
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                // A Bluetooth headset flips from A2DP (44.1 kHz, no mic) to HFP (16 kHz mono)
                // the moment the mic is opened, which stops the engine and invalidates the
                // converter built for the old rate. But this notification also fires for
                // changes that cost us nothing, and rebuilding mid-take drops ~300 ms of
                // audio — so only rebuild when the engine is actually broken.
                let hz = engine.inputNode.inputFormat(forBus: 0).sampleRate
                guard !engine.isRunning || hz != self.converterInputRate else {
                    DebugLog.log("♻️ device reconfigured but engine still valid (\(hz)Hz) — keeping it")
                    return
                }
                self.lock.lock(); let busy = self.capturing; self.lock.unlock()
                DebugLog.log("♻️ device reconfigured (running=\(engine.isRunning) \(hz)Hz vs \(self.converterInputRate)Hz, recording=\(busy)) — rebuilding")
                // `audioFile` and `capturing` live outside the engine, so a take in progress
                // keeps writing to the same file across the rebuild.
                self.stopEngine()
                self.startEngine()
            }
            DebugLog.log("🎙️ engine started in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms · hw in \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch \(inputFormat.commonFormat.rawValue)")
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
        if let engine = audioEngine {
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: engine)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        converter = nil
        converterInputRate = 0
        lock.lock(); preRoll.removeAll(); lock.unlock()
        DebugLog.log("🎙️ mic released")
    }

    /// Start the mic now. Called at launch: the input device reconfigures itself the moment
    /// it is first opened (measured ~180 ms after engine start), and if that lands mid-
    /// recording the engine stops and the take is lost. Doing it at launch gets it over with,
    /// and gives the very first dictation a pre-roll too.
    func warmUp() {
        guard warmIdleSeconds > 0 else { return }
        startEngine()
        scheduleIdleStop()
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
        DebugLog.log("▶️ start · pre-roll \(preRollCount * 1000 / 16_000)ms · engineRunning=\(audioEngine?.isRunning ?? false) · hwNow=\(audioEngine?.inputNode.inputFormat(forBus: 0).sampleRate ?? -1)Hz")
    }

    func stopRecording() {
        lock.lock()
        capturing = false
        audioFile = nil                 // dropping the last reference finalises the WAV header
        preRoll.removeAll(keepingCapacity: true)
        lock.unlock()

        isRecording = false
        DispatchQueue.main.async { self.level = 0 }

        if let url = tempFileURL {
            if let w = DebugLog.wavPeak(url) {
                DebugLog.log("⏹ stop · \(w.bytes)B · \(w.frames) frames = \(w.frames * 1000 / 16_000)ms · peak \(String(format: "%.4f", w.peak))\(w.peak < 0.001 ? "  ⚠️ SILENT" : "")")
            } else {
                DebugLog.log("⏹ stop · ⚠️ WAV unreadable or empty at \(url.path)")
            }
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


// MARK: - Record self-test
// Verifies the whole capture path (engine → converter → tap → WAV) without a hotkey press:
//   open --env WHISPER_RECORD_TEST=1 Whisper.app
// Deliberately an environment variable, not a marker file: a file in ~/.whisperapp could be
// planted by anything with write access to the home directory, which would turn a diagnostic
// into a way to make the app record audio on next launch.
extension AudioRecorder {
    static var recordTestRequested: Bool {
        ProcessInfo.processInfo.environment["WHISPER_RECORD_TEST"] != nil
    }

    /// Instance method on purpose: driving a second AudioRecorder would open a second engine
    /// on the same device and the two reconfigure each other mid-take.
    func runRecordTest(seconds: Double = 3.0, then done: @escaping () -> Void) {
        let r = self
        DebugLog.log("🧪 record test: warming up, then \(seconds)s")
        r.warmUp()                       // real usage warms at launch; let the device settle
        Thread.sleep(forTimeInterval: 2.0)
        r.startRecording()
        guard r.isRecording else { DebugLog.log("🧪 FAILED: startRecording() did not start"); done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            r.stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let url = r.recordedFileURL, let w = DebugLog.wavPeak(url) {
                    let ms = w.frames * 1000 / 16_000
                    let want = Int(seconds * 1000)
                    let ok = ms > want * 3 / 4 && w.peak > 0.0005
                    DebugLog.log("🧪 \(ok ? "PASS" : "FAILED"): wanted ~\(want)ms, got \(ms)ms, peak \(String(format: "%.4f", w.peak))")
                } else {
                    DebugLog.log("🧪 FAILED: no WAV produced")
                }
                // The diagnostic must not leave a recording of the room sitting in /tmp.
                if let url = r.recordedFileURL { try? FileManager.default.removeItem(at: url) }
                done()
            }
        }
    }
}
