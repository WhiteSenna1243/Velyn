import AppKit
import CoreAudio
import AudioToolbox
import Accelerate

/// What the glow and the lyrics read every frame. All values are 0...1 and
/// auto-gained, so they behave the same at any system volume.
struct AudioSnapshot {
    var level: Float = 0        // overall loudness
    var bass: Float = 0         // ~30-150 Hz  (kick, bass)
    var lowMid: Float = 0       // ~150-500 Hz (snare body, vocals low)
    var mid: Float = 0          // ~500-2000 Hz
    var treble: Float = 0       // ~2-8 kHz    (hats, air)
    var beatPulse: Float = 0    // jumps to 1 on every beat, then decays (~150 ms)
    var beatCount: Int = 0      // increments on every beat: compare to your last value
    var hasSignal = false       // false when the system is silent (or access is blocked)
}

/// Listens to the Mac's system audio (never the microphone) with a Core Audio
/// "process tap" and turns it into band levels plus beat events.
///
/// Why a tap and not ScreenCaptureKit: a tap only needs the light
/// "System Audio Recording" permission. ScreenCaptureKit needs full Screen
/// Recording, which is the scary lock prompt that kept coming back.
final class AudioReactor: ObservableObject {
    enum Status { case off, listening, waiting, unavailable }

    @Published private(set) var status: Status = .off
    private(set) var isRunning = false

    // Shared with the audio queue.
    private let lock = NSLock()
    private var snap = AudioSnapshot()
    private var lastFrameUptime = 0.0
    private var lastSignalUptime = 0.0
    private var everHeardSignal = false

    // Core Audio objects.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "velyn.audio.tap", qos: .userInteractive)
    private var statusTimer: Timer?
    private var startFailed = false
    private var watching = false

    // Analysis (touched only on `queue`).
    private let n = 2048                       // FFT size
    private let hop = 512                      // new samples per analysis step (~10 ms)
    private let log2n: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var pending: [Float] = []
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var prevMags: [Float]
    private var sampleRate = 48000.0

    private var peakLevel: Float = 0.002
    private var peakBass: Float = 0.002
    private var peakLowMid: Float = 0.002
    private var peakMid: Float = 0.002
    private var peakTreble: Float = 0.002
    private var peakFlux: Float = 0.0005
    private var outLevel: Float = 0
    private var outBass: Float = 0
    private var outLowMid: Float = 0
    private var outMid: Float = 0
    private var outTreble: Float = 0
    private var pulse: Float = 0
    private var beats = 0
    private var fluxHistory: [Float] = []
    private var lastBeatUptime = 0.0

