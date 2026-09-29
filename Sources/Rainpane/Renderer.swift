import AppKit
import Metal
import QuartzCore
import simd

struct Uniforms {
    var screen = SIMD4<Float>.zero
    var timeInfo = SIMD4<Float>.zero
    var rain = SIMD4<Float>.zero
    var rain2 = SIMD4<Float>.zero
    var rainColor = SIMD4<Float>.zero
    var light = SIMD4<Float>.zero
    var water = SIMD4<Float>.zero
    var counts = SIMD4<Float>.zero
}

/// 모든 화면이 공유하는 Metal 객체
final class GPU {
    static let shared: GPU? = {
        do { return try GPU() } catch {
            NSLog("Rainpane GPU init failed: \(error)")
            return nil
        }
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let mask: MTLRenderPipelineState
    let rain: MTLRenderPipelineState
    let pool: MTLRenderPipelineState
    let rivulet: MTLRenderPipelineState
    let drop: MTLRenderPipelineState
    let splash: MTLRenderPipelineState
    let curtain: MTLRenderPipelineState
    let press: MTLRenderPipelineState
    let pressShadow: MTLRenderPipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Rainpane", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Metal을 사용할 수 없습니다", "Metal is not available")])
        }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let lib = try device.makeLibrary(source: shaderSource, options: options)

        func make(_ v: String, _ f: String, format: MTLPixelFormat = .bgra8Unorm, blend: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if blend {
                // 프리멀티플라이드 알파 합성
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        mask = try make("maskVertex", "maskFragment", format: .rg8Unorm, blend: false)
        rain = try make("rainVertex", "rainFragment")
        pool = try make("poolVertex", "poolFragment")
        rivulet = try make("rivuletVertex", "rivuletFragment")
        drop = try make("dropVertex", "dropFragment")
        splash = try make("splashVertex", "dropFragment")
        curtain = try make("curtainVertex", "curtainFragment")
        press = try make("pressVertex", "pressFragment")
        pressShadow = try make("pressVertex", "pressShadowFragment")
    }
}

/// 프레임마다 재사용되는 공유 버퍼 (in-flight 프레임 수만큼 링)
final class RingBuffer {
    private var buffers: [MTLBuffer?]
    private let device: MTLDevice

    init(device: MTLDevice, count: Int) {
        self.device = device
        buffers = Array(repeating: nil, count: count)
    }

    func upload<T>(_ array: [T], slot: Int) -> MTLBuffer? {
        let size = max(MemoryLayout<T>.stride * array.count, 16)
        if buffers[slot] == nil || buffers[slot]!.length < size {
            buffers[slot] = device.makeBuffer(length: size * 2, options: [.storageModeShared, .cpuCacheModeWriteCombined])
        }
        guard let buf = buffers[slot] else { return nil }
        if !array.isEmpty {
            _ = array.withUnsafeBytes { memcpy(buf.contents(), $0.baseAddress!, $0.count) }
        }
        return buf
    }
}

/// 화면 하나를 담당하는 렌더러
final class ScreenRenderer {
    let layer: CAMetalLayer
    private(set) var quartzFrame: CGRect
    private var pixelScale: CGFloat = 2
    private var maskTexture: MTLTexture?
    private var maskVersion = -1
    private let inflight = DispatchSemaphore(value: 3)
    private var slot = 0
    private let gpu: GPU
    private let poolBuf, heightBuf, rivBuf, dropBuf, curtainBuf, edgeBuf, rectBuf, pressBuf: RingBuffer
    private var presentedEmpty = false
    var screenIndex = 0

    init(gpu: GPU, layer: CAMetalLayer, quartzFrame: CGRect) {
        self.gpu = gpu
        self.layer = layer
        self.quartzFrame = quartzFrame
        layer.device = gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        func ring() -> RingBuffer { RingBuffer(device: gpu.device, count: 3) }
        poolBuf = ring(); heightBuf = ring(); rivBuf = ring(); dropBuf = ring()
        curtainBuf = ring(); edgeBuf = ring(); rectBuf = ring(); pressBuf = ring()
    }

