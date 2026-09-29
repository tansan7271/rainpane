import AppKit
import simd

/// 마우스로 누른 자리에 물이 눌려 퍼졌다가, 떼면 오므라드는 효과 (갤럭시 S6 물방울 잠금화면 느낌).
/// 유리와 비닐 랩 사이에 낀 물을 손가락으로 누르는 모습: 누르는 동안 물이 닿는 면이 넓어지고,
/// 끌면 말랑하게 늘어나며 따라오고, 떼면 매끈하게 작아져 사라진다.
/// 화면 표면에서 일어나는 일이라 창 순서와 상관없이 맨 위에 그린다.
final class PressEffect {
    struct Blob {
        let id: Int
        var pos: SIMD2<Float>
        var target: SIMD2<Float>
        var vel = SIMD2<Float>(0, 0)
        var r: Float = 0
        var vr: Float = 0
        var held = true
        var age: Float = 0            // 누른(다시 누른) 뒤 흐른 시간
        var releaseAge: Float = 0     // 뗀 뒤 흐른 시간
        var baseR: Float = 0          // 다시 눌렀을 때 이미 퍼져 있던 크기
        var tapGrow = false           // 톡 클릭처럼 덜 퍼진 채 뗐으면 표준 크기까지는 마저 퍼진 뒤 줄어든다
        var burstAt: Float = -1       // 이 나이가 되면 잔 물방울을 쏜다 (막 눌렀을 땐 본 방울이 조금 퍼진 뒤에)
        /// 타원 늘어남 e·(cos2φ, sin2φ): φ 방향으로 (1+e)배, 수직으로 1/(1+e)배 (넓이 유지)
        /// = 속도를 곧바로 따라가는 모양(shape) + 그 변화에 튕겨서 천천히 출렁이는 말랑함(wobble)
        var shape = SIMD2<Float>(0, 0)
        var wobble = SIMD2<Float>(0, 0)
        var wobbleVel = SIMD2<Float>(0, 0)
        var stretch: SIMD2<Float> {
            let s = shape + wobble
            let e = simd_length(s)
            return e > 0.9 ? s * (0.9 / e) : s
        }
    }

    /// 누르기·떼기 때 본 방울에서 튀어 나가는 잔 물방울. 커서와 상관없이 바깥으로 퍼지다 작아져 사라진다.
    /// 본 방울 가까이에선 목으로 이어져 있다가 멀어지며 끊긴다 (Metal은 셰이더의 부드러운 합집합, 유리는 GlassEffectContainer)
    struct Satellite {
        let id: Int
        let group: Int                // 튀어 나온 본 방울
        var pos: SIMD2<Float>
        let from: SIMD2<Float>
        let dir: SIMD2<Float>
        let dist: Float               // 나가는 거리 (강한 ease-out으로 거의 멈출 때까지)
        let r0: Float
        var r: Float
        var age: Float = 0
        let life: Float
    }

    /// 설정 탭 "물방울"의 손잡이들 (매 프레임 설정에서 다시 읽는다)
    struct Tuning {
        var maxR: Float = 48, tapR: Float = 32
        var grow: Float = 1, shrink: Float = 1
        var stretch: Float = 1, wobble: Float = 1
        var satellites = true
        var satCount: Float = 1, satSize: Float = 1, satDistance: Float = 1, neck: Float = 1
        var shadow: Float = 0.15, shadowSpread: Float = 1
        var scrollDust = false
        init() {}
        init(_ s: RainSettings) {
            maxR = Float(s.pressMaxRadius); tapR = min(Float(s.pressTapRadius), maxR)
            grow = Float(s.pressGrowSpeed); shrink = Float(s.pressShrinkSpeed)
            stretch = Float(s.pressStretch); wobble = Float(s.pressWobble)
            satellites = s.pressSatellites
            satCount = Float(s.pressSatelliteCount); satSize = Float(s.pressSatelliteSize)
            satDistance = Float(s.pressSatelliteDistance); neck = Float(s.pressNeck)
            shadow = Float(s.pressShadow); shadowSpread = Float(s.pressShadowSpread)
            scrollDust = s.pressScrollDust
        }
        /// 잔 물방울과 합쳐지는 거리 (목이 생기는 거리)
        var k: Float { maxR * 0.2 * neck }
    }