    init() {
        windowed = [Float](repeating: 0, count: 2048)
        real = [Float](repeating: 0, count: 1024)
        imag = [Float](repeating: 0, count: 1024)
        mags = [Float](repeating: 0, count: 1024)
        prevMags = [Float](repeating: 0, count: 1024)
        window = (0..<2048).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 2047) }
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Reading (main thread, every frame)

    func snapshot() -> AudioSnapshot {
        lock.lock()
        var s = snap
        let last = lastFrameUptime
        lock.unlock()
        if ProcessInfo.processInfo.systemUptime - last > 0.5 {
            s = AudioSnapshot()   // callbacks stopped: go dark instead of freezing
        }
        return s
    }

    // MARK: - Start / stop

    func start() {
        guard !isRunning else { return }
        guard let outUID = Self.defaultOutputUID() else {
            startFailed = true
            publishStatus()
            return
        }

        // 1. A global stereo tap on everything that plays (Velyn itself makes no sound).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "\(AppInfo.name) audio analysis"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else {
            NSLog("Velyn: could not create audio tap")
            startFailed = true
            publishStatus()
            return
        }
        tapID = tap

        // 2. A private aggregate device that carries the tap's audio to us.
        let aggUID = UUID().uuidString
        let subDevice: [String: Any] = [kAudioSubDeviceUIDKey: outUID]
        let subTap: [String: Any] = [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: desc.uuid.uuidString
        ]
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AppInfo.name) Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [subDevice],
            kAudioAggregateDeviceTapListKey: [subTap]
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else {
            NSLog("Velyn: could not create aggregate device")
            teardown()
            startFailed = true
            publishStatus()
            return
        }
        aggID = agg
        sampleRate = Self.nominalSampleRate(of: agg) ?? Self.tapSampleRate(of: tap) ?? 48000

        // 3. Read the audio on our own queue.
        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inData, _, _, _ in
            self?.consume(inData)
        }
        guard err == noErr, let proc else {
            NSLog("Velyn: could not create audio IO proc")
            teardown()
            startFailed = true
            publishStatus()
            return
        }
        procID = proc
        guard AudioDeviceStart(agg, proc) == noErr else {
            NSLog("Velyn: could not start audio device")
            teardown()
            startFailed = true
            publishStatus()
            return
        }

        startFailed = false
        isRunning = true
        watchOutputDevice()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.publishStatus()
        }
        publishStatus()
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
        statusTimer?.invalidate()
        statusTimer = nil
        lock.lock()
        snap = AudioSnapshot()
        lock.unlock()
        publishStatus()
    }

    private func teardown() {
        if aggID != AudioObjectID(kAudioObjectUnknown), let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        procID = nil
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Switching headphones / speakers: rebuild the tap on the new output.
    private func watchOutputDevice() {
        guard !watching else { return }
        watching = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.stop()
            self.start()
        }
    }

    private func publishStatus() {
        let next: Status
        if !isRunning {
            next = startFailed ? .unavailable : .off
        } else {
            lock.lock()
            let heard = ProcessInfo.processInfo.systemUptime - lastSignalUptime < 3 && everHeardSignal
            lock.unlock()
            next = heard ? .listening : .waiting
        }
        if next != status { status = next }
    }

    // MARK: - Device helpers

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 8000 else { return nil }
        return rate
    }

    private static func tapSampleRate(of tap: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 8000 else { return nil }
        return asbd.mSampleRate
    }

    // MARK: - Audio callback (runs on `queue`)

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return }

        var mono: [Float] = []
        if abl.count == 1 {
            // One buffer, channels interleaved (the usual case).
            let b = abl[0]
            guard let raw = b.mData else { return }
            let p = raw.assumingMemoryBound(to: Float.self)
            let ch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            mono.reserveCapacity(frames)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[i * ch + c] }
                mono.append(s / Float(ch))
            }
        } else {
            // One buffer per channel.
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            var used: Float = 0
            for b in abl {
                guard let raw = b.mData else { continue }
                let p = raw.assumingMemoryBound(to: Float.self)
                let cnt = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<cnt { mono[i] += p[i] }
                used += 1
            }
            if used > 1 { for i in 0..<frames { mono[i] /= used } }
        }

        pending.append(contentsOf: mono)
        while pending.count >= n {
            analyze()
            pending.removeFirst(hop)
        }
    }

    // MARK: - Analysis

    private func bin(_ hz: Double) -> Int {
        max(1, min(n / 2 - 1, Int(hz / (sampleRate / Double(n)))))
    }

    private func bandRMS(_ lo: Int, _ hi: Int) -> Float {
        guard hi > lo else { return 0 }
        var sum: Float = 0
        for k in lo..<hi { sum += mags[k] * mags[k] }
        return (sum / Float(hi - lo)).squareRoot()
    }

    /// Auto-gain: track a slowly falling peak so 0...1 always spans the song's own dynamics.
    private func normalise(_ v: Float, peak: inout Float, decay: Float, floor: Float) -> Float {
        peak = max(v, peak * decay, floor)
        return min(1, v / peak)
    }

    private func analyze() {
        guard let setup = fftSetup else { return }
        let dt = Double(hop) / sampleRate
        let now = ProcessInfo.processInfo.systemUptime

        // Window the newest `n` samples and run the FFT.
        var rms: Float = 0
        for i in 0..<n {
            let s = pending[i]
            rms += s * s
            windowed[i] = s * window[i]
        }
        rms = (rms / Float(n)).squareRoot()
        let silent = rms < 0.0003

        windowed.withUnsafeBufferPointer { wp in
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
        let scale = 1 / Float(n)
        for k in 1..<(n / 2) {
            mags[k] = (real[k] * real[k] + imag[k] * imag[k]).squareRoot() * scale
        }

        // Per-band energy.
        let eBass = bandRMS(bin(30), bin(150))
        let eLowMid = bandRMS(bin(150), bin(500))
        let eMid = bandRMS(bin(500), bin(2000))
        let eTreble = bandRMS(bin(2000), bin(8000))
        let eAll = bandRMS(bin(30), bin(8000))

        // Onset strength: how much new low-frequency energy appeared since the last step.
        var flux: Float = 0
        let fluxLo = bin(40)
        let fluxHi = max(fluxLo + 1, bin(250))
        for k in fluxLo..<fluxHi { flux += max(0, mags[k] - prevMags[k]) }
        prevMags = mags

        let slow = Float(pow(0.5, dt / 3.0))        // peak half-life 3 s
        var level: Float = 0, bass: Float = 0, lowMid: Float = 0, mid: Float = 0, treble: Float = 0
        var beatNow = false

        if !silent {
            level = normalise(eAll, peak: &peakLevel, decay: slow, floor: 0.0015)
            bass = normalise(eBass, peak: &peakBass, decay: slow, floor: 0.0015)
            lowMid = normalise(eLowMid, peak: &peakLowMid, decay: slow, floor: 0.001)
            mid = normalise(eMid, peak: &peakMid, decay: slow, floor: 0.0008)
            treble = normalise(eTreble, peak: &peakTreble, decay: slow, floor: 0.0004)
            // A little contrast so quiet parts are really calmer than loud ones.
            level = powf(level, 1.4); bass = powf(bass, 1.4)
            lowMid = powf(lowMid, 1.4); mid = powf(mid, 1.4); treble = powf(treble, 1.4)

            let fluxN = normalise(flux, peak: &peakFlux, decay: slow, floor: 0.0004)
            fluxHistory.append(fluxN)
            if fluxHistory.count > 90 { fluxHistory.removeFirst() }
            let mean = fluxHistory.reduce(0, +) / Float(fluxHistory.count)
            var variance: Float = 0
            for v in fluxHistory { variance += (v - mean) * (v - mean) }
            let sd = (variance / Float(fluxHistory.count)).squareRoot()
            let threshold = max(0.30, mean + 1.3 * sd)
            if fluxN > threshold, now - lastBeatUptime > 0.20, fluxHistory.count > 20 {
                beatNow = true
                lastBeatUptime = now
            }
        } else {
            fluxHistory.removeAll(keepingCapacity: true)
        }

        // Fast attack, smooth release: lights snap on, then ease off.
        func follow(_ out: inout Float, _ target: Float, halfLife: Double) {
            if target > out { out = target } else { out *= Float(pow(0.5, dt / halfLife)) }
        }
        follow(&outLevel, level, halfLife: 0.16)
        follow(&outBass, bass, halfLife: 0.12)
        follow(&outLowMid, lowMid, halfLife: 0.12)
        follow(&outMid, mid, halfLife: 0.10)
        follow(&outTreble, treble, halfLife: 0.08)

        pulse *= Float(pow(0.5, dt / 0.15))
        if beatNow {
            pulse = 1
            beats += 1
        }

        lock.lock()
        snap.level = outLevel
        snap.bass = outBass
        snap.lowMid = outLowMid
        snap.mid = outMid
        snap.treble = outTreble
        snap.beatPulse = pulse
        snap.beatCount = beats
        snap.hasSignal = !silent
        lastFrameUptime = now
        if !silent {
            lastSignalUptime = now
            everHeardSignal = true
        }
        lock.unlock()
    }
}
