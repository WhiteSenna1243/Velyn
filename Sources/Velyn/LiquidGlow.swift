import AppKit
import MetalKit
import SwiftUI

// MARK: - Liquid glow
//
// A bright band along the screen edge whose thickness ripples like liquid: bulges slide around
// the edge, colour regions flow with them, and music makes it surge. Drawn by one small GPU
// shader per frame (compiled at runtime, so no Xcode/Metal toolchain is needed to build Velyn).
// The shader works out each pixel's depth from the edge and its position around the edge,
// so there is no blur and almost no CPU work.

/// Everything the shader needs for one frame. Packed as plain floats (see `floats`).
struct LiquidUniforms {
    var size = SIMD2<Float>(0, 0)       // drawable pixels
    var scale: Float = 1                // pixels per point
    var phase: Float = 0                // liquid flow, seconds-ish
    var rotation: Float = 0             // colour offset around the edge, turns
    var intensity: Float = 1
    var thickness: Float = 30           // points
    var reach: Float = 1                // 0...1, how far the soft halo goes
    var colorA = SIMD3<Float>(1, 0.2, 0.4)
    var colorB = SIMD3<Float>(0.2, 0.5, 1)
    var twoColors: Float = 1
    var share: Float = 0.6
    var notch = SIMD4<Float>(0, 0, 0, 0) // x, y, w, h in pixels; w = 0 means none
    var energy: Float = 0               // music energy 0...1 (makes the bulges swell)
    var corner: Float = 20              // screen corner radius, pixels

    var floats: [Float] {
        [size.x, size.y, scale, phase, rotation, intensity, thickness, reach,
         colorA.x, colorA.y, colorA.z, colorB.x, colorB.y, colorB.z, twoColors, share,
         notch.x, notch.y, notch.z, notch.w, energy, corner, 0, 0]
    }
}

