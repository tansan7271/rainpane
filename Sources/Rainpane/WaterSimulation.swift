import Foundation
import CoreGraphics
import simd

// MARK: - 빠른 난수 (SystemRandomNumberGenerator보다 훨씬 가벼움)

struct FastRandom {
    private var state: UInt64
    init(seed: UInt64 = 0x9E3779B97F4A7C15) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    /// 0..<1
    mutating func float() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * float() }
}

// MARK: - 상태 타입

struct Rivulet {
    var flow: Float = 0       // 평활화된 유량 (pt²/s)
    var head: Float = 0       // 물줄기 머리가 윗변에서 내려온 거리
    var tail: Float = 0       // 물줄기 꼬리 (흐름이 멈추면 아래로 빠짐)
    var active = false
    var dripAcc: Float = 0    // 아래 모서리에 매달린 물방울에 모인 양
    var width: Float = 0      // 평활화된 물줄기 폭
    var connect: Float = 0    // 위쪽 모서리와 이어진 정도 0..1 (고인 물 셰이더와 물줄기 셰이더가 같은 값을 써서 이음매가 일치)
    var dripCooldown: Float = 0 // 다음 방울까지 남은 최소 간격 (방울이 줄지어 빽빽해지지 않게)
    var seed: Float

    init(seed: Float) { self.seed = seed }

    /// 한 방울이 떨어지는 데 필요한 양 (흐름이 세면 더 자주 떨어진다)
    var dropArea: Float { 22 }

    /// 매달린 방울 반경 (0이면 없음)
    var pendantRadius: Float {
        guard dripAcc > 0.3 else { return 0 }
        let full = (dropArea / .pi).squareRoot()
        return max(0.8, full * (0.45 + 0.55 * min(1, dripAcc / dropArea)).squareRoot())
    }

    /// 반환: 바닥 모서리에서 떨어뜨릴 물방울 개수
    mutating func update(spill: Float, length: Float, dt: Float) -> Int {
        // 넘침은 프레임마다 들쭉날쭉하므로 강하게 평활화하고, 켜짐/꺼짐에 히스테리시스를 둔다
        flow += (spill - flow) * min(1, dt * 2.5)
        if flow > 3 || (active && flow > 1) {
            if !active {
                active = true; head = 0; tail = 0
            } else if tail > 0 {
                tail = max(0, tail - 260 * dt)     // 다시 흐르면 위에서부터 채워진다
            }
            head = min(length, head + (70 + 12 * flow.squareRoot()) * dt)
        } else if active {
            tail += 220 * dt
            if tail >= head { active = false; head = 0; tail = 0; dripAcc = 0 }
        }
        var drips = 0
        dripCooldown = max(0, dripCooldown - dt)
        if active && head >= length && tail < length {
            // 유량이 늘수록 더 많이 떨어진다 (옆 물줄기 굵기에 민감하게)
            let gain = min(1.2 + flow / 80, 1.65)
            dripAcc += flow * dt * gain
            let area = dropArea
            // 방울 사이에 최소 간격을 둔다. 그 사이 모인 물은 다음 방울을 더 크게 만든다 (최대 2방울 분량)
            if dripAcc > area && dripCooldown <= 0 {
                drips = min(2, Int(dripAcc / area))
                dripAcc -= Float(drips) * area
                dripCooldown = 0.07 + 0.05 * abs(sin(seed * 12.9 + head * 0.37 + flow))
            }
            dripAcc = min(dripAcc, area * 2.5)
        } else if !active {
            dripAcc = max(0, dripAcc - dt * 1.5)     // 흐름이 끝나면 매달린 방울은 천천히 마른다
        }
        return drips
    }
}

final class Pool {
    let id: CGWindowID
    let pid: pid_t
    var frame: CGRect
    var rank: Int
    var n: Int
    var dx: Float
    var h: [Float]
    var q: [Float]
    var exposure: [Float]
    var spillL: Float = 0
    var spillR: Float = 0
    var left: Rivulet
    var right: Rivulet
    var lastSeen: CFTimeInterval = 0
    var visible = true
    /// 최소화 등으로 빨려 들어가는 중: 물은 원래 자리(frame)에 그대로 둔 채 숨긴다.
    /// 창이 그대로 사라지면 원래 자리에서 수막, 움직임이 멎고 남아 있으면 다시 보인다
    var frozen = false
    var seenFrame = CGRect.zero
    var lastChange: CFTimeInterval = 0

    // 운동 추정
    var lastOrigin: SIMD2<Float>
    var vel = SIMD2<Float>.zero
    var accel = SIMD2<Float>.zero
    var waterVY: Float = 0


    var dropletClock: Float = 0
    var lastAlpha: Float = 1
    var screen = 0            // 창 중심이 있는 모니터
    var kind: TrackedWindow.Kind = .normal   // 표면 종류 (모서리 반경 등)
    var wobblePhase = SIMD3<Float>(0, 0, 0)   // 느린 무작위 출렁임 (서로 다른 주기의 사인 합)

    init(window: TrackedWindow, rng: inout FastRandom) {
        id = window.id
        pid = window.pid
        kind = window.kind
        frame = window.frame
        rank = window.rank
        n = Pool.cellCount(for: Float(window.frame.width))
        dx = Float(window.frame.width) / Float(n)
        h = Array(repeating: 0, count: n)
        q = Array(repeating: 0, count: n + 1)
        exposure = Array(repeating: 1, count: n)
        left = Rivulet(seed: rng.range(0, 100))
        right = Rivulet(seed: rng.range(0, 100))
        lastOrigin = SIMD2(Float(window.frame.minX), Float(window.frame.minY))
        lastAlpha = window.alpha      // 열리는 애니메이션(투명도 상승)을 닫기로 오해하지 않게
        wobblePhase = SIMD3(rng.range(0, 6.28), rng.range(0, 6.28), rng.range(0, 6.28))
    }

    static func cellCount(for width: Float) -> Int { max(8, min(1600, Int(width / 3))) }

    var hasRivulet: Bool { left.active || right.active }

    var volume: Float { h.reduce(0, +) * dx }
    var averageHeight: Float { volume / max(Float(frame.width), 1) }

    /// 창 크기가 바뀌면 부피를 보존하며 재표본화
    func resize(to newFrame: CGRect) {
        let newN = Pool.cellCount(for: Float(newFrame.width))
        let newDx = Float(newFrame.width) / Float(newN)
        if newN != n {
            let vol = volume
            var nh = [Float](repeating: 0, count: newN)
            var ne = [Float](repeating: 1, count: newN)
            for j in 0..<newN {
                let t = (Float(j) + 0.5) / Float(newN) * Float(n) - 0.5
                let i0 = max(0, min(n - 1, Int(floor(t))))
                let i1 = min(n - 1, i0 + 1)
                let f = max(0, min(1, t - Float(i0)))
                nh[j] = h[i0] * (1 - f) + h[i1] * f
                ne[j] = exposure[min(n - 1, Int(Float(j) / Float(newN) * Float(n)))]
            }
            let nv = nh.reduce(0, +) * newDx
            if nv > 0.0001 { let s = vol / nv; for j in 0..<newN { nh[j] *= s } }
            h = nh; exposure = ne; n = newN
            q = Array(repeating: 0, count: newN + 1)
        }
        dx = newDx
        frame = newFrame
    }
}

struct Drip {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var r: Float
    var rank: Int
    var source: CGWindowID
    var screen: Int
    var wander: Float = 0     // 떨어질수록 커지는 제각각의 옆 방향 가속 (pt/s²)
    var startY: Float = 0
    var hitsSource = false    // 창에서 떨어져 나온 윗변 물방울: 자기 창 윗변에도 다시 떨어진다
}

struct Spray {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var r: Float
    var life: Float
    var rank: Int
    var screen: Int
}

