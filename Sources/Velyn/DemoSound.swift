#if DEBUG
import Foundation
import AVFoundation

/// Dev aid: the demo video's soundtrack, synthesised here from scratch (no samples, nothing copyrighted).
/// 112 BPM in C (Fmaj7 · G · Am7 · Em7). It shares DemoVideo's beat grid, so the kick lands on every glow
/// pulse, and a soft lead plays one note per lyric word at the moment the word lights up.
///   .build/debug/Velyn --demo-sound out.m4a              audio only
///   .build/debug/Velyn --demo-sound out.mp4 silent.mp4   new soundtrack on an already rendered picture
///   .build/debug/Velyn --demo-check out.mp4              tracks, levels and kick timing of a finished video
enum DemoSound {
    struct Note { var time, length: Double; var line, word, count: Int; var last: Bool }
    struct Cues {
        var length: Double
        var drop: Double                            // drums in (a downbeat)
        var outro: Double                           // drums out, final chord
        var cuts: [Double] = []                     // soft swishes
        var phones: Double?                         // whoosh as the phones slide up
        var pop: Double?                            // the settings panel dropping in
        var chimes: [Double] = []                   // the logo appearing
        var notes: [Note] = []                      // one per lyric word
    }

    static let sr = 44100.0
    static let beat = 60.0 / 112.0                 // must match DemoVideo.beat

    // Pad voicing (MIDI), bass note, melody chord tones (pitch classes).
    private static let chords: [(pad: [Int], bass: Int, tones: [Int])] = [
        ([53, 57, 60, 64], 41, [5, 9, 0, 4]),       // Fmaj7
        ([55, 59, 62, 67], 43, [7, 11, 2]),         // G
        ([57, 60, 64, 67], 45, [9, 0, 4, 7]),       // Am7
        ([52, 55, 59, 62], 40, [4, 7, 11, 2])       // Em7
    ]
    private static let endChord = [48, 55, 60, 62, 64, 67]   // Cadd9
    private static let pentatonic = [0, 2, 4, 7, 9]

    // MARK: Make

    /// Renders the soundtrack for `cues`, writes it as AAC and puts it on `silent` -> `out`.
    static func make(out: URL, silent: URL?, cues: Cues) {
        let (l, r) = render(cues)
        let m4a = silent == nil ? out : out.deletingPathExtension().appendingPathExtension("m4a")
        guard write(l, r, to: m4a) else { print("couldn't write \(m4a.path)"); return }
        print("audio: \(m4a.path)")
        guard let silent else { return }
        if mux(video: silent, audio: m4a, out: out) {
            try? FileManager.default.removeItem(at: m4a)
            print("video: \(out.path)")
            check(out, cues: cues)
        } else { print("mux failed") }
    }

    // MARK: Synth