    private(set) var blobs: [Blob] = []
    private(set) var satellites: [Satellite] = []
    private var nextID = 0
    private var tune = Tuning()
    private var rMax: Float { tune.maxR }
    /// GPU로 올릴 데이터. 앞쪽은 본 방울 무리당 3개: (x, y, 반경, 알파), (늘어남 x, 늘어남 y, 잔 물방울 시작 번호, 개수),
    /// (그릴 반경, 합치는 거리 k, 그림자 진하기, 그림자 퍼짐). 그 뒤로 잔 물방울이 하나씩: (x, y, 반경, 0)
    private(set) var data: [SIMD4<Float>] = []
    private(set) var groupCount = 0
    private var monitor: Any?
    /// 스크롤 먼지: 스크롤한 거리를 모아 간격마다 하나씩, 너무 많아지지 않게 시간 간격도 둔다
    private var scrollAcc: Float = 0
    private var scrollNext: Float = 24
    private var lastDust: CFTimeInterval = 0
    /// 실제 마우스를 따라갈지 (스냅샷 도구에서는 끔)
    private var live = false
    var onActivity: (() -> Void)?

    var isActive: Bool { !blobs.isEmpty || !satellites.isEmpty }

    // MARK: 마우스

    /// 전역 마우스 이벤트 감시. 키보드와 달리 마우스 이벤트는 손쉬운 사용 권한 없이 받을 수 있다.
    /// 누르기를 무시해야 하나 (스크린샷 도구가 떠 있는 동안)
    var suppress: () -> Bool = { false }