final class LiquidRenderer {
    static let shared = LiquidRenderer()

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        device = dev
        queue = dev?.makeCommandQueue()
        var state: MTLRenderPipelineState?
        var lib: MTLLibrary?
        do { lib = try dev?.makeLibrary(source: Self.source, options: nil) }
        catch { NSLog("Velyn: liquid glow shader failed to compile, using the classic glow. \(error)") }
        if let dev, let lib {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "liquid_vertex")
            d.fragmentFunction = lib.makeFunction(name: "liquid_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            state = try? dev.makeRenderPipelineState(descriptor: d)
        }
        pipeline = state
    }

    var available: Bool { pipeline != nil && queue != nil }

    func encode(_ u: LiquidUniforms, pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer) {
        guard let pipeline, let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = u.floats
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&f, length: f.count * MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue?.makeCommandBuffer() }

    /// Renders one frame into an image (snapshot tool).
    func image(_ u: LiquidUniforms) -> CGImage? {
        guard let device, available else { return nil }
        let w = Int(u.size.x), h = Int(u.size.y)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let buf = makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        encode(u, pass: pass, buffer: buf)
        buf.commit()
        buf.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // Metal Shading Language, compiled when Velyn starts.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; };

    vertex VOut liquid_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));   // one triangle covering the screen
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static float sdBox(float2 p, float2 c, float2 half_, float r) {
        float2 q = abs(p - c) - (half_ - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    struct Params { float t, thick, reach, energy, k; };

    // Liquid band thickness at position s (0...1 around the edge): ripples plus sliding bulges.
    static float bandWidth(float s, Params P, thread float &lump) {
        const float TAU = 6.2831853;
        float t = P.t;
        float ripple = 0.50 * sin(TAU * 3.0 * s - 1.30 * t)
                     + 0.30 * sin(TAU * 7.0 * s + 0.90 * t + 1.7)
                     + 0.20 * sin(TAU * 13.0 * s - 2.30 * t + 0.4);
        lump = pow(0.5 + 0.5 * sin(TAU * (2.0 * s - 0.110 * t)), 6.0)
             + 0.8 * pow(0.5 + 0.5 * sin(TAU * (3.0 * s + 0.075 * t) + 2.0), 8.0)
             + 0.6 * pow(0.5 + 0.5 * sin(TAU * (5.0 * s - 0.170 * t) + 4.1), 10.0);
        return P.thick * (0.60 + 0.25 * (0.5 + 0.5 * ripple) + (0.25 + 0.80 * P.energy) * lump);
    }

    // Brightness at depth d (pixels) for a band of width w: hot rim, soft-edged band, short halo.
    static float profile(float d, float w, float reach) {
        float cut = w * (1.6 + 2.4 * reach);
        if (d < 0.0 || d > cut) { return 0.0; }
        float band = 1.0 - smoothstep(w * 0.35, w, d);
        float rim = exp(-d / max(1.0, w * 0.15));
        float halo = exp(-d / max(1.0, w * (0.7 + 1.3 * reach))) * (0.08 + 0.27 * reach)
                   * (1.0 - smoothstep(cut * 0.45, cut, d));          // fade out, no hard line
        return clamp(0.70 * band + 0.45 * rim + halo, 0.0, 1.0);
    }

    // Colour at position s around the edge; the two-colour boundary wobbles with the liquid.
    static float3 colorAt(float s, float rot, float t, float3 ca, float3 cb, float two, float share) {
        const float TAU = 6.2831853;
        float h = fract(s + rot + 0.03 * sin(TAU * 5.0 * s + t * 0.8));
        if (two < 0.5) { return ca; }
        float e = 0.07;
        float x = smoothstep(share - e, share + e, h) * (1.0 - smoothstep(1.0 - e, 1.0, h));
        return mix(ca, cb, x);
    }

    fragment float4 liquid_fragment(VOut in [[stage_in]], constant float *u [[buffer(0)]]) {
        const float TAU = 6.2831853;
        float2 size = float2(u[0], u[1]);
        float k = u[2];
        float rot = u[4];
        float inten = u[5];
        float3 ca = float3(u[8], u[9], u[10]);
        float3 cb = float3(u[11], u[12], u[13]);
        float two = u[14];
        float share = clamp(u[15], 0.2, 0.8);
        float4 notch = float4(u[16], u[17], u[18], u[19]);
        float radius = u[21];
        Params P = { u[3], u[6] * k, u[7], u[20], k };
        float2 p = in.pos.xy;

        // Outside the rounded screen corners (or inside the notch) nothing is drawn.
        if (sdBox(p, size * 0.5, size * 0.5, radius) > 0.0) { return float4(0.0); }

        float W = size.x, H = size.y, L = 2.0 * (W + H);
        // Each edge glows on its own; taking the brightest keeps the corners seamless.
        float4 depth = float4(p.y, W - p.x, H - p.y, p.x);                     // top, right, bottom, left
        float4 pos = float4(p.x, W + p.y, W + H + (W - p.x), 2.0 * W + H + (H - p.y)) / L;
        float best = 0.0, sum = 0.0, lumpAt = 0.0;
        float3 colSum = float3(0.0);
        for (int i = 0; i < 4; i++) {
            float lump;
            float w = bandWidth(pos[i], P, lump);
            float a = profile(depth[i], w, P.reach);
            if (a > best) { best = a; lumpAt = lump; }
            sum += a;
            colSum += a * colorAt(pos[i], rot, P.t, ca, cb, two, share);
        }
        if (notch.z > 0.0) {
            float top = -20.0 * k, bottom = notch.y + notch.w;
            float n = sdBox(p, float2(notch.x + notch.z * 0.5, (top + bottom) * 0.5),
                            float2(notch.z * 0.5, (bottom - top) * 0.5), 9.0 * k);
            if (n < 0.0) { return float4(0.0); }
            float lump;
            float w = bandWidth(pos[0], P, lump);
            float a = profile(n, w, P.reach);
            if (a > best) { best = a; lumpAt = lump; }
            sum += a;
            colSum += a * colorAt(pos[0], rot, P.t, ca, cb, two, share);
        }
        if (best < 0.002) { return float4(0.0); }
        // Soft union of the edges near corners, never brighter than 1.
        float a = clamp(best + 0.35 * (sum - best), 0.0, 1.0) * inten;
        float3 col = colSum / max(sum, 1e-4);   // each edge's own colour, blended at the corners
        col = mix(col, float3(1.0), clamp(0.25 * best * best + 0.15 * lumpAt * best, 0.0, 0.45));   // white-hot core

        // Light, not paint: a black colour gives no glow instead of a dark band.
        float light = clamp(max(col.r, max(col.g, col.b)) * 1.15, 0.0, 1.0);
        a *= light;
        return float4(col * a, a);
    }
    """
}

// MARK: - View

/// Hosts the shader. It runs its own display-synced loop and asks `frame` for uniforms each time.
final class LiquidGlowView: MTKView, MTKViewDelegate {
    var frameProvider: ((CGSize, CGFloat) -> LiquidUniforms?)?

    init() {
        super.init(frame: .zero, device: LiquidRenderer.shared.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 60
        // The glow is soft, so render at 1 pixel per point (a quarter of the work on Retina).
        autoResizeDrawable = false
    }

    required init(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        drawableSize = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let u = frameProvider?(bounds.size, drawableSize.width / max(1, bounds.width)),
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buf = LiquidRenderer.shared.makeCommandBuffer() else { return }
        LiquidRenderer.shared.encode(u, pass: pass, buffer: buf)
        buf.present(drawable)
        buf.commit()
    }
}

/// SwiftUI wrapper: the liquid glow for one display.
struct LiquidGlow: NSViewRepresentable {
    let engine: Engine
    let settings: Settings
    var notch: CGRect?
    /// Frames per second from `Power`; 0 stops drawing.
    var fps = 60

    final class Coordinator {
        let driver = GlowDriver()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiquidGlowView {
        let v = LiquidGlowView()
        update(v, context)
        return v
    }

    func updateNSView(_ v: LiquidGlowView, context: Context) { update(v, context) }

    private func update(_ v: LiquidGlowView, _ context: Context) {
        let driver = context.coordinator.driver
        let notch = self.notch
        if fps > 0, v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
        if v.isPaused != (fps == 0) { v.isPaused = fps == 0 }
        v.frameProvider = { [weak engine, weak settings] size, scale in
            guard let engine, let settings else { return nil }
            let p = settings.prefs
            let f = driver.step(time: CACurrentMediaTime(), prefs: p, playing: engine.isPlaying, audio: engine.audio)
            return LiquidGlow.uniforms(p, colors: engine.glowColors(p), frame: f, size: size, scale: scale,
                                       notch: p.notchCompat ? notch : nil)
        }
    }

    static func uniforms(_ p: Prefs, colors: (RGB, RGB), frame f: GlowDriver.Frame, size: CGSize, scale: CGFloat,
                         notch: CGRect?) -> LiquidUniforms {
        var u = LiquidUniforms()
        let k = Float(scale)
        u.size = SIMD2(Float(size.width) * k, Float(size.height) * k)
        u.scale = k
        u.phase = Float(f.phase)
        u.rotation = Float(f.rotation / 360)
        u.intensity = Float(f.intensity * (0.15 + 0.85 * p.brightness))
        u.thickness = Float(6 + p.thickness * 40)
        u.reach = Float(p.glow)
        u.colorA = SIMD3(Float(colors.0.r), Float(colors.0.g), Float(colors.0.b))
        u.colorB = SIMD3(Float(colors.1.r), Float(colors.1.g), Float(colors.1.b))
        u.twoColors = p.gradientColors == 2 ? 1 : 0
        u.share = Float(p.primaryShare)
        if let n = notch {
            u.notch = SIMD4(Float(n.minX) * k, Float(n.minY) * k, Float(n.width) * k, Float(n.height) * k)
        }
        u.energy = Float(f.energy)
        u.corner = 14 * k
        return u
    }
}