struct GlassDrop {
    var win: CGWindowID
    var p: SIMD2<Float>        // 창 좌상단 기준 상대 좌표
    var r: Float
    var target: Float
    var v: Float = 0
    var pause: Float = 0
    var trail: Float = 0
    var trailNext: Float = 8
    var drift: Float = 0
    var bead = false
    var life: Float = 0
}

struct Curtain {
    var x0: Float, x1: Float, top: Float, bottom: Float
    var age: Float = 0
    var strength: Float
    var rank: Int
    var seed: Float
    var duration: Float
    var clipTop: Float        // 이보다 위에는 물이 없다 (이어받은 수막이 갑자기 길어지지 않도록)
    var screen: Int
}

/// GPU로 올릴 평탄화된 프레임 데이터 (전역 Quartz 좌표)
struct SimSnapshot {
    var pools: [SIMD4<Float>] = []       // 풀당 4개
    var heights: [Float] = []
    var rivulets: [SIMD4<Float>] = []    // 물줄기당 4개
    var drops: [SIMD4<Float>] = []       // 물방울당 2개
    var curtains: [SIMD4<Float>] = []    // 수막당 3개
    var edges: [SIMD4<Float>] = []       // 튀김용 선분당 2개
    var edgeLength: Float = 0
    /// 모니터별 마스크용 창 사각형 (뒤→앞 순서, 2개씩: 사각형, (전역 순위, 그 모니터 안에서의 순위))
    var screenRects: [[SIMD4<Float>]] = []
    var maskVersion = 0

    mutating func clear() {
        pools.removeAll(keepingCapacity: true)
        heights.removeAll(keepingCapacity: true)
        rivulets.removeAll(keepingCapacity: true)
        drops.removeAll(keepingCapacity: true)
        curtains.removeAll(keepingCapacity: true)
        edges.removeAll(keepingCapacity: true)
        edgeLength = 0
    }
}

// MARK: - 시뮬레이션

final class WaterSimulation {
    private(set) var pools: [CGWindowID: Pool] = [:]
    private var visiblePools: [Pool] = []
    private var windows: [TrackedWindow] = []
    private var windowVersion = -1
    private var pending: [CGWindowID: CFTimeInterval] = [:]
    private var forcedClose: Set<CGWindowID> = []
    /// 닫기 애니메이션 중인 창: 물은 이미 수막으로 흘려보냈으니, 사라질 때까지 무시한다
    private var closingAnim: Set<CGWindowID> = []
    private var massHideUntil: CFTimeInterval = 0
    var lastSpaceChange: CFTimeInterval = -100
    /// 이미 수막을 흘려보낸 창(최소화 시작, 가리기): 목록에서 사라질 때까지(최대 1.5초) 무시한다.
    /// 그 사이 다시 풀을 만들면 빨려 들어가는 창에 물이 새로 고이거나 사라질 때 수막이 한 번 더 생긴다
    private var goneSoon: [CGWindowID: CFTimeInterval] = [:]

    /// 가리기(⌘H): 알림이 오는 즉시 그 앱 창들의 물을 수막으로 흘려보낸다. 창이 한꺼번에 사라지면
    /// Space 전환으로 보고 물을 보관하는데, 사라진 뒤 판단하면 몇 프레임 늦게 흘러내렸다
    func appHidden(pid: pid_t, now: CFTimeInterval) {
        for (id, p) in pools where p.pid == pid && (p.visible || pending[id] != nil) {
            letGo(p, now: now)
        }
    }

    /// 창이 곧 사라진다: 지금 자리에서 물을 수막으로 흘려보내고 풀을 없앤다
    private func letGo(_ p: Pool, now: CFTimeInterval) {
        if currentSettings.curtain { spawnCurtain(from: p, settings: currentSettings) }
        releaseGlassDrops(of: p.id)
        pools.removeValue(forKey: p.id)
        pending.removeValue(forKey: p.id)
        visiblePools.removeAll { $0 === p }
        goneSoon[p.id] = now
    }

    private(set) var drips: [Drip] = []
    private var swayTime: Float = 0

    /// 떨어지는 물의 가로 초기 속도. 천천히 왼쪽으로 갔다가 돌아왔다가, 덜 갔다가 오른쪽으로 가며 은은하게 흔들린다.
    /// 중력만 받으면 궤적이 x ∝ √y (위에서 꺾이고 아래로 갈수록 곧아지는) 곡선이 된다.
    private func sway(seed: Float) -> Float {
        let t = swayTime
        return 55 * (sin(t * 0.9 + seed) * 0.6 + sin(t * 0.37 + seed * 2.1) * 0.4)
    }
    private(set) var sprays: [Spray] = []
    private(set) var glassDrops: [GlassDrop] = []
    private(set) var curtains: [Curtain] = []

    var screens: [CGRect] = []          // Quartz 좌표의 화면 사각형
    /// 스냅샷 도구에서 같은 결과를 다시 만들 때 (RAINPANE_SNAPSHOT_SEED)
    static var seedOverride: UInt64?
    private var rng = FastRandom(seed: WaterSimulation.seedOverride ?? UInt64(Date().timeIntervalSince1970 * 1000))
    private(set) var snapshot = SimSnapshot()

    private let gravity: Float = 2400

    /// 활동 중인 요소가 있으면 true (비가 멈춰도 렌더를 이어가야 하는지 판단)
    var isActive: Bool {
        if !drips.isEmpty || !sprays.isEmpty || !curtains.isEmpty { return true }
        if glassDrops.contains(where: { !$0.bead }) || !glassDrops.isEmpty { return true }
        for p in visiblePools {
            if p.left.active || p.right.active { return true }
            if p.q.contains(where: { abs($0) > 0.5 }) { return true }
        }
        return false
    }

    /// 부드러운 프레임이 필요한 빠른 움직임이 있는지 (적응형 FPS용)
    var needsSmoothMotion: Bool {
        !curtains.isEmpty
    }

    func clearAll() {
        pools.removeAll(); visiblePools.removeAll()
        drips.removeAll(); sprays.removeAll(); glassDrops.removeAll(); curtains.removeAll()
        pending.removeAll()
        forcedClose.removeAll()
        windowVersion = -1
    }

    // MARK: 창 목록 동기화