    func startMonitoring() {
        guard monitor == nil else { return }
        live = true
        // 스크롤도 마우스 이벤트라 권한 없이 받을 수 있다
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] e in
            guard let self else { return }
            switch e.type {
            case .leftMouseDown:
                // 스크린샷 영역·창을 고르는 클릭은 물방울을 만들지 않는다 (찍히지 않게)
                if self.suppress() { return }
                self.begin(at: Self.mouseQuartz())
            case .leftMouseUp: self.end()
            case .scrollWheel:
                guard self.tune.scrollDust else { return }
                // 휠 마우스는 줄 단위라 pt로 대충 바꾼다. 화면에서 내용이 움직이는 방향 = (dx, dy) (y 아래)
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
                self.scroll(at: Self.mouseQuartz(), delta: SIMD2(Float(e.scrollingDeltaX * k), Float(e.scrollingDeltaY * k)))
                if self.satellites.isEmpty { return }
            default: return
            }
            self.onActivity?()
        }
    }

    func stopMonitoring() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        live = false
        blobs.removeAll()
        satellites.removeAll()
        data.removeAll()
        groupCount = 0
    }

    /// 현재 마우스 위치 (전역 Quartz 좌표: 주 화면 좌상단 원점, y 아래)
    static func mouseQuartz() -> SIMD2<Float> {
        let p = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return SIMD2(Float(p.x), Float(mainHeight - p.y))
    }

    // MARK: 누르기

    func begin(at p: SIMD2<Float>) {
        end()
        // 아직 오므라드는 중인 방울을 다시 누르면 그 방울이 다시 부푼다 (더블클릭). 최대 크기는 넘지 않게
        if let i = blobs.lastIndex(where: { simd_distance($0.pos, p) < max($0.r, 8) }) {
            blobs[i].held = true
            blobs[i].age = 0
            blobs[i].baseR = min(blobs[i].r, rMax)
            blobs[i].target = p
            burst(blobs[i], count: 3...4, rest: blobs[i].r)
            return
        }
        nextID += 1
        var b = Blob(id: nextID, pos: p, target: p)
        // 본 방울이 조금 퍼진 뒤 가장자리에서 떨어져 나가게 (바로 쏘면 이어진 목 없이 점만 생긴다)
        b.burstAt = 0.07
        blobs.append(b)
        if blobs.count > 6 { blobs.removeFirst() }
    }

    /// 스크롤할 때 본 방울 없이 커서 둘레에서 잔 물방울이 먼지처럼 흩날린다. 내용이 움직이는 방향으로,
    /// 빠를수록 멀리·많이. 사라지는 건 다른 잔 물방울과 같다
    func scroll(at p: SIMD2<Float>, delta: SIMD2<Float>, now: CFTimeInterval = CACurrentMediaTime()) {
        let len = simd_length(delta)
        guard len > 0.5 else { return }
        scrollAcc += len
        guard scrollAcc >= scrollNext, now - lastDust > 1.0 / 40 else { return }
        scrollAcc = 0
        scrollNext = Float.random(in: 18...32)
        lastDust = now
        let dir = delta / len
        let perp = SIMD2(-dir.y, dir.x)
        let a = Float.random(in: -0.4...0.4)
        let fly = SIMD2(dir.x * cos(a) - dir.y * sin(a), dir.x * sin(a) + dir.y * cos(a))
        let r0 = rMax * (0.03 + 0.09 * pow(Float.random(in: 0...1), 2)) * tune.satSize
        let start = p + perp * Float.random(in: -26...26) + dir * Float.random(in: -12...12)
        nextID += 1
        satellites.append(Satellite(id: nextID, group: 0, pos: start, from: start, dir: fly,
                                    dist: min(90, max(10, len * 2.5)) * Float.random(in: 0.6...1.2), r0: r0, r: r0,
                                    life: Float.random(in: 0.5...0.8)))
        trimSatellites()
    }

    /// 톡 클릭과 같은 물방울을 하나 띄운다 (키보드 Enter·포커스 이동). 누르고 있는 마우스 방울은 건드리지 않는다
    func tap(at p: SIMD2<Float>) {
        nextID += 1
        var b = Blob(id: nextID, pos: p, target: p)
        b.held = false
        b.tapGrow = true
        b.burstAt = 0.07
        blobs.append(b)
        if blobs.count > 6 { blobs.removeFirst() }
    }

    /// Enter로 채팅을 보냈을 때: 입력칸 가장자리 여기저기에서 잔 물방울이 톡톡 튀어 나가 흩어진다. 본 방울은 없다.
    /// (입력칸 모양 본 방울을 띄워 봤지만 오므라들든 옅어지든 어떻게 사라져도 부자연스러웠다). rect는 전역 Quartz 좌표
    func pop(rect: CGRect) {
        guard tune.satellites else { return }
        let hx = Float(rect.width / 2), hy = Float(rect.height / 2)
        let center = SIMD2(Float(rect.midX), Float(rect.midY))
        let perimeter = 4 * (hx + hy)
        let n = max(2, Int((Float(Int.random(in: 11...19)) * tune.satCount).rounded()))
        for _ in 0..<n {
            let s = Float.random(in: 0..<perimeter)
            // 위 → 오른쪽 → 아래 → 왼쪽 (y 아래)
            let p: SIMD2<Float>, nrm: SIMD2<Float>
            if s < 2 * hx { p = SIMD2(-hx + s, -hy); nrm = SIMD2(0, -1) }
            else if s < 2 * hx + 2 * hy { p = SIMD2(hx, -hy + (s - 2 * hx)); nrm = SIMD2(1, 0) }
            else if s < 4 * hx + 2 * hy { p = SIMD2(hx - (s - 2 * hx - 2 * hy), hy); nrm = SIMD2(0, 1) }
            else { p = SIMD2(-hx, hy - (s - 4 * hx - 2 * hy)); nrm = SIMD2(-1, 0) }
            // 모서리 쪽은 대각선으로 퍼지게 가운데에서 바깥 방향을 조금 섞는다
            let radial = simd_normalize(p / SIMD2(hx, hy))
            let a = Float.random(in: -0.35...0.35)
            let d0 = simd_normalize(nrm + radial * 0.5)
            let dir = SIMD2(d0.x * cos(a) - d0.y * sin(a), d0.x * sin(a) + d0.y * cos(a))
            // 크기는 작은 것부터 꽤 큰 것까지 (작은 쪽이 더 흔하게)
            let r0 = min(3 + 12 * pow(Float.random(in: 0...1), 1.4), max(hy, 4) * 0.9) * tune.satSize
            let start = center + p - nrm * r0 * 0.5
            nextID += 1
            satellites.append(Satellite(id: nextID, group: 0, pos: start, from: start, dir: dir,
                                        dist: Float.random(in: 8...50) * tune.satDistance,
                                        r0: r0, r: r0, life: Float.random(in: 0.4...0.7)))
        }
        trimSatellites()
        onActivity?()
    }

    func move(to p: SIMD2<Float>) {
        for i in blobs.indices where blobs[i].held { blobs[i].target = p }
    }

    func end() {
        for i in blobs.indices where blobs[i].held {
            blobs[i].held = false
            blobs[i].releaseAge = 0
            blobs[i].tapGrow = true
            // 톡 클릭은 누를 때 튄 것만으로 충분하다 (뗄 때도 튀면 방울이 너무 많아 보인다). 어느 정도 누르고 있었을 때만
            if blobs[i].age >= 0.4 { burst(blobs[i], count: 5...7, rest: blobs[i].r) }
        }
    }

    /// 본 방울 가장자리 안쪽에서 고르게(조금씩 흐트러뜨려) 잔 물방울을 쏜다.
    /// 본 방울이 아직 작으면 곧 퍼질 가장자리에서 쏜다 (가운데서 쏘면 퍼지는 본 방울에 붙어 울퉁불퉁해진다).
    /// rest: 이 기준 반경 바깥으로 목 길이(k) 안팎에서 멈추게 한다. 강한 ease-out으로 거기서 오래 머물러야
    /// 목이 늘어났다 끊기는 게 보인다 (빨리 멀리 날아가면 목이 한두 프레임 만에 끊겨 거의 안 보였다)
    private func burst(_ b: Blob, count: ClosedRange<Int>, rest: Float) {
        guard tune.satellites else { return }
        let n = Int((Float(Int.random(in: count)) * tune.satCount).rounded())
        guard n > 0 else { return }
        let a0 = Float.random(in: 0..<(2 * .pi))
        let k = tune.k
        for j in 0..<n {
            let a = a0 + Float(j) / Float(n) * 2 * .pi + Float.random(in: -0.45...0.45)
            let dir = SIMD2(cos(a), sin(a))
            // 대부분 작고, 가끔 두 배까지 크게
            let r0 = rMax * (0.07 + 0.23 * pow(Float.random(in: 0...1), 1.8)) * tune.satSize
            let rim = max(b.r, rMax * 0.32)
            let start = max(0, rim - r0) * 0.85
            let stop = rest + r0 + k * Float.random(in: 0.3...2.0) * tune.satDistance
            nextID += 1
            satellites.append(Satellite(id: nextID, group: b.id, pos: b.pos + dir * start, from: b.pos + dir * start,
                                        dir: dir, dist: max(4, stop - start), r0: r0, r: r0,
                                        life: Float.random(in: 0.5...0.8)))
        }
        trimSatellites()
    }

    private func trimSatellites() {
        if satellites.count > 100 { satellites.removeFirst(satellites.count - 100) }
    }

    // MARK: 갱신

    func update(dt: Float, settings s: RainSettings) {
        if live, blobs.contains(where: \.held) {
            if NSEvent.pressedMouseButtons & 1 == 0 {
                end()                                   // 떼는 이벤트를 놓쳤을 때
            } else {
                move(to: Self.mouseQuartz())            // 누른 채로 끌면 따라간다
            }
        }
        tune = Tuning(s)
        // 스프링이 발산하지 않도록 작은 스텝으로 나눠 적분
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Float(steps)
        for i in blobs.indices {
            // 위치는 커서에 바로 붙인다. 스프링으로 늦게 따라가게 했더니 휙 끌고 멈췄을 때 방울이 뒤늦게
            // 따라오느라 늘어난 채 버텨서 "한 박자 쉬고" 돌아왔다. 속도는 늘어남 계산용으로만 짧게 평활화한다
            let raw = (blobs[i].target - blobs[i].pos) / max(dt, 1e-4)
            blobs[i].pos = blobs[i].target
            blobs[i].vel += (raw - blobs[i].vel) * (1 - exp(-dt / 0.02))
            for _ in 0..<steps { step(&blobs[i], h, rMax: rMax) }
            if blobs[i].burstAt >= 0 && blobs[i].age >= blobs[i].burstAt {
                blobs[i].burstAt = -1
                burst(blobs[i], count: 5...7, rest: tune.tapR)
            }
        }

        // 잔 물방울: 강한 ease-out(5차)으로 바깥으로 퍼지다 거의 멈추고, 수명 끝으로 갈수록 빠르게 작아진다
        for i in satellites.indices {
            satellites[i].age += dt
            let t = min(1, satellites[i].age / satellites[i].life)
            let ease = 1 - pow(1 - t, 5)
            satellites[i].pos = satellites[i].from + satellites[i].dir * satellites[i].dist * ease
            // 처음 0.05초 동안 톡 부풀어 나온다 (본 방울 없이 생긴 잔 물방울이 갑자기 나타나지 않게)
            satellites[i].r = satellites[i].r0 * sqrt(min(1, satellites[i].age / 0.05)) * (1 - pow(t, 2.2))
        }
        satellites.removeAll { $0.age >= $0.life }
        // 본 방울은 자기 잔 물방울이 다 사라질 때까지 남긴다 (Metal에서 무리 단위로 그리므로)
        blobs.removeAll { b in
            !b.held && (b.releaseAge > 1.5 || (b.releaseAge > 0.1 && b.r < rMax * 0.04))
                && !satellites.contains { $0.group == b.id }
        }

        var heads: [SIMD4<Float>] = [], sats: [SIMD4<Float>] = []
        let k = tune.k
        // 그리는 사각형에 그림자가 번질 몫(아래로 비낀 4pt + 가장 넓게 번질 때)까지 더한다
        let pad = k + 4 + 4 + 21 * tune.shadowSpread * 1.5
        let look = SIMD2(tune.shadow, tune.shadowSpread)
        func single(_ m: Satellite) {
            heads.append(SIMD4(m.pos.x, m.pos.y, 0, 1))
            heads.append(SIMD4(0, 0, Float(sats.count), 1))
            heads.append(SIMD4(m.r + pad, k, look.x, look.y))
            sats.append(SIMD4(m.pos.x, m.pos.y, m.r, 0))
        }
        for b in blobs {
            // 아주 작아지면 옅어져서 점처럼 남지 않게
            let x = min(1, max(0, (b.r / rMax - 0.04) / 0.12))
            let alpha = x * x * (3 - 2 * x)
            let R: Float = alpha > 0 ? b.r : 0
            let rExt = R * (1 + simd_length(b.stretch))
            // 본 방울 근처(목이 생길 수 있는 거리)의 잔 물방울만 한 무리로 묶고, 멀리 떨어진 건 각자 작은 사각형으로 그린다.
            // (튄 뒤 본 방울을 끌고 멀리 가면 무리 사각형이 쓸데없이 커지고 픽셀마다 잔 물방울을 모두 계산하게 된다)
            var near: [Satellite] = []
            for m in satellites where m.group == b.id && m.r > 0.3 {
                if simd_distance(m.pos, b.pos) - m.r - rExt < k * 2 { near.append(m) } else { single(m) }
            }
            if alpha <= 0 && near.isEmpty { continue }
            var ext = rExt
            for m in near { ext = max(ext, simd_distance(m.pos, b.pos) + m.r) }
            heads.append(SIMD4(b.pos.x, b.pos.y, R, alpha))
            heads.append(SIMD4(b.stretch.x, b.stretch.y, Float(sats.count), Float(near.count)))
            heads.append(SIMD4(ext + pad, k, look.x, look.y))
            for m in near { sats.append(SIMD4(m.pos.x, m.pos.y, m.r, 0)) }
        }
        // 본 방울 없는 잔 물방울(스크롤 먼지)은 각자 작은 무리로
        let ids = Set(blobs.map(\.id))
        for m in satellites where m.r > 0.3 && !ids.contains(m.group) { single(m) }
        groupCount = heads.count / 3
        // 잔 물방울 번호는 머리 뒤에서부터
        for g in 0..<groupCount { heads[g * 3 + 1].z += Float(heads.count) }
        data = heads + sats
    }

    private func step(_ b: inout Blob, _ h: Float, rMax: Float) {
        b.age += h
        if !b.held { b.releaseAge += h }
        // 크기: 누르는 동안 처음엔 빠르게(살짝 넘쳤다가), 점점 느리게 퍼진다. 떼면 출렁임 없이 매끈하게 줄어든다.
        // (비눗방울처럼 커지며 옅어지게도 해 봤지만 리퀴드 글래스는 불투명도가 먹지 않아 툭 사라졌다)
        let tapR = tune.tapR
        if b.tapGrow && b.r >= tapR * 0.9 { b.tapGrow = false }
        let tr: Float, wr: Float, zr: Float
        if b.held {
            // 처음엔 톡 클릭 크기의 절반쯤으로 확 퍼지고, 점점 느리게 최대까지
            let start = min(tapR * 0.48, rMax)
            tr = max(b.baseR, start + (rMax - start) * (1 - exp(-b.age * tune.grow / 0.33)))
            wr = 24 * tune.grow; zr = 0.5
        } else if b.tapGrow {
            tr = tapR
            wr = 24 * tune.grow; zr = 0.6
        } else {
            tr = 0
            wr = 12 * tune.shrink; zr = 1
        }
        b.vr += ((tr - b.r) * wr * wr - b.vr * 2 * zr * wr) * h
        b.r = max(0, b.r + b.vr * h)

        // 늘어남: 끌면 움직이는 방향으로 길쭉해진다. 목표는 속도에 비례하다가 부드럽게 포화한다.
        // 모양은 목표를 곧바로(1차 지연) 따라가고, 모양이 바뀐 만큼 말랑함 진동자를 튕겨서 넘쳤다가 천천히 출렁이게 한다.
        // (진동자 하나로 모양 전체를 따라가게 하면, 멈춘 순간 늘어난 채 잠깐 버티다 돌아와서 "한 박자 쉬는" 느낌이 나고,
        //  그걸 줄이려 빠르게 하면 출렁임이 너무 급해진다)
        let v = b.vel
        let sp = simd_length(v)
        let eMax: Float = 0.7 * min(tune.stretch, 1.25)
        let eq = sp > 1 && eMax > 0.001
            ? SIMD2(v.x * v.x - v.y * v.y, 2 * v.x * v.y) / (sp * sp) * (eMax * tanh(sp * 0.0005 * tune.stretch / eMax)) : .zero
        let prev = b.shape
        b.shape += (eq - b.shape) * (1 - exp(-h / 0.022))
        // 뗀 뒤에는 출렁임 없이
        let ws: Float = 13
        let zs: Float = b.held ? 0.22 : 0.9
        if b.held { b.wobbleVel += (b.shape - prev) * 5 * tune.wobble }
        b.wobbleVel += (-b.wobble * ws * ws - b.wobbleVel * 2 * zs * ws) * h
        b.wobble += b.wobbleVel * h
    }
}
