import SwiftUI
import AppKit

// MARK: - Player bar (shown on hover)

struct PlayerBar: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let track = engine.state.track
        let subtitle: String = {
            guard let t = track else { return "" }
            return t.album.isEmpty ? t.artist : "\(t.artist) — \(t.album)"
        }()

        VStack(spacing: 8) {
            Scrubber(scale: 1)
            HStack(spacing: 14) {
                Group {
                    if let img = engine.artwork {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.10)
                            Image(systemName: "music.note").foregroundColor(Color.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Not Playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.95))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TransportRow(scale: 0.8)
                    .frame(width: 280)

                HStack(spacing: 8) {
                    Spacer()
                    if engine.canFavorite {
                        CircleIconButton(system: engine.state.favorited ? "star.fill" : "star", size: 30) {
                            engine.toggleFavorite()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

struct CircleIconButton: View {
    let system: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Scrubber

struct Scrubber: View {
    let scale: CGFloat
    @EnvironmentObject var engine: Engine
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { tl in
            let dur = max(engine.state.track?.duration ?? 0, 0)
            let live = min(max(engine.time(at: tl.date, offset: 0), 0), dur)
            let pos = dragValue ?? live
            let frac = dur > 0.01 ? pos / dur : 0
            let barH: CGFloat = (hovering || dragValue != nil) ? 10 : 6

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        Capsule().fill(Color.white.opacity(0.88))
                            .frame(width: max(0, geo.size.width * frac))
                    }
                    .frame(height: barH)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.15), value: barH)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard dur > 0.01 else { return }
                                dragValue = clamp(v.location.x / geo.size.width) * dur
                            }
                            .onEnded { v in
                                if dur > 0.01 { engine.seek(to: clamp(v.location.x / geo.size.width) * dur) }
                                dragValue = nil
                            }
                    )
                }
                .frame(height: 16)
                .onHover { hovering = $0 }

                HStack {
                    Text(fmt(pos))
                    Spacer()
                    Text("−" + fmt(max(dur - pos, 0)))
                }
                .font(.system(size: 11 * scale, weight: .medium).monospacedDigit())
                .foregroundColor(Color.white.opacity(0.55))
            }
        }
    }

    private func clamp(_ x: Double) -> Double { max(0, min(1, x)) }

    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Transport

struct TransportRow: View {
    let scale: CGFloat
    @EnvironmentObject var engine: Engine

    var body: some View {
        let st = engine.state
        HStack(spacing: 0) {
            ToggleChip(system: "shuffle", on: st.shuffle, scale: scale) { engine.toggleShuffle() }
            Spacer()
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 28 * scale))
            }
            .buttonStyle(PressStyle())
            Spacer()
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38 * scale))
                    .frame(width: 48 * scale, height: 48 * scale)
            }
            .buttonStyle(PressStyle())
            Spacer()
            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 28 * scale))
            }
            .buttonStyle(PressStyle())
            Spacer()
            ToggleChip(system: st.repeatMode == .one ? "repeat.1" : "repeat",
                       on: st.repeatMode != .off, scale: scale) { engine.cycleRepeat() }
        }
        .foregroundColor(Color.white.opacity(0.92))
    }
}

struct ToggleChip: View {
    let system: String
    let on: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16 * scale, weight: .semibold))
                .foregroundColor(Color.white.opacity(on ? 1 : 0.7))
                .frame(width: 38 * scale, height: 32 * scale)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(on ? 0.26 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