    /// overview: 미션 컨트롤·데스크톱 보기 중. 이때 사라진 창은 모두 "닫힘"으로 처리한다.
    func sync(windows newWindows: [TrackedWindow], version: Int, overview: Bool, now: CFTimeInterval, dt: Float) {
        // 숨겨 둔 창의 움직임이 멎었으면 창 목록이 그대로여도 다시 맞춘다 (그대로 남아 있으면 다시 보이게)
        let thaw = pools.values.contains { $0.frozen && now - $0.lastChange > 0.15 }
        guard version != windowVersion || thaw else {
            // 창 목록이 그대로면 속도는 0으로 감쇠
            for p in visiblePools { p.vel *= 0.5; p.accel = .zero }
            return
        }
        windowVersion = version
        let oldIDs = Set(windows.map(\.id))
        windows = newWindows
        let newIDs = Set(newWindows.map(\.id))

        // 사라진 창 → 보류 목록 (공간 전환인지 닫힘인지 잠깐 지켜본다)
        let vanished = oldIDs.subtracting(newIDs)
        if vanished.count >= 3 { massHideUntil = now + 0.5 }
        for id in vanished where pools[id] != nil {
            pending[id] = now
            if overview { forcedClose.insert(id) }
        }
        for id in newIDs { pending.removeValue(forKey: id); forcedClose.remove(id) }
        closingAnim = closingAnim.filter { newIDs.contains($0) }
        goneSoon = goneSoon.filter { newIDs.contains($0.key) && now - $0.value < 1.5 }

        visiblePools.removeAll(keepingCapacity: true)
        for w in newWindows {
            if goneSoon[w.id] != nil { continue }
            if closingAnim.contains(w.id) {
                if w.alpha < 0.99 { continue }       // 아직 사라지는 중
                closingAnim.remove(w.id)             // 다시 불투명해졌다면 닫기가 아니었음
            }
            let pool: Pool
            if let existing = pools[w.id] {
                // 닫기 애니메이션 시작(투명도가 떨어지기 시작함): 애니메이션을 기다리지 않고
                // 원래 크기 그대로의 물을 바로 수막으로 흘려보낸다
                if existing.visible && w.alpha < 0.97 && w.alpha < existing.lastAlpha - 0.03 {
                    if currentSettings.curtain { spawnCurtain(from: existing, settings: currentSettings) }
                    releaseGlassDrops(of: w.id)
                    pools.removeValue(forKey: w.id)
                    closingAnim.insert(w.id)
                    continue
                }
                existing.lastAlpha = w.alpha
                if existing.frozen {
                    if w.frame != existing.seenFrame { existing.seenFrame = w.frame; existing.lastChange = now }
                    if now - existing.lastChange <= 0.15 { continue }       // 아직 움직이는 중: 숨긴 채로
                    // 멎었는데 창이 남아 있다: 최소화가 아니었다 (앱 창 모아 보기·창 정리 애니메이션 등). 지금 자리에서 다시 보인다
                    existing.frozen = false
                    existing.lastOrigin = SIMD2(Float(w.frame.minX), Float(w.frame.minY))
                    existing.vel = .zero; existing.accel = .zero
                } else if existing.visible && Self.looksSuckedIn(from: existing.frame, to: w.frame) {
                    if Self.looksLikeGenie(from: existing.frame, to: w.frame) {
                        // 지니 최소화가 시작됐다: 기다리지 않고 원래 자리에서 바로 흘러내린다
                        letGo(existing, now: now)
                        continue
                    }
                    existing.frozen = true
                    existing.seenFrame = w.frame
                    existing.lastChange = now
                    continue
                }
                pool = existing
                let origin = SIMD2(Float(w.frame.minX), Float(w.frame.minY))
                let step = max(dt, 1.0 / 240)
                if pool.visible {
                    let raw = (origin - pool.lastOrigin) / step
                    let clampedRaw = simd_clamp(raw, SIMD2(repeating: -6000), SIMD2(repeating: 6000))
                    let newVel = pool.vel * 0.35 + clampedRaw * 0.65
                    pool.accel = simd_clamp((newVel - pool.vel) / step, SIMD2(repeating: -12000), SIMD2(repeating: 12000))
                    pool.vel = newVel
                    handleVerticalMotion(pool, oldY: pool.lastOrigin.y, newY: origin.y, oldX: pool.lastOrigin.x, dt: step)
                }
                pool.lastOrigin = origin
                if w.frame.size != pool.frame.size { pool.resize(to: w.frame) } else { pool.frame = w.frame }
                pool.rank = w.rank
                pool.kind = w.kind
            } else {
                pool = Pool(window: w, rng: &rng)
                pools[w.id] = pool
            }
            pool.visible = true
            pool.lastSeen = now
            pool.screen = screenIndex(of: CGPoint(x: w.frame.midX, y: w.frame.midY))
            visiblePools.append(pool)
        }
        // 목록에 없는 풀은 숨김 처리
        for (id, p) in pools where !newIDs.contains(id) { p.visible = false }

        computeExposure()
        buildRects()
    }