    func configure(quartzFrame: CGRect, backingScale: CGFloat, renderScale: CGFloat) {
        self.quartzFrame = quartzFrame
        pixelScale = backingScale * renderScale
        let size = CGSize(width: (quartzFrame.width * pixelScale).rounded(), height: (quartzFrame.height * pixelScale).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = pixelScale
        layer.drawableSize = size
        CATransaction.commit()
        if maskTexture?.width != Int(size.width) || maskTexture?.height != Int(size.height) {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .private
            maskTexture = gpu.device.makeTexture(descriptor: td)
            maskVersion = -1
        }
        presentedEmpty = false
    }

    /// 빈 프레임을 한 번 올려서 화면을 비운다 (가려졌거나 멈췄을 때)
    func clearOnce() {
        guard !presentedEmpty else { return }
        guard inflight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(), let cb = gpu.queue.makeCommandBuffer() else { inflight.signal(); return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        cb.present(drawable)
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        presentedEmpty = true
    }

    func draw(snapshot s: SimSnapshot, presses: [SIMD4<Float>], pressGroups: Int = 0, pressShadowOnly: Bool = false, base: Uniforms, rainCount: Int, splashCount: Int) {
        // GPU가 밀려 있으면 메인 스레드를 막지 않고 이번 프레임은 건너뛴다
        guard inflight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(),
              let cb = gpu.queue.makeCommandBuffer() else { inflight.signal(); return }
        presentedEmpty = false
        encode(cb: cb, target: drawable.texture, snapshot: s, presses: presses, pressGroups: pressGroups, pressShadowOnly: pressShadowOnly, base: base, rainCount: rainCount,
               splashCount: splashCount)
        cb.present(drawable)
        let sem = inflight
        cb.addCompletedHandler { buf in
            GPUTiming.record(buf.gpuEndTime - buf.gpuStartTime)
            sem.signal()
        }
        cb.commit()
    }

    /// 한 프레임을 target 텍스처에 그린다 (화면용 드로어블, 또는 스냅샷용 오프스크린 텍스처)
    func encode(cb: MTLCommandBuffer, target: MTLTexture, snapshot s: SimSnapshot, presses: [SIMD4<Float>], pressGroups: Int = 0,
                pressShadowOnly: Bool = false, base: Uniforms,
                rainCount: Int, splashCount: Int) {
        guard let mask = maskTexture else { return }
        slot = (slot + 1) % 3
        var u = base
        u.screen = SIMD4(Float(quartzFrame.minX), Float(quartzFrame.minY), Float(quartzFrame.width), Float(quartzFrame.height))
        u.timeInfo.y = Float(pixelScale)
        u.counts = SIMD4(Float(s.edges.count / 2), s.edgeLength, Float(screenIndex), base.counts.w)

        let quad = 4
        // 1) 가려짐 마스크: 창 배치가 바뀌었을 때만
        if maskVersion != s.maskVersion {
            maskVersion = s.maskVersion
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = mask
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                let rects = screenIndex < s.screenRects.count ? s.screenRects[screenIndex] : []
                let n = rects.count / 2
                if n > 0 {
                    enc.setRenderPipelineState(gpu.mask)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setVertexBuffer(rectBuf.upload(rects, slot: slot), offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: n)
                }
                enc.endEncoding()
            }
        }

        // 2) 본 패스
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(mask, index: 0)

        if rainCount > 0 {
            enc.setRenderPipelineState(gpu.rain)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: rainCount)
        }
        if !s.curtains.isEmpty {
            let b = curtainBuf.upload(s.curtains, slot: slot)
            enc.setRenderPipelineState(gpu.curtain)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentBuffer(b, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: s.curtains.count / 3)
        }
        if !s.pools.isEmpty {
            let b = poolBuf.upload(s.pools, slot: slot)
            enc.setRenderPipelineState(gpu.pool)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentBuffer(b, offset: 0, index: 1)
            enc.setFragmentBuffer(heightBuf.upload(s.heights, slot: slot), offset: 0, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: s.pools.count / 4)
        }
        if !s.rivulets.isEmpty {
            let b = rivBuf.upload(s.rivulets, slot: slot)
            enc.setRenderPipelineState(gpu.rivulet)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentBuffer(b, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: s.rivulets.count / 4)
        }
        if !s.drops.isEmpty {
            enc.setRenderPipelineState(gpu.drop)
            enc.setVertexBuffer(dropBuf.upload(s.drops, slot: slot), offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: s.drops.count / 2)
        }
        if splashCount > 0 && !s.edges.isEmpty {
            enc.setRenderPipelineState(gpu.splash)
            enc.setVertexBuffer(edgeBuf.upload(s.edges, slot: slot), offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: splashCount * 5)
        }
        // 마우스로 누른 물: 화면 표면의 일이라 가려짐 없이 맨 위에
        if pressGroups > 0 {
            let b = pressBuf.upload(presses, slot: slot)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentBuffer(b, offset: 0, index: 1)
            // 그림자를 먼저 깔고 물방울 (유리 모드면 그림자만: 물방울은 그 위 유리가 그린다)
            enc.setRenderPipelineState(gpu.pressShadow)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: pressGroups)
            if !pressShadowOnly {
                enc.setRenderPipelineState(gpu.press)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad, instanceCount: pressGroups)
            }
        }
        enc.endEncoding()
    }
}

/// GPU 프레임 시간 (완료 핸들러 스레드에서 기록, 메인에서 읽음)
enum GPUTiming {
    private static var lock = os_unfair_lock()
    private static var total: Double = 0
    private static var count = 0
    static func record(_ t: Double) {
        os_unfair_lock_lock(&lock); total += t; count += 1; os_unfair_lock_unlock(&lock)
    }
    /// 평균(ms)을 돌려주고 초기화
    static func drain() -> Double {
        os_unfair_lock_lock(&lock); defer { total = 0; count = 0; os_unfair_lock_unlock(&lock) }
        return count > 0 ? total / Double(count) * 1000 : 0
    }
}
