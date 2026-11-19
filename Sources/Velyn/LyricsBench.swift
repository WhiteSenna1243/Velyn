#if DEBUG
import SwiftUI
import AppKit

/// Dev aid: how long each lyric style takes to draw one frame.
/// swift build && .build/debug/Velyn --lyrics-bench [frames]
@MainActor
enum LyricsBench {
    static func run(frames: Int) {
        let engine = Engine()
        let settings = Settings()
        settings.prefs = Prefs()
        let lines = DemoVideo.lyrics()
        let art = DemoVideo.cover()
        engine.debugLoad(track: Track(title: "Paper Lanterns", artist: "Sample Artist", album: "Night Lights", duration: 214),
                         position: 2, artwork: art, lines: lines)
        let p = settings.prefs
        let palette = engine.kineticPalette(p)
        let colors = engine.lyricColors(p)

        func input(_ t: Double) -> LyricInput {
            var snap = AudioSnapshot()
            snap.beatPulse = Float(exp(-t.truncatingRemainder(dividingBy: 0.5) * 7))
            snap.level = 0.6
            snap.hasSignal = true
            return LyricInput(lines: lines, t: t, clock: t, size: 1, motion: 0.6,
                              palette: palette, colors: colors, font: .sfPro, snap: snap)
        }

        let sim = SpotlightSim()
        let styles: [(String, (LyricInput) -> AnyView)] = [
            ("empty", { _ in AnyView(Color.black) }),
            ("stream", { AnyView(StreamStage(input: $0)) }),
            ("lens", { AnyView(FisheyeStage(input: $0)) }),
            ("code", { AnyView(CodeStage(input: $0)) }),
            ("vine", { AnyView(GraphStage(input: $0, kind: .branches)) }),
            ("weave", { AnyView(GraphStage(input: $0, kind: .web)) }),
            ("stars", { AnyView(GraphStage(input: $0, kind: .constellation)) }),
            ("spotlight", { AnyView(SpotlightStage(input: $0, artwork: art, external: sim)) }),
        ]
        let size = CGSize(width: 1512, height: 982)
        for (name, make) in styles {
            var times: [Double] = []
            for f in 0..<frames {
                let t = 2.0 + Double(f) / 60
                let start = CACurrentMediaTime()
                let r = ImageRenderer(content: make(input(t)).frame(width: size.width, height: size.height)
                                        .background(Color.black))
                r.scale = 2
                guard let cg = r.cgImage else { continue }
                if f == frames / 2, let out = ProcessInfo.processInfo.environment["BENCH_OUT"] {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
                }
                times.append((CACurrentMediaTime() - start) * 1000)
            }
            let sorted = times.sorted()
            let avg = times.reduce(0, +) / Double(times.count)
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            print(String(format: "%-10@ avg %6.2f ms   p95 %6.2f ms   max %6.2f ms", name as NSString, avg, p95, sorted.last!))
        }

        // Live: one window that stays up (off screen), updated frame by frame like the real one.
        // This is where text laid out once pays off: it carries over between frames.
        print("live window, main-thread time per frame:")
        for (name, kind) in [("vine", GraphKind.branches), ("weave", .web), ("stars", .constellation)] {
            for old in [true, false] {
                GraphStage.debugOldText = old
                let clock = BenchClock(input(2))
                let host = NSHostingView(rootView: BenchLive(clock: clock, kind: kind))
                host.frame = CGRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                var times: [Double] = []
                for f in 0..<frames {
                    let start = CACurrentMediaTime()
                    clock.input = input(2 + Double(f) / 60)
                    RunLoop.main.run(until: Date())
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    times.append((CACurrentMediaTime() - start) * 1000)
                }
                w.orderOut(nil)
                let sorted = times.sorted()
                print(String(format: "  %-6@ %@  avg %5.2f ms   p95 %5.2f ms", name as NSString, old ? "old" : "new",
                             times.reduce(0, +) / Double(times.count), sorted[Int(Double(sorted.count) * 0.95)]))
            }
        }
        GraphStage.debugOldText = false
    }
}

final class BenchClock: ObservableObject {
    @Published var input: LyricInput
    init(_ i: LyricInput) { input = i }
}

private struct BenchLive: View {
    @ObservedObject var clock: BenchClock
    let kind: GraphKind
    var body: some View { GraphStage(input: clock.input, kind: kind).background(Color.black) }
}
#endif