    private struct Rng {
        var s: UInt32
        mutating func next() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s >> 8) / Double(1 << 23) - 1 }
    }

    /// Zero-delay state-variable filter (lowpass, bandpass, highpass at once).
    private struct SVF {
        var ic1 = 0.0, ic2 = 0.0
        mutating func run(_ x: Double, _ cutoff: Double, q: Double = 0.7) -> (lp: Double, bp: Double, hp: Double) {
            let g = tan(.pi * min(max(cutoff, 20), sr * 0.45) / sr), k = 1 / q
            let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
            let v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
            return (v2, v1, x - k * v1 - v2)
        }
    }

    private static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    /// Mixes stems into one stereo pair. Each stem is measured on its own, so levels can be checked without ears.
    private final class Mix {
        let n: Int
        var L: [Float], R: [Float], sL: [Float], sR: [Float]
        var verb: [Float], echo: [Float]
        var levels: [(String, Double)] = []
        let window: Range<Int>
        init(_ n: Int, window: Range<Int>) {
            self.n = n; self.window = window
            L = [Float](repeating: 0, count: n); R = L; sL = L; sR = L; verb = L; echo = L
        }
        func put(_ i: Int, _ x: Double, pan: Double = 0, verb v: Double = 0, echo e: Double = 0) {
            guard i >= 0, i < n else { return }
            sL[i] += Float(x * min(1, 1 - pan)); sR[i] += Float(x * min(1, 1 + pan))
            if v > 0 { verb[i] += Float(x * v) }
            if e > 0 { echo[i] += Float(x * e) }
        }
        /// Adds the current stem to the mix and notes its RMS over the busy part of the video.
        func stem(_ name: String, _ body: () -> Void) {
            for i in 0..<n { sL[i] = 0; sR[i] = 0 }
            body()
            var sum = 0.0
            for i in window { sum += Double(sL[i] * sL[i] + sR[i] * sR[i]) / 2 }
            levels.append((name, sqrt(sum / Double(window.count))))
            for i in 0..<n { L[i] += sL[i]; R[i] += sR[i] }
        }
    }

    static func render(_ c: Cues) -> ([Float], [Float]) {
        let n = Int(c.length * sr)
        func at(_ t: Double) -> Int { Int((t * sr).rounded()) }
        let mix = Mix(n, window: at(c.drop)..<at(c.outro))
        let bar = 4 * beat, eighth = beat / 2, sixteenth = beat / 4
        func chord(_ t: Double) -> Int { (Int(((t - c.drop + 0.001) / bar).rounded(.down)) % 4 + 4) % 4 }
        let kicks = stride(from: c.drop, to: c.outro - 0.01, by: beat).map { $0 }
        // Sidechain: pads and bass dip on every kick.
        func duck(_ t: Double) -> Double {
            guard t >= c.drop else { return 1 }
            let last = c.drop + ((t - c.drop) / beat).rounded(.down) * beat
            guard last < c.outro - 0.01 else { return 1 }
            return 1 - 0.5 * exp(-(t - last) * 9)
        }
        var rng = Rng(s: 0x5eed)

        // Pad: three detuned saws per note, low-passed, a chord per bar. Swells in over the title card.
        mix.stem("pad") {
            var segs: [(Double, Double, [Int])] = []
            var b = Int(((0 - c.drop) / bar).rounded(.down))
            while c.drop + Double(b) * bar < c.outro - 0.01 {
                let s = max(0, c.drop + Double(b) * bar), e = min(c.outro, c.drop + Double(b + 1) * bar)
                segs.append((s, e, chords[(b % 4 + 4) % 4].pad))
                b += 1
            }
            segs.append((c.outro, c.length, endChord))
            for (si, (s, e, notes)) in segs.enumerated() {
                let attack = si == 0 ? 1.2 : 0.25, release = si == segs.count - 1 ? 0.01 : 0.7
                var fL = SVF(), fR = SVF()
                var ph = notes.flatMap { _ in [rng.next(), rng.next(), rng.next()] }
                let fs = notes.flatMap { m in [-7.0, 0, 7].map { hz(Double(m) + $0 / 100) / sr } }
                for i in at(s)..<min(n, at(e + release)) {
                    let t = Double(i) / sr, lt = t - s
                    var env = min(1, lt / attack)
                    if t > e { env *= max(0, 1 - (t - e) / release) }
                    var l = 0.0, r = 0.0
                    for v in 0..<ph.count {
                        ph[v] += fs[v]; ph[v] -= ph[v].rounded(.down)
                        let saw = 2 * ph[v] - 1
                        switch v % 3 { case 0: l += saw; case 2: r += saw; default: l += saw * 0.5; r += saw * 0.5 }
                    }
                    let cut = t >= c.outro ? 900 + 700 * exp(-(t - c.outro) * 0.8) : (t < c.drop ? 500 + 1000 * t / c.drop : 1600)
                    let g = env * 0.066 * (t >= c.drop && t < c.outro ? 0.8 * duck(t) : 1)
                    let yl = fL.run(l, cut).lp * g, yr = fR.run(r, cut).lp * g
                    mix.put(i, yl, pan: 0.6, verb: 0.3); mix.put(i, yr, pan: -0.6, verb: 0.3)
                }
            }
        }

        // Bass: 8th notes on the chord root with an octave hop, plus a sine sub. A long low C on the end card.
        mix.stem("bass") {
            let hops = [0, 0, 12, 0, 0, 0, 12, 0]
            var notes: [(Double, Double, Double)] = []
            var k = 0
            for t in stride(from: c.drop, to: c.outro - 0.01, by: eighth) {
                notes.append((t, eighth * 0.85, Double(chords[chord(t)].bass + hops[k % 8]))); k += 1
            }
            notes.append((c.outro, 4, 36))
            for (s, len, m) in notes {
                var f = SVF(), ph = 0.0, sub = 0.0
                let fr = hz(m) / sr, root = hz(m.truncatingRemainder(dividingBy: 12) + 36) / sr
                let long = len > 1
                for i in at(s)..<min(n, at(s + len + 0.03)) {
                    let lt = Double(i) / sr - s
                    var env = min(1, lt / 0.004) * (long ? exp(-lt * 0.9) : 1)
                    if lt > len { env *= max(0, 1 - (lt - len) / 0.03) }
                    ph += fr; ph -= ph.rounded(.down); sub += root; sub -= sub.rounded(.down)
                    let y = f.run(2 * ph - 1, 180 + 900 * exp(-lt * 16), q: 0.9).lp
                    mix.put(i, (y * 0.2 + sin(2 * .pi * sub) * 0.25) * env * duck(Double(i) / sr))
                }
            }
        }

        // Kick on every beat: the glow pulses with it. One last softer one as the end card comes in.
        mix.stem("kick") {
            for (s, gain) in kicks.map({ ($0, 0.65) }) + [(c.outro, 0.4)] {
                var ph = 0.0
                for i in at(s)..<min(n, at(s + 0.45)) {
                    let lt = Double(i) / sr - s
                    ph += (46 + 115 * exp(-lt * 32)) / sr
                    let y = sin(2 * .pi * ph) * exp(-lt * 6.5) * min(1, lt / 0.002) + rng.next() * 0.25 * exp(-lt * 500)
                    mix.put(i, y * gain)
                }
            }
        }

        // Clap on 2 and 4.
        mix.stem("clap") {
            for (k, s) in kicks.enumerated() where k % 2 == 1 {
                var f = SVF()
                for i in at(s)..<min(n, at(s + 0.35)) {
                    let lt = Double(i) / sr - s
                    var env = 0.0
                    for d in [0, 0.011, 0.022] where lt >= d { env += exp(-(lt - d) * 220) }
                    if lt >= 0.022 { env += 0.55 * exp(-(lt - 0.022) * 16) }
                    mix.put(i, f.run(rng.next(), 1500, q: 1.1).bp * env * 2.0, verb: 0.25)
                }
            }
        }

        // Hats: off-beat 8ths, quieter 16ths in between.
        mix.stem("hats") {
            for s in kicks {
                for (off, decay, gain, pan) in [(eighth, 40.0, 0.64, 0.25), (sixteenth, 85.0, 0.24, -0.3), (3 * sixteenth, 85.0, 0.24, -0.3)] {
                    var f = SVF(), g = SVF()
                    let t0 = s + off
                    for i in at(t0)..<min(n, at(min(t0 + 0.14, c.outro))) {
                        let lt = Double(i) / sr - t0
                        let y = g.run(f.run(rng.next(), 7000).hp, 9000).hp
                        mix.put(i, y * exp(-lt * decay) * gain, pan: pan)
                    }
                }
            }
        }

        // Arp: plucked 16ths over the chord, up an octave. Louder in the intro, faint under the groove.
        mix.stem("arp") {
            let order = [0, 1, 2, 3, 2, 1, 3, 2]
            var k = 0
            for s in stride(from: c.drop - 14 * sixteenth, to: c.outro - 0.01, by: sixteenth) where s >= 0.3 {
                let notes = chords[chord(s)].pad
                let m = Double(notes[order[k % order.count] % notes.count] + 12); k += 1
                let gain = s < c.drop ? 0.24 * min(1, (s - 0.3) / 0.8) : 0.12
                var ph = 0.0
                let fr = hz(m) / sr
                for i in at(s)..<min(n, at(s + 0.3)) {
                    let lt = Double(i) / sr - s
                    ph += fr; ph -= ph.rounded(.down)
                    let tri = 4 * abs(ph - 0.5) - 1
                    mix.put(i, tri * exp(-lt * 14) * min(1, lt / 0.003) * gain * duck(Double(i) / sr),
                            pan: k % 2 == 0 ? 0.4 : -0.4, verb: 0.4)
                }
            }
        }

        // Lead "voice": one note per lyric word, chord tones, held last note with vibrato, into an echo.
        mix.stem("lead") {
            var prev = 69.0, prevEnd = -1.0
            for note in c.notes {
                let ch = chords[chord(note.time)]
                let onBeat = abs(((note.time - c.drop) / beat) - ((note.time - c.drop) / beat).rounded()) < 0.02
                var allowed = note.last ? Array(ch.tones.prefix(3)) : ch.tones
                if !onBeat && !note.last { allowed += pentatonic }
                let x = note.count > 1 ? Double(note.word) / Double(note.count - 1) : 0
                let shapes: [Double] = [sin(.pi * x), x, 1 - 0.7 * x, 0.5 + 0.5 * sin(2 * .pi * x)]
                var target = 64 + 9 * shapes[note.line % 4] + (note.line % 2 == 1 ? 2 : 0)
                if note.last { target -= 2 }
                let first = note.word == 0 || note.time - prevEnd > 0.3
                let m = (57...81).filter { allowed.contains($0 % 12) }
                    .min { a, b in
                        func score(_ v: Int) -> Double { abs(Double(v) - target) + (first ? 0 : 0.4 * abs(Double(v) - prev)) }
                        return score(a) < score(b)
                    }.map(Double.init) ?? 69
                let glideFrom = first ? m : prev
                var ph = 0.0
                var breath = SVF()
                for i in at(note.time)..<min(n, at(note.time + note.length + 0.09)) {
                    let lt = Double(i) / sr - note.time
                    var pitch = m + (glideFrom - m) * max(0, 1 - lt / 0.05)
                    pitch += 0.2 * min(1, max(0, lt - 0.18) / 0.3) * sin(2 * .pi * 5.2 * lt)
                    ph += hz(pitch) / sr; ph -= ph.rounded(.down)
                    let p = 2 * .pi * ph
                    var env = min(1, lt / 0.018) * (0.8 + 0.2 * exp(-lt * 7))
                    if lt > note.length { env *= max(0, 1 - (lt - note.length) / 0.09) }
                    let y = sin(p) + 0.22 * sin(2 * p) + 0.1 * sin(3 * p) + 0.15 * breath.run(rng.next(), 2500).bp
                    mix.put(i, y * env * 0.2, verb: 0.3, echo: 0.4)
                }
                prev = m; prevEnd = note.time + note.length
            }
        }

        // Chimes as the logo appears: a soft FM bell arpeggio.
        mix.stem("chime") {
            for (ci, s) in c.chimes.enumerated() {
                let notes = ci == 0 ? [76, 81, 84, 88] : [72, 76, 79, 84, 88]
                for (k, m) in notes.enumerated() {
                    let t0 = s + Double(k) * 0.09, fr = hz(Double(m))
                    for i in at(t0)..<min(n, at(t0 + 3)) {
                        let lt = Double(i) / sr - t0
                        let y = sin(2 * .pi * fr * lt + 2.2 * exp(-lt * 5) * sin(2 * .pi * fr * 3.5 * lt))
                        mix.put(i, y * exp(-lt * 2) * min(1, lt / 0.002) * 0.09, pan: Double(k) * 0.3 - 0.5, verb: 0.6)
                    }
                }
            }
        }

        // Effects: a riser into the drop and a crash on it, swishes at cuts, a whoosh for the phones, a pop for the panel.
        mix.stem("fx") {
            func sweep(_ s: Double, _ len: Double, from f0: Double, to f1: Double, gain: Double, peak: Double, q: Double = 1.5) {
                var fl = SVF(), fr = SVF(), r2 = Rng(s: UInt32(s * 1000) | 1)
                for i in max(0, at(s))..<min(n, at(s + len)) {
                    let x = (Double(i) / sr - s) / len
                    let env = x < peak ? pow(x / peak, 2) : pow(max(0, 1 - (x - peak) / (1 - peak)), 1.5)
                    let cut = f0 * pow(f1 / f0, x)
                    mix.put(i, fl.run(rng.next(), cut, q: q).bp * env * gain, pan: 0.5 - x, verb: 0.3)
                    mix.put(i, fr.run(r2.next(), cut * 1.05, q: q).bp * env * gain, pan: x - 0.5, verb: 0.3)
                }
            }
            sweep(c.drop - 2.2, 2.2, from: 300, to: 6000, gain: 0.16, peak: 0.995, q: 2)
            var hp = SVF()
            for i in at(c.drop)..<min(n, at(c.drop + 2.2)) {
                let lt = Double(i) / sr - c.drop
                mix.put(i, hp.run(rng.next(), 4500).hp * exp(-lt * 2.6) * 0.13, verb: 0.3)
            }
            for cut in c.cuts { sweep(cut - 0.3, 0.55, from: 900, to: 3500, gain: 0.05, peak: 0.55) }
            sweep(c.outro - 0.45, 0.8, from: 1200, to: 5000, gain: 0.06, peak: 0.55)
            if let p = c.phones { sweep(p - 0.05, 0.9, from: 4500, to: 500, gain: 0.1, peak: 0.25) }
            if let p = c.pop {
                var ph = 0.0
                for i in at(p)..<min(n, at(p + 0.12)) {
                    let lt = Double(i) / sr - p
                    ph += (330 + 600 * exp(-lt * 60)) / sr
                    mix.put(i, sin(2 * .pi * ph) * exp(-lt * 38) * min(1, lt / 0.001) * 0.22, verb: 0.2)
                }
            }
        }

        // Echo on the lead: ping-pong, dotted 8th, darkening repeats.
        mix.stem("echo") {
            let d = at(0.75 * beat)
            var bl = [Float](repeating: 0, count: n), br = bl
            var damp = SVF()
            for i in 0..<n {
                let fromR = i >= d ? Double(br[i - d]) : 0, fromL = i >= d ? Double(bl[i - d]) : 0
                bl[i] = Float(Double(mix.echo[i]) + damp.run(fromR, 3500).lp * 0.38)
                br[i] = Float(fromL * 0.38)
                mix.put(i, fromL * 1.1, pan: 0.7, verb: 0.15)
                mix.put(i, fromR * 1.1, pan: -0.7, verb: 0.15)
            }
        }

        // Reverb: four damped combs and two allpasses per side (Schroeder style).
        mix.stem("reverb") {
            for (side, lengths) in [[1116, 1277, 1422, 1557], [1188, 1356, 1491, 1617]].enumerated() {
                var combs = lengths.map { [Double](repeating: 0, count: $0) }
                var pos = [Int](repeating: 0, count: 4), lp = [Double](repeating: 0, count: 4)
                var aps = [556, 441].map { [Double](repeating: 0, count: $0 + side * 23) }, apos = [0, 0]
                for i in 0..<n {
                    let x = Double(mix.verb[i]) * 0.1
                    var y = 0.0
                    for k in 0..<4 {
                        let out = combs[k][pos[k]]
                        lp[k] = out * 0.75 + lp[k] * 0.25
                        combs[k][pos[k]] = x + lp[k] * 0.86
                        pos[k] = (pos[k] + 1) % combs[k].count
                        y += out
                    }
                    for k in 0..<2 {
                        let b = aps[k][apos[k]]
                        aps[k][apos[k]] = y + b * 0.5
                        y = b - y
                        apos[k] = (apos[k] + 1) % aps[k].count
                    }
                    mix.put(i, y, pan: side == 0 ? 1 : -1)
                }
            }
        }

        // Master: level, fades, soft limiter.
        var sum = 0.0
        for i in mix.window { sum += Double(mix.L[i] * mix.L[i] + mix.R[i] * mix.R[i]) / 2 }
        let gain = 0.15 / max(1e-6, sqrt(sum / Double(mix.window.count)))   // about -16.5 dBFS RMS in the groove
        var limited = 0, peak: Float = 0
        func limit(_ x: Double) -> Float {
            let a = abs(x)
            if a <= 0.75 { return Float(x) }
            limited += 1
            return Float((x < 0 ? -1 : 1) * (0.75 + 0.14 * tanh((a - 0.75) / 0.14)))
        }
        for i in 0..<n {
            let t = Double(i) / sr
            let fade = min(1, t / 0.01, (c.length - t) / 2.0)
            mix.L[i] = limit(Double(mix.L[i]) * gain * fade)
            mix.R[i] = limit(Double(mix.R[i]) * gain * fade)
            peak = max(peak, abs(mix.L[i]), abs(mix.R[i]))
        }
        print("stems (RMS in the groove, before master gain \(String(format: "%.2f", gain))):")
        for (name, rms) in mix.levels { print(String(format: "  %-7@ %6.1f dB", name as NSString, 20 * log10(max(rms * gain, 1e-9)))) }
        print(String(format: "master peak %.3f, limited samples %.3f%%", peak, 100 * Double(limited) / Double(2 * n)))
        return (mix.L, mix.R)
    }

    // MARK: Files

    /// Whether a rendered demo includes the phone scene (it's 5 s longer).
    static func hasPhones(_ video: URL) -> Bool { AVURLAsset(url: video).duration.seconds > 52 }

    static func write(_ l: [Float], _ r: [Float], to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(l.count)),
                  let ch = buf.floatChannelData else { return false }
            buf.frameLength = AVAudioFrameCount(l.count)
            l.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: l.count) }
            r.withUnsafeBufferPointer { ch[1].update(from: $0.baseAddress!, count: r.count) }
            try file.write(from: buf)
            return true                              // the file is finished when `file` goes away
        } catch { print(error); return false }
    }

    /// Picture from `video`, sound from `audio`, copied as they are into `out`.
    static func mux(video: URL, audio: URL, out: URL) -> Bool {
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: audio)
        guard let vt = va.tracks(withMediaType: .video).first, let at = aa.tracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return false }
        do {
            try cv.insertTimeRange(CMTimeRange(start: .zero, duration: va.duration), of: vt, at: .zero)
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(aa.duration, va.duration)), of: at, at: .zero)
        } catch { print(error); return false }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        try? FileManager.default.removeItem(at: out)
        ex.outputURL = out
        ex.outputFileType = .mp4
        var done = false
        ex.exportAsynchronously { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if ex.status != .completed { print(String(describing: ex.error)) }
        return ex.status == .completed
    }

    // MARK: Check

    /// Reads the finished video back: track lengths, loudness per second, and how close each kick
    /// lands to its glow beat.
    static func check(_ url: URL, cues: Cues) {
        let asset = AVURLAsset(url: url)
        let v = asset.tracks(withMediaType: .video).first, a = asset.tracks(withMediaType: .audio).first
        print(String(format: "file %.3f s, video track %.3f s, audio track %.3f s", asset.duration.seconds,
                     v?.timeRange.duration.seconds ?? -1, a?.timeRange.duration.seconds ?? -1))
        guard let a, let reader = try? AVAssetReader(asset: asset) else { print("no audio"); return }
        let output = AVAssetReaderTrackOutput(track: a, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2])
        reader.add(output)
        reader.startReading()
        var mono: [Float] = [], peak: Float = 0
        while let sb = output.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for k in stride(from: 0, to: chunk.count - 1, by: 2) {
                peak = max(peak, abs(chunk[k]), abs(chunk[k + 1]))
                mono.append((chunk[k] + chunk[k + 1]) / 2)
            }
        }
        print(String(format: "decoded %.3f s, peak %.3f (%.1f dBFS)", Double(mono.count) / sr, peak, 20 * log10(Double(peak))))
        var line = "loudness per second (dBFS):"
        var quiet: [Int] = []
        for s in 0..<Int(Double(mono.count) / sr) {
            var sum = 0.0
            for i in Int(Double(s) * sr)..<min(mono.count, Int(Double(s + 1) * sr)) { sum += Double(mono[i] * mono[i]) }
            let db = 10 * log10(max(sum / sr, 1e-12))
            line += String(format: " %.0f", db)
            if db < -45 { quiet.append(s) }
        }
        print(line)
        print(quiet.isEmpty ? "no silent seconds" : "silent seconds: \(quiet)")
        // Kick timing: the bass-band envelope's steepest rise near each expected beat.
        var env = [Double](repeating: 0, count: mono.count), lp = 0.0, e = 0.0
        for i in 0..<mono.count {
            lp += (Double(mono[i]) - lp) * 0.012                 // ~85 Hz low-pass
            e = max(abs(lp), e * 0.9995)
            env[i] = e
        }
        var offsets: [Double] = []
        for b in stride(from: cues.drop, to: cues.outro - 0.01, by: beat) {
            let lo = Int((b - 0.05) * sr), hi = min(mono.count - 2, Int((b + 0.05) * sr))
            guard lo > 0, hi > lo else { continue }
            var best = lo, rise = -1.0
            for i in lo..<hi where env[i + 1] - env[i] > rise { rise = env[i + 1] - env[i]; best = i }
            offsets.append(Double(best) / sr - b)
        }
        let mean = offsets.reduce(0, +) / Double(max(1, offsets.count))
        let worst = offsets.map(abs).max() ?? 0
        print(String(format: "kicks vs glow beats: %d beats, mean offset %+.1f ms, worst %.1f ms (a frame is 33 ms)",
                     offsets.count, mean * 1000, worst * 1000))
        // Lead notes start where the words light up; both should sit on the music's 16th grid.
        let grid = cues.notes.map { n -> Double in
            let x = (n.time - cues.drop) / (beat / 4)
            return abs(x - x.rounded()) * beat / 4
        }
        print(String(format: "lead notes: %d, furthest from the 16th grid %.2f ms", cues.notes.count, (grid.max() ?? 0) * 1000))
        // Glow: the brightest frame after each beat is at most one frame late.
        let late = stride(from: cues.drop, to: cues.outro - 0.01, by: beat).map { b in
            (b * Double(DemoVideo.fps)).rounded(.up) / Double(DemoVideo.fps) - b
        }
        print(String(format: "glow peak frame after each beat: worst %.1f ms late", (late.max() ?? 0) * 1000))
    }
}
#endif