    /// 최소화(지니·축소)나 미션 컨트롤에 빨려 들어가기 시작하는지: 크기가 줄었는데 고정된 모서리가 하나도 없다.
    /// 사용자가 크기를 줄일 땐 늘 모서리 하나가 제자리다. 지니 효과는 처음 두 프레임 옆으로 미끄러지다가 셋째 프레임부터
    /// 아래 모서리를 둔 채 윗변이 내려오고 옆으로도 밀려서, 창이 크게 내려가 물이 튀기 전에 잡힌다
    /// (못 잡으면 빠르게 내려가는 창으로 보고 물을 방울로 흩뿌려서, 최소화에 수막이 거의 안 생겼다)
    static func looksSuckedIn(from old: CGRect, to new: CGRect) -> Bool {
        guard new.width < old.width - 0.5 || new.height < old.height - 0.5 else { return false }
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1.5 }
        let cornerFixed = (same(new.minX, old.minX) && same(new.minY, old.minY)) || (same(new.maxX, old.maxX) && same(new.maxY, old.maxY))
            || (same(new.minX, old.minX) && same(new.maxY, old.maxY)) || (same(new.maxX, old.maxX) && same(new.minY, old.minY))
        return !cornerFixed
    }

    /// 지니 최소화의 첫 모양: 폭은 거의 그대로, 아래 모서리는 제자리인 채 윗변만 내려온다 (실측: VSCode 폭 ±0·아래 ±0,
    /// 카카오톡 폭 −2·아래 −2). 미션 컨트롤·확대 해제는 가로세로가 함께 크게 줄어서 여기 걸리지 않는다
    static func looksLikeGenie(from old: CGRect, to new: CGRect) -> Bool {
        abs(new.width - old.width) <= 3 && new.height < old.height - 0.5 && new.minY > old.minY && abs(new.maxY - old.maxY) <= 3
    }

    /// 창이 중력보다 빨리 내려가면, 받침을 잃은 윗변의 물은 여러 방울로 흩어져 공중에 남는다.
    /// 방울은 떨어지다가 창 윗변(또는 그 아래 창)에 다시 닿으면 철푸덕 튀며 물웅덩이로 합쳐진다.
    private func handleVerticalMotion(_ p: Pool, oldY: Float, newY: Float, oldX: Float, dt: Float) {
        let drop = newY - oldY
        guard currentSettings.poolInertia, p.averageHeight > 0.15 else {
            p.waterVY = drop / dt
            return
        }
        let fallReach = p.waterVY * dt + 0.5 * gravity * dt * dt
        guard drop > fallReach + 1.5 else {
            p.waterVY = drop / dt
            return
        }
        // 6~10pt 구간마다 물을 모아 방울 하나로 (얇은 막 10%는 남긴다)
        var i = 0
        while i < p.n && drips.count < 1500 {
            let end = min(p.n, i + max(1, Int(rng.range(6, 10) / p.dx)))
            var vol: Float = 0
            for k in i..<end { vol += p.h[k] * p.dx * 0.9; p.h[k] *= 0.1 }
            if vol > 1.5 {
                let r = min(3.6, max(0.9, (vol / .pi).squareRoot()))
                let cx = oldX + (Float(i) + Float(end - i) * rng.float()) * p.dx
                drips.append(Drip(pos: SIMD2(cx, oldY - r * 0.8),
                                  vel: SIMD2(max(-150, min(150, p.vel.x * 0.3)) + rng.range(-25, 25), max(0, p.waterVY) + rng.range(0, 80)),
                                  r: r, rank: p.rank, source: p.id, screen: p.screen, hitsSource: true))
            }
            i = end
        }
        for k in 0...p.n { p.q[k] = 0 }
        p.spillL = 0; p.spillR = 0
        p.waterVY = drop / dt
    }

    /// 앞 창에 가려진 셀 계산. 새로 가려진 곳에 고여 있던 물은 앞 창 위로 수막이 되어 쓸려 내려간다.
    private func computeExposure() {
        var covers: [(a: Float, b: Float, rank: Int)] = []
        for p in visiblePools {
            let top = Float(p.frame.minY) - 1.5
            let x0 = Float(p.frame.minX)
            // 이 창 윗변 높이를 가로지르는 앞 창들의 가로 구간만 먼저 추린다 (앞 창부터: 처음 맞는 게 가장 앞)
            covers.removeAll(keepingCapacity: true)
            for w in windows where w.rank < p.rank {
                let f = w.frame
                if Float(f.minY) <= top && top <= Float(f.maxY) && Float(f.maxX) >= x0 && Float(f.minX) <= x0 + Float(p.frame.width) {
                    covers.append((Float(f.minX), Float(f.maxX), w.rank))
                }
            }
            var runStart = -1, runRank = 0
            var runVol: Float = 0
            func flush(_ end: Int) {
                guard runStart >= 0 else { return }
                let a = x0 + Float(runStart) * p.dx, b = x0 + Float(end) * p.dx
                sweepCovered(x0: a, x1: b, volume: runVol, top: Float(p.frame.minY), coverRank: runRank, pool: p)
                runStart = -1; runVol = 0
            }
            for i in 0..<p.n {
                let x = x0 + (Float(i) + 0.5) * p.dx
                var coverRank = -1
                for c in covers where c.a <= x && x <= c.b { coverRank = c.rank; break }
                let wasExposed = p.exposure[i] > 0
                p.exposure[i] = coverRank >= 0 ? 0 : 1
                if wasExposed && coverRank >= 0 && p.h[i] > 0.2 {
                    if runStart < 0 { runStart = i; runRank = coverRank }
                    runVol += p.h[i] * p.dx
                    p.h[i] = 0
                } else {
                    flush(i)
                }
            }
            flush(p.n)
        }
    }

    private func sweepCovered(x0: Float, x1: Float, volume: Float, top: Float, coverRank: Int, pool p: Pool) {
        let width = x1 - x0
        let avg = volume / max(width, 1)
        if width > 12 && avg > 0.3 && currentSettings.curtain {
            spawnCurtain(x0: x0, x1: x1, frontY: top, avgHeight: avg, rank: coverRank, velocity: 0, clipTop: top - avg - 2, screen: p.screen)
        } else if volume > 6 && currentSettings.drips {
            spawnDrip(at: SIMD2((x0 + x1) / 2, top), r: min(3.5, (volume / .pi).squareRoot()), rank: coverRank, source: p.id, screen: p.screen)
        }
    }

    func screenIndex(of point: CGPoint) -> Int {
        if let i = screens.firstIndex(where: { $0.contains(point) }) { return i }
        // 화면 밖이면 가장 가까운 화면
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, s) in screens.enumerated() {
            let dx = max(s.minX - point.x, 0, point.x - s.maxX), dy = max(s.minY - point.y, 0, point.y - s.maxY)
            if dx * dx + dy * dy < bestD { bestD = dx * dx + dy * dy; best = i }
        }
        return best
    }

    /// 모니터마다 그 모니터에 걸친 일반 창들만으로 순위를 다시 매긴다.
    /// 비는 이 "모니터 내 순위"를 쓰므로, 포커스와 상관없이 각 모니터의 맨 위 창에는 비가 보이지 않는다.
    /// 위젯은 254(바탕화면처럼 비가 전부 보임)이고, 일반 창 순위를 밀어내지 않는다.
    private func buildRects() {
        snapshot.screenRects = screens.map { screen in
            let onScreen = windows.filter { $0.frame.intersects(screen) }
            var local: [Float] = []
            var next: Float = 0
            for w in onScreen {
                if w.isWidget { local.append(254) }
                else { local.append(next); next += 1 }
            }
            var list: [SIMD4<Float>] = []
            for (i, w) in onScreen.enumerated().reversed() {
                list.append(SIMD4(Float(w.frame.minX), Float(w.frame.minY), Float(w.frame.width), Float(w.frame.height)))
                list.append(SIMD4(Float(w.rank), local[i], 0, 0))
            }
            return list
        }
        snapshot.maskVersion &+= 1
    }

    // MARK: 업데이트

    private var currentSettings = RainSettings()

    func update(dt rawDt: Float, now: CFTimeInterval, settings s: RainSettings, windSpeed: Float) {
        currentSettings = s
        swayTime = Float(fmod(now, 10000))
        let dt = min(rawDt, 1.0 / 20)
        let intensity = Float(s.intensity)

        resolvePending(now: now, settings: s)

        // 30분 이상 보이지 않은 풀 정리
        if Int(now) % 30 == 0 {
            pools = pools.filter { $0.value.visible || now - $0.value.lastSeen < 1800 }
        }

        for p in visiblePools {
            if s.pooling {
                simulatePool(p, dt: dt, settings: s, intensity: intensity)
            } else {
                for i in 0..<p.n { p.h[i] = 0 }
            }
            // 옆면 직선 끝 + 아래 모서리 곡선. 머리가 곡선도 따라 내려가야 곡선 부분이 한꺼번에 툭 생기지 않는다
            // (모서리가 크고 키가 작은 위젯에선 곡선이 물줄기 길이의 1/3쯤이라 눈에 띄었다)
            let R = effectiveRadius(p, s)
            let length = Float(p.frame.maxY) - R - Float(p.frame.minY) + Self.cornerRun(R)
            let spillScale: Float = s.streams ? 1 : 0
            // 창이 움직이는 동안은 옆 물줄기로 물이 공급되지 않아 위에서부터 빠지며 사라지고,
            // 물줄기에 있던 물은 방울이 되어 창의 움직임을 따라 주변으로 튄다
            let speed = simd_length(p.vel)
            let moving = speed > 250
            if moving && s.drips {
                for side in [Float(-1), Float(1)] {
                    let riv = side < 0 ? p.left : p.right
                    guard riv.active, riv.width > 0.5 else { continue }
                    let y0 = Float(p.frame.minY) + riv.tail, y1 = min(Float(p.frame.minY) + riv.head, Float(p.frame.maxY) - R)
                    guard y1 > y0 + 4 else { continue }
                    let rate = riv.width * (y1 - y0) / 100 * min(1, speed / 800) * 26
                    var k = Int(rate * dt)
                    if rng.float() < rate * dt - Float(k) { k += 1 }
                    let edgeX = side < 0 ? Float(p.frame.minX) : Float(p.frame.maxX)
                    for _ in 0..<min(k, 8) where drips.count < 1500 {
                        let pos = SIMD2(edgeX + side * riv.width * 0.5, rng.range(y0, y1))
                        let vel = p.vel * 0.5 + SIMD2(side * rng.range(20, 90) + rng.range(-40, 40), rng.range(-60, 40))
                        drips.append(Drip(pos: pos, vel: vel, r: rng.range(1.1, 2.2), rank: p.rank, source: p.id, screen: p.screen,
                                          wander: rng.range(-60, 60), startY: pos.y))
                    }
                }
            }
            let feed: Float = moving ? 0 : spillScale
            let dl = p.left.update(spill: p.spillL * feed, length: length, dt: dt)
            let dr = p.right.update(spill: p.spillR * feed, length: length, dt: dt)
            for (side, count) in [(Float(-1), dl), (Float(1), dr)] {
                var riv = side < 0 ? p.left : p.right
                let target: Float = (s.streams && riv.active && riv.tail < 1) ? 1 : 0
                riv.width += (rivuletWidth(riv, s) - riv.width) * min(1, dt * 4)
                riv.connect += (target - riv.connect) * min(1, dt * 8)

                if s.drips && count > 0 {
                    // 매달려 있던 방울 자리에서 그대로 떨어진다. 유량이 많으면 더 자주가 아니라 더 큰 방울로
                    let r = (riv.dropArea / .pi).squareRoot() * min(1.35, Float(count).squareRoot())
                    let c = pendantCenter(p, side: side, riv: riv, r: r)
                    spawnDrip(at: c, r: r, rank: p.rank, source: p.id, screen: p.screen,
                              vx: max(-150, min(150, p.vel.x * 0.3)) + sway(seed: riv.seed), wander: rng.range(-110, 110))
                }
                if side < 0 { p.left = riv } else { p.right = riv }
            }
        }

        updateGlassDrops(dt: dt, settings: s, intensity: intensity)
        updateDrips(dt: dt, windSpeed: windSpeed)
        updateSprays(dt: dt)
        updateCurtains(dt: dt)
        buildSnapshot(settings: s)
    }

    private func resolvePending(now: CFTimeInterval, settings s: RainSettings) {
        guard !pending.isEmpty else { return }
        // 한꺼번에 사라졌으면 가리기 알림이 늦게 올 경우를 위해 조금 더 기다린다(알림이 먼저 오면 이미 흘려보낸 뒤라 해당 없음).
        // 빨려 들어가다 사라진 창(숨겨 둔 풀)은 기다리지 않는다
        let wait = now < massHideUntil ? 0.25 : 0.1
        for (id, t) in pending where now - t > wait || forcedClose.contains(id) || (pools[id]?.frozen ?? false) {
            pending.removeValue(forKey: id)
            let forced = forcedClose.remove(id) != nil
            guard let p = pools[id] else { continue }
            let spaceSwitch = lastSpaceChange > t - 0.6 || now < massHideUntil
            if spaceSwitch && !forced { continue }   // 다른 Space로 간 창: 물은 보관
            // 창이 닫힘/최소화됨 → 고인 물이 화면을 타고 흘러내림
            // 미션 컨트롤·데스크톱 보기로 한꺼번에 사라진 창(forced)은 수막 없이 물만 사라진다
            // (창이 많으면 수막이 너무 과하고, 수막마다 화면 절반을 덮어 GPU가 한 프레임을 다 썼다)
            if s.curtain && !forced { spawnCurtain(from: p, settings: s) }
            releaseGlassDrops(of: id)
            pools.removeValue(forKey: id)
        }
    }

    private func simulatePool(_ p: Pool, dt: Float, settings s: RainSettings, intensity: Float) {
        let n = p.n
        let dx = p.dx
        let cap = Float(s.poolCapacity)
        let G: Float = 3000
        let rain = intensity * Float(s.accumulation) * 0.7
        let evap = Float(s.evaporation) * 0.08
        // 바람에 흔들리듯 느리게 변하는 기울임. 프레임마다 튀지 않도록 난수 대신 주기가 다른 사인의 합
        p.wobblePhase += SIMD3(0.43, 0.71, 1.13) * dt
        let wob = sin(p.wobblePhase.x) * 0.5 + sin(p.wobblePhase.y) * 0.3 + sin(p.wobblePhase.z) * 0.2
        let slosh = -p.accel.x * Float(s.sloshing) * 0.5 + wob * 160 * (0.3 + intensity) * Float(s.sloshing)

        // 빗방울 충돌: 충돌 지점 주변 몇 칸에 걸쳐 물을 바깥으로 밀어내 부드러운 파문이 퍼지게 한다.
        // (한 칸에만 주면 격자 크기의 잔떨림이 생겨 지직거린다)
        let impacts = (0.3 + intensity) * Float(p.frame.width) * 0.07 * dt
        var k = Int(impacts)
        if rng.float() < impacts - Float(k) { k += 1 }
        let weights: [Float] = [0.45, 0.33, 0.22]
        for _ in 0..<k {
            guard n > 8 else { break }
            let i = 4 + Int(rng.float() * Float(n - 8))
            let hl = p.h[i]
            if hl > 0.4 {
                let imp = rng.range(150, 330) * hl.squareRoot()
                for (j, w) in weights.enumerated() {
                    p.q[i + 1 + j] += imp * w
                    p.q[i - j] -= imp * w
                }
            }
        }

        let lipScale: Float = p.kind == .widget ? 1.25 : 1
        let steps = max(1, Int(ceil(dt / (1.0 / 120))))
        let sdt = dt / Float(steps)
        let damp = exp(-4 * sdt)
        var spillL: Float = 0, spillR: Float = 0

        p.h.withUnsafeMutableBufferPointer { h in
            p.q.withUnsafeMutableBufferPointer { q in
                p.exposure.withUnsafeBufferPointer { e in
                    for _ in 0..<steps {
                        for i in 0..<n {
                            h[i] = max(0, h[i] + (rain * e[i] - evap) * sdt)
                        }
                        // 가상 파이프 모델: 내부 경계 q[1..n-1]
                        for i in 1..<n {
                            let ha = 0.5 * (h[i - 1] + h[i])
                            if ha <= 0.0001 && h[i - 1] <= 0 && h[i] <= 0 { q[i] = 0; continue }
                            q[i] = q[i] * damp + sdt * (G * ha * (h[i - 1] - h[i]) / dx + slosh * ha)
                        }
                        q[0] = 0; q[n] = 0
                        // 음수 방지 스케일링
                        for i in 0..<n {
                            let out = max(q[i + 1], 0) + max(-q[i], 0)
                            let avail = h[i] * dx / sdt
                            if out > avail && out > 0 {
                                let sc = avail / out
                                if q[i + 1] > 0 { q[i + 1] *= sc }
                                if q[i] < 0 { q[i] *= sc }
                            }
                        }
                        for i in 0..<n {
                            h[i] = max(0, h[i] + sdt * (q[i] - q[i + 1]) / dx)
                        }
                        // 약한 점성: 격자 크기의 잔떨림만 빠르게 죽이고 긴 파도는 거의 그대로 둔다 (부피 보존)
                        var prev = h[0]
                        for i in 1..<(n - 1) {
                            let cur = h[i]
                            h[i] = cur + 0.03 * (prev - 2 * cur + h[i + 1])
                            prev = cur
                        }
                        // 양 끝 넘침. 짧은 표면은 물이 양 끝으로 금방 빠져 가장자리 높이에 머물고(긴 창은 가운데가 더 높이 찬다),
                        // 위젯은 모서리 곡선도 커서 얇아 보였다. 위젯만 넘치는 높이를 25% 올린다
                        let lip = cap * lipScale
                        if h[0] > lip {
                            let out = min((h[0] - lip) * 500, h[0] * dx / sdt)
                            h[0] -= out * sdt / dx; spillL += out / Float(steps)
                        }
                        if h[n - 1] > lip {
                            let out = min((h[n - 1] - lip) * 500, h[n - 1] * dx / sdt)
                            h[n - 1] -= out * sdt / dx; spillR += out / Float(steps)
                        }
                        // 과도한 수위 제한 (강한 출렁임 시)
                        for i in 0..<n where h[i] > cap * 1.6 * lipScale { h[i] = cap * 1.6 * lipScale }
                    }
                }
            }
        }
        p.spillL = spillL
        p.spillR = spillR
    }

    /// wander: 처음엔 부드러운 곡선으로 떨어지다가, 60pt쯤 아래부터 방울마다 제각각 옆으로 비껴가게 하는 가속
    private func spawnDrip(at pos: SIMD2<Float>, r: Float, rank: Int, source: CGWindowID, screen: Int, vx: Float = 0, wander: Float = 0) {
        guard drips.count < 1500 else { return }
        drips.append(Drip(pos: pos, vel: SIMD2(vx, rng.range(20, 60)), r: r, rank: rank, source: source, screen: screen,
                          wander: wander, startY: pos.y))
    }

    private func updateDrips(dt: Float, windSpeed: Float) {
        // 창에서 떨어져 나온 방울이 착지하지 못하고 그 창의 윗변 아래로 내려가면 수막으로 바뀐다 (창별로 모아서)
        var toCurtain: [CGWindowID: (x0: Float, x1: Float, area: Float, y: Float, vy: Float, n: Float, rank: Int, screen: Int)] = [:]
        var i = 0
        while i < drips.count {
            var d = drips[i]
            let prevY = d.pos.y
            d.vel.y = min(d.vel.y + gravity * dt, 2200)
            d.vel.x += (windSpeed * d.vel.y * 0.25 - d.vel.x) * min(1, dt * 0.6)
            if d.wander != 0 {
                let fallen = d.pos.y - d.startY
                let k = max(0, min(1, (fallen - 60) / 160))
                d.vel.x += d.wander * k * k * dt
            }
            d.pos += d.vel * dt
            var hit: Pool?
            var hitTop = Float.greatestFiniteMagnitude
            // 다른 모니터의 창에는 떨어지지 않는다
            for p in visiblePools where (p.id != d.source || d.hitsSource) && p.screen == d.screen {
                let top = Float(p.frame.minY)
                if prevY < top && d.pos.y >= top && top < hitTop
                    && d.pos.x >= Float(p.frame.minX) && d.pos.x <= Float(p.frame.maxX) {
                    let c = min(p.n - 1, max(0, Int((d.pos.x - Float(p.frame.minX)) / p.dx)))
                    if p.exposure[c] > 0 { hit = p; hitTop = top }
                }
            }
            if let p = hit {
                let c = min(p.n - 1, max(0, Int((d.pos.x - Float(p.frame.minX)) / p.dx)))
                if currentSettings.pooling {
                    p.h[c] += .pi * d.r * d.r / p.dx
                    // 철푸덕: 큰 방울이 빠르게 떨어질수록 물결을 세게 일으킨다
                    let imp = min(400, d.r * d.vel.y * 0.25)
                    if c > 1 && c < p.n - 1 { p.q[c] -= imp; p.q[c + 1] += imp }
                }
                if currentSettings.splashes {
                    let count = d.hitsSource ? Int(2 + d.r * 1.5 * min(1.5, d.vel.y / 500)) : 3
                    for _ in 0..<count {
                        let vy = rng.range(60, 200) * (d.hitsSource ? min(1.4, 0.7 + d.vel.y / 1200) : 1)
                        // 약 65%는 꼭대기를 지나면 곧 사라진다
                        let life = rng.float() < 0.65 ? vy / 1800 + rng.range(0.03, 0.08) : rng.range(0.25, 0.4)
                        sprays.append(Spray(pos: SIMD2(d.pos.x, hitTop - 2), vel: SIMD2(rng.range(-110, 110), -vy),
                                            r: rng.range(0.5, 1.1), life: life, rank: p.rank, screen: p.screen))
                    }
                }
                drips.swapAt(i, drips.count - 1); drips.removeLast()
                continue
            }
            // 창 앞면 위에 걸린 방울만 수막으로 (창 옆 허공으로 비껴간 방울은 그냥 방울로 계속 떨어진다)
            if d.hitsSource, let src = pools[d.source], src.visible, d.pos.y > Float(src.frame.minY) + 1,
               d.pos.x > Float(src.frame.minX) + 2, d.pos.x < Float(src.frame.maxX) - 2 {
                var gp = toCurtain[d.source] ?? (d.pos.x, d.pos.x, 0, 0, 0, 0, d.rank, d.screen)
                gp.x0 = min(gp.x0, d.pos.x - d.r); gp.x1 = max(gp.x1, d.pos.x + d.r)
                gp.area += .pi * d.r * d.r; gp.y += d.pos.y; gp.vy += d.vel.y; gp.n += 1
                toCurtain[d.source] = gp
                drips.swapAt(i, drips.count - 1); drips.removeLast()
                continue
            }
            let bottom = d.screen < screens.count ? Float(screens[d.screen].maxY) : 5000
            if d.pos.y > bottom + 30 {
                drips.swapAt(i, drips.count - 1); drips.removeLast()
                continue
            }
            drips[i] = d
            i += 1
        }
        guard currentSettings.curtain else { return }
        for (_, gp) in toCurtain {
            let x0 = gp.x0 - 10, x1 = gp.x1 + 10
            let y = gp.y / gp.n
            // 머리가 방울이 있던 자리에서 또렷하게 시작하도록, 위쪽 페이드는 그보다 충분히 위에서 시작
            spawnCurtain(x0: x0, x1: x1, frontY: y + 2, avgHeight: gp.area / (x1 - x0) * 1.5, rank: gp.rank,
                         velocity: gp.vy / gp.n, clipTop: y - 45, screen: gp.screen)
        }
    }

    private func updateSprays(dt: Float) {
        if sprays.count > 600 { sprays.removeFirst(sprays.count - 600) }
        var i = 0
        while i < sprays.count {
            sprays[i].life -= dt
            if sprays[i].life <= 0 { sprays.swapAt(i, sprays.count - 1); sprays.removeLast(); continue }
            sprays[i].vel.y += 1800 * dt
            sprays[i].pos += sprays[i].vel * dt
            i += 1
        }
    }

    // MARK: 창 유리 위를 흐르는 물방울

    private func updateGlassDrops(dt: Float, settings s: RainSettings, intensity: Float) {
        // 생성
        if s.windowDroplets {
            let frontNormal = windows.first { $0.kind == .normal }?.id
            for p in visiblePools where s.dropletsExceptFront ? p.id != frontNormal : (s.dropletsOnAllWindows || p.id == frontNormal) {
                guard p.frame.height > 110, p.frame.width > 110, !coversScreen(p.frame) else { continue }
                let fullness = min(1, p.averageHeight / max(0.5, Float(s.poolCapacity)) * 1.5)
                let wet = max(fullness, intensity > 0.01 ? 0.15 : 0)
                guard wet > 0.05 else { continue }
                let active = glassDrops.lazy.filter { $0.win == p.id && !$0.bead }.count
                guard active < 8 else { continue }
                p.dropletClock += dt * Float(s.dropletFrequency) * 0.7 * wet
                if p.dropletClock >= 1 || rng.float() < p.dropletClock * dt * 0.5 {
                    p.dropletClock = max(0, p.dropletClock - 1) * rng.float()
                    let R = Float(s.cornerRadius)
                    let x = rng.range(R + 16, Float(p.frame.width) - R - 16)
                    let target = rng.range(2.4, 4.6)
                    glassDrops.append(GlassDrop(win: p.id, p: SIMD2(x, 1.5), r: 0.6, target: target,
                                                pause: rng.range(0.4, 1.4), trailNext: rng.range(5, 12),
                                                drift: rng.range(-0.3, 0.3)))
                    // 고인 물에서 조금 빼 간다. 물방울은 폭과 상관없이 같은 빈도로 맺혀서, 좁은 위젯은 폭에 비해 훨씬 많이
                    // 빼앗겨 창보다 물이 얇게 고였다 (창은 그대로 두려고 위젯만 폭 400pt 기준으로 줄인다)
                    let c = min(p.n - 1, max(0, Int(x / p.dx)))
                    let share: Float = p.kind == .widget ? min(1, Float(p.frame.width) / 400) : 1
                    p.h[c] = max(0, p.h[c] - .pi * target * target / p.dx * 0.5 * share)
                }
            }
        }

        // 갱신
        var newBeads: [GlassDrop] = []
        var i = 0
        while i < glassDrops.count {
            var g = glassDrops[i]
            guard let p = pools[g.win] else {
                glassDrops.swapAt(i, glassDrops.count - 1); glassDrops.removeLast(); continue
            }
            if g.bead {
                g.life -= dt
                if g.life <= 0 { glassDrops.swapAt(i, glassDrops.count - 1); glassDrops.removeLast(); continue }
                glassDrops[i] = g; i += 1; continue
            }
            if g.r < g.target && g.v == 0 && g.p.y < 4 {
                g.r = min(g.target, g.r + 2.5 * dt)      // 천장에서 맺히는 중
                g.pause = max(g.pause, 0.05)
            }
            if g.pause > 0 {
                g.pause -= dt
                g.v *= max(0, 1 - 10 * dt)
            } else {
                g.v = min(g.v + 220 * (g.r - 1.6) * dt, 25 + 24 * g.r)
                if rng.float() < dt * 1.4 { g.pause = rng.range(0.05, 0.6) }
            }
            g.drift += rng.range(-1, 1) * dt
            g.drift = max(-0.4, min(0.4, g.drift))
            let dy = g.v * dt
            g.p.y += dy
            g.p.x += g.drift * dy * 0.25
            g.trail += dy
            if g.trail > g.trailNext {
                g.trail = 0
                g.trailNext = rng.range(5, 13)
                if rng.float() < 0.6 && newBeads.count + glassDrops.count < 320 {
                    let br = g.r * rng.range(0.2, 0.36)
                    newBeads.append(GlassDrop(win: g.win, p: g.p - SIMD2(0, g.r * 1.1), r: br, target: br,
                                              bead: true, life: rng.range(3, 8)))
                    let v3 = g.r * g.r * g.r - br * br * br
                    g.r = max(0.5, cbrt(v3))
                }
            }
            if g.r < 1.55 && g.v >= 0 && g.p.y > 6 {
                g.bead = true; g.life = rng.range(2, 6)
            }
            if g.p.y > Float(p.frame.height) - 3 {
                if s.drips {
                    spawnDrip(at: SIMD2(Float(p.frame.minX) + g.p.x, Float(p.frame.maxY)), r: g.r * 0.9, rank: p.rank, source: p.id, screen: p.screen, vx: max(-150, min(150, p.vel.x * 0.3)))
                }
                glassDrops.swapAt(i, glassDrops.count - 1); glassDrops.removeLast(); continue
            }
            glassDrops[i] = g
            i += 1
        }
        glassDrops.append(contentsOf: newBeads)
    }

    private func releaseGlassDrops(of id: CGWindowID) {
        guard let p = pools[id] else { return }
        for g in glassDrops where g.win == id && !g.bead {
            spawnDrip(at: SIMD2(Float(p.frame.minX) + g.p.x, Float(p.frame.minY) + g.p.y), r: g.r, rank: p.rank, source: id, screen: p.screen)
        }
        glassDrops.removeAll { $0.win == id }
    }

    private func coversScreen(_ f: CGRect) -> Bool {
        screens.contains { f.insetBy(dx: -2, dy: -2).contains($0) }
    }

    // MARK: 수막

    private func spawnCurtain(from p: Pool, settings s: RainSettings) {
        let avg = p.averageHeight + (p.left.active ? 0.3 : 0) + (p.right.active ? 0.3 : 0)
        let x0 = Float(p.frame.minX)
        let front = Float(p.frame.minY)
        spawnCurtain(x0: x0, x1: x0 + Float(p.frame.width), frontY: front,
                     avgHeight: avg, rank: p.rank, velocity: 0, clipTop: front - Float(s.poolCapacity) * 2.5, screen: p.screen)
    }

    /// velocity: 이미 떨어지던 물이면 그 속도에서 이어지도록 셰이더의 낙하 곡선 시점을 맞춘다
    private func spawnCurtain(x0: Float, x1: Float, frontY: Float, avgHeight: Float, rank: Int, velocity: Float, clipTop: Float, screen: Int) {
        guard avgHeight > 0.25 else { return }
        let strength = min(1.6, avgHeight / max(1, Float(currentSettings.poolCapacity))) * Float(currentSettings.curtainStrength)
        guard strength > 0.02 else { return }
        // 셰이더와 같은 낙하 모델: fall(τ) = vt·(τ − (1 − e^(−kτ))/k)
        let vt: Float = 900, k: Float = 2.5
        let ratio = min(max(velocity, 0) / vt, 0.9)
        let tau0 = -log(1 - ratio) / k
        let fall0 = vt * (tau0 - (1 - exp(-k * tau0)) / k)
        let bottom = screen < screens.count ? Float(screens[screen].maxY) : frontY + 1500
        let dist = max(100, bottom - frontY)
        let duration = tau0 + min(8, 0.9 + dist / 700 + 2.2)
        curtains.append(Curtain(x0: x0, x1: x1, top: frontY - fall0, bottom: bottom, age: tau0,
                                strength: strength, rank: rank, seed: rng.range(0, 500), duration: duration,
                                clipTop: clipTop, screen: screen))
        if curtains.count > 24 { curtains.removeFirst() }
    }

    /// 모서리 곡선이 차지하는 길이. macOS 창은 원호가 아니라 연속 곡률(squircle)이라 반경보다 길게 휜다.
    func effectiveRadius(_ p: Pool, _ s: RainSettings) -> Float {
        let radius = p.kind == .widget ? s.widgetCornerRadius : s.cornerRadius
        let extent = Float(radius) * (1 + 0.5 * Float(s.cornerSmoothness))
        return min(extent, Float(p.frame.width) * 0.5, Float(p.frame.height) * 0.5)
    }

    static func cornerExponent(_ s: RainSettings) -> Float { 2 + 3 * Float(s.cornerSmoothness) }

    /// 물줄기가 아래 모서리를 돌아 밑변을 따라 안쪽으로 들어가는 거리
    /// 물줄기가 아래 모서리 곡선을 따라 도는 끝 각도 (옆면 0° → 밑변 90°). 셰이더의 `kDripAngle`과 같아야 한다.
    /// 물줄기 머리가 위쪽 모서리 곡선을 얼마나 돌았나 (0 = 시작 전, 1 = 곡선 끝, 그 뒤로는 1.2).
    /// 머리는 윗변에서 내려온 세로 거리라, 원호로 보고 각도 비율로 바꾼다. 고인 물 셰이더가 이 만큼만 물줄기 폭으로 굵힌다
    /// (곡선 전체를 한꺼번에 굵혔더니, 물줄기가 곡선을 다 돌기 전까지 곡선 끝이 수평으로 칼같이 잘린 채 보였다)
    private func cornerReach(_ riv: Rivulet, _ R: Float) -> Float {
        guard riv.active, R > 0.5 else { return 0 }
        if riv.head >= R { return 1.2 }
        return acos(max(-1, 1 - riv.head / R)) / (.pi / 2)
    }

    static let dripAngle: Float = 65 * .pi / 180
    /// 물줄기 머리가 아래 모서리 곡선을 따라 가는 거리. 곡선 길이(≈ R × 65°)보다 25% 더 가야 셰이더에서 곡선 끝까지 다 그려진다
    static func cornerRun(_ R: Float) -> Float { R * dripAngle * 1.25 }

    /// 물이 떨어지는 지점: 아래 모서리 곡선 위, 밑변 쪽으로 65° 돈 곳 (초타원 매개변수)
    private func dripPoint(_ p: Pool, side: Float) -> SIMD2<Float> {
        let E = effectiveRadius(p, currentSettings)
        let n = Self.cornerExponent(currentSettings)
        let edgeX = side < 0 ? Float(p.frame.minX) : Float(p.frame.maxX)
        let cx = edgeX - side * E, cy = Float(p.frame.maxY) - E
        let dx = E * pow(cos(Self.dripAngle), 2 / n), dy = E * pow(sin(Self.dripAngle), 2 / n)
        return SIMD2(cx + side * dx, cy + dy)
    }

    /// 물줄기 끝에 매달린 방울 중심 (끝으로 갈수록 물줄기가 가늘어져 끝 폭은 절반)
    private func pendantCenter(_ p: Pool, side: Float, riv: Rivulet, r: Float) -> SIMD2<Float> {
        let outward = SIMD2<Float>(side * 0.42, 0.91)
        return dripPoint(p, side: side) + outward * (riv.width * 0.25) + SIMD2(0, r * 0.75)
    }

    private func rivuletWidth(_ r: Rivulet, _ s: RainSettings) -> Float {
        max(1.2, min(6, 0.32 * r.flow.squareRoot())) * Float(s.streamWidth)
    }

    private func updateCurtains(dt: Float) {
        for i in curtains.indices { curtains[i].age += dt }
        curtains.removeAll { $0.age > $0.duration }
    }

    // MARK: 스냅샷

    private func buildSnapshot(settings s: RainSettings) {
        snapshot.clear()
        let cap = Float(s.poolCapacity)
        // 닫힘 판정 대기 중인 창의 물도 잠깐 계속 그린다 (깜빡임 방지)
        let pendingPools = pending.keys.compactMap { pools[$0] }.filter { !$0.frozen }   // 빨려 들어간 창의 물은 다시 그리지 않는다
        for p in visiblePools + pendingPools {
            let isPending = !p.visible
            let R = effectiveRadius(p, s)
            let enc = Self.encode(rank: p.rank, screen: p.screen)
            // 모서리에서 옆면 물줄기로 이어지는 폭 (시뮬레이션에서 서서히 변하도록 평활화됨)
            let joinL: Float = p.left.width * p.left.connect
            let joinR: Float = p.right.width * p.right.connect
            // 물 높이 + 튀김용 노출 선분
            let maxH = min(cap * 1.6, (p.h.max() ?? 0))
            if maxH > 0.2 || joinL > 0.2 || joinR > 0.2 {
                let offset = Float(snapshot.heights.count)
                snapshot.heights.append(contentsOf: p.h)
                snapshot.pools.append(SIMD4(Float(p.frame.minX), Float(p.frame.minY), Float(p.frame.width), enc))
                snapshot.pools.append(SIMD4(offset, Float(p.n), p.dx, 1))
                snapshot.pools.append(SIMD4(joinL, joinR, R, max(maxH, joinL, joinR)))
                snapshot.pools.append(SIMD4(cornerReach(p.left, R), cornerReach(p.right, R), 0, 0))
            }
            if isPending { continue }
            appendEdges(p, R: R)
            // 옆면 물줄기와 아래 모서리에 매달린 방울
            for (riv, side) in [(p.left, Float(-1)), (p.right, Float(1))] {
                let top = Float(p.frame.minY)
                let endY = Float(p.frame.maxY) - R      // 옆면 직선이 끝나는 곳
                if riv.active && riv.width > 0.3 {
                    let edgeX = side < 0 ? Float(p.frame.minX) : Float(p.frame.maxX)
                    snapshot.rivulets.append(SIMD4(edgeX, top, Float(p.frame.maxY), side))
                    // 머리는 옆면 끝을 지나 모서리 곡선 쪽으로 이어질 수 있다 (셰이더가 곡선 진행으로 읽는다)
                    snapshot.rivulets.append(SIMD4(top + riv.head, top + riv.tail, riv.width, enc))
                    snapshot.rivulets.append(SIMD4(riv.seed, min(1, riv.flow / 150), R, 0))
                    snapshot.rivulets.append(SIMD4(riv.connect, 0, 0, 0))
                }
                let pr = riv.pendantRadius
                if s.drips && pr > 0 && (!riv.active || riv.head >= endY - top + Self.cornerRun(R) - 0.5) {
                    let c = pendantCenter(p, side: side, riv: riv, r: pr)
                    snapshot.drops.append(SIMD4(c.x, c.y, pr, 1))
                    snapshot.drops.append(SIMD4(0, 1, 1.15, enc))
                }
            }
        }

        // 바탕화면 바닥 (화면 아래쪽) 튀김
        if s.desktopRain > 0.05 {
            for sc in screens {
                // 화면 바닥은 Dock 등에 가려지기 쉬우니 창 윗변보다 낮은 비중
                let weight: Float = 0.25
                let idx = screens.firstIndex(of: sc) ?? 0
                snapshot.edges.append(SIMD4(Float(sc.minX), Float(sc.maxX), Float(sc.maxY) - 1, Self.encode(rank: 255, screen: idx)))
                snapshot.edges.append(SIMD4(snapshot.edgeLength, weight, 0, 0))
                snapshot.edgeLength += Float(sc.width) * weight
            }
        }

        // 물방울들
        for d in drips {
            let speed = simd_length(d.vel)
            let dir = speed > 1 ? d.vel / speed : SIMD2<Float>(0, 1)
            snapshot.drops.append(SIMD4(d.pos.x, d.pos.y, d.r, 1))
            // 작은 방울은 빠를수록 길게 늘어나 연달아 떨어질 때 물줄기처럼 이어진다
            let stretch = min(10, 1 + speed * 0.0045 / max(d.r, 0.8))
            snapshot.drops.append(SIMD4(dir.x, dir.y, stretch, Self.encode(rank: d.rank, screen: d.screen)))
        }
        for sp in sprays {
            let speed = simd_length(sp.vel)
            let dir = speed > 1 ? sp.vel / speed : SIMD2<Float>(0, 1)
            snapshot.drops.append(SIMD4(sp.pos.x, sp.pos.y, sp.r, -min(1, sp.life * 5)))   // 음수 알파 = 튀김(연하게)
            snapshot.drops.append(SIMD4(dir.x, dir.y, 1 + min(2, speed * 0.004), Self.encode(rank: sp.rank, screen: sp.screen)))
        }
        for g in glassDrops {
            guard let p = pools[g.win], p.visible else { continue }
            let wx = Float(p.frame.minX) + g.p.x
            let wy = Float(p.frame.minY) + g.p.y
            let alpha: Float = g.bead ? min(1, g.life / 1.5) : 1
            let stretch: Float = g.bead ? 1.0 : 1.15 + min(0.9, g.v * 0.012)
            snapshot.drops.append(SIMD4(wx, wy, g.r, alpha))
            snapshot.drops.append(SIMD4(0, 1, stretch, Self.encode(rank: p.rank, screen: p.screen)))
        }
        for c in curtains {
            snapshot.curtains.append(SIMD4(c.x0, c.x1, c.top, c.bottom))
            snapshot.curtains.append(SIMD4(c.age, c.strength, Self.encode(rank: c.rank, screen: c.screen), c.seed))
            snapshot.curtains.append(SIMD4(c.duration, c.clipTop, 0, 0))
        }
    }

    /// 순위와 소속 모니터를 float 하나에 담는다 (셰이더에서 다른 모니터 요소는 버림)
    static func encode(rank: Int, screen: Int) -> Float { Float(min(rank, 255) + 256 * screen) }

    private func appendEdges(_ p: Pool, R: Float) {
        let x0 = Float(p.frame.minX)
        let top = Float(p.frame.minY)
        var runStart = -1
        var sum: Float = 0
        func flush(_ end: Int) {
            guard runStart >= 0 else { return }
            let a = x0 + Float(runStart) * p.dx
            let b = x0 + Float(end) * p.dx
            let lo = max(a, x0 + R * 0.6), hi = min(b, x0 + Float(p.frame.width) - R * 0.6)
            if hi - lo > 8 {
                let avg = sum / Float(max(1, end - runStart))
                snapshot.edges.append(SIMD4(lo, hi, top - avg, Self.encode(rank: p.rank, screen: p.screen)))
                snapshot.edges.append(SIMD4(snapshot.edgeLength, 1, 0, 0))
                snapshot.edgeLength += hi - lo
            }
            runStart = -1; sum = 0
        }
        for i in 0..<p.n {
            if p.exposure[i] > 0 {
                if runStart < 0 { runStart = i }
                sum += p.h[i]
            } else { flush(i) }
        }
        flush(p.n)
    }

    /// 화면을 완전히 덮은 맨 앞 창이 있는지
    func screenIsCovered(_ screen: CGRect) -> Bool {
        guard let front = windows.first(where: { $0.kind == .normal }) else { return false }
        return front.frame.insetBy(dx: -2, dy: -2).contains(screen)
    }
}
