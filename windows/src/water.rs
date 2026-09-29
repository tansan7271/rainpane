// 물 시뮬레이션: 맥판 WaterSimulation.swift를 옮긴 것.
// 다른 점: 창이 사라진 이유를 윈도우가 알려 준다 (닫힘, 최소화, 다른 가상 데스크톱). 그래서 맥판의
// 지니·미션 컨트롤 짐작과 사라진 뒤 잠깐 지켜보는 대기가 없다.

use std::collections::{HashMap, HashSet};
use std::f32::consts::PI;

use crate::settings::{CORNER_EXPONENT, Settings};
use crate::tracker::{Kind, Monitor, Vanish, Win};
use crate::v2::{Rng, V2, v2};

const GRAVITY: f32 = 2400.0;
/// 물줄기가 아래 모서리 곡선을 따라 도는 끝 각도 (옆면 0° → 밑변 90°). 셰이더의 kDripAngle과 같아야 한다.
const DRIP_ANGLE: f32 = 65.0 * PI / 180.0;

#[derive(Clone)]
struct Rivulet {
    flow: f32,
    head: f32,
    tail: f32,
    active: bool,
    drip_acc: f32,
    width: f32,
    connect: f32,
    drip_cooldown: f32,
    seed: f32,
}

impl Rivulet {
    fn new(seed: f32) -> Rivulet {
        Rivulet { flow: 0.0, head: 0.0, tail: 0.0, active: false, drip_acc: 0.0, width: 0.0, connect: 0.0, drip_cooldown: 0.0, seed }
    }
    /// 한 방울이 떨어지는 데 필요한 양
    fn drop_area(&self) -> f32 {
        22.0
    }
    /// 매달린 방울 반경 (0이면 없음)
    fn pendant_radius(&self) -> f32 {
        if self.drip_acc <= 0.3 {
            return 0.0;
        }
        let full = (self.drop_area() / PI).sqrt();
        (full * (0.45 + 0.55 * (self.drip_acc / self.drop_area()).min(1.0)).sqrt()).max(0.8)
    }
    /// 반환: 바닥 모서리에서 떨어뜨릴 물방울 개수
    fn update(&mut self, spill: f32, length: f32, dt: f32) -> i32 {
        // 넘침은 프레임마다 들쭉날쭉하므로 강하게 평활화하고, 켜짐/꺼짐에 히스테리시스를 둔다
        self.flow += (spill - self.flow) * (dt * 2.5).min(1.0);
        if self.flow > 3.0 || (self.active && self.flow > 1.0) {
            if !self.active {
                self.active = true;
                self.head = 0.0;
                self.tail = 0.0;
            } else if self.tail > 0.0 {
                self.tail = (self.tail - 260.0 * dt).max(0.0);
            }
            self.head = length.min(self.head + (70.0 + 12.0 * self.flow.sqrt()) * dt);
        } else if self.active {
            self.tail += 220.0 * dt;
            if self.tail >= self.head {
                self.active = false;
                self.head = 0.0;
                self.tail = 0.0;
                self.drip_acc = 0.0;
            }
        }
        let mut drips = 0;
        self.drip_cooldown = (self.drip_cooldown - dt).max(0.0);
        if self.active && self.head >= length && self.tail < length {
            let gain = (1.2 + self.flow / 80.0).min(1.65);
            self.drip_acc += self.flow * dt * gain;
            let area = self.drop_area();
            // 방울 사이에 최소 간격을 둔다. 그 사이 모인 물은 다음 방울을 더 크게 만든다 (최대 2방울 분량)
            if self.drip_acc > area && self.drip_cooldown <= 0.0 {
                drips = 2.min((self.drip_acc / area) as i32);
                self.drip_acc -= drips as f32 * area;
                self.drip_cooldown = 0.07 + 0.05 * (self.seed * 12.9 + self.head * 0.37 + self.flow).sin().abs();
            }
            self.drip_acc = self.drip_acc.min(area * 2.5);
        } else if !self.active {
            self.drip_acc = (self.drip_acc - dt * 1.5).max(0.0);
        }
        drips
    }
}

struct Pool {
    id: isize,
    /// (x, y, w, h) pt
    frame: [f32; 4],
    rank: u32,
    /// 창 목록(앞에서 뒤)에서의 자리
    zi: usize,
    n: usize,
    dx: f32,
    h: Vec<f32>,
    q: Vec<f32>,
    exposure: Vec<f32>,
    spill_l: f32,
    spill_r: f32,
    left: Rivulet,
    right: Rivulet,
    last_seen: f64,
    visible: bool,
    last_origin: V2,
    vel: V2,
    accel: V2,
    water_vy: f32,
    droplet_clock: f32,
    screen: usize,
    wobble: [f32; 3],
}

fn cell_count(width: f32) -> usize {
    ((width / 3.0) as usize).clamp(8, 1600)
}

impl Pool {
    fn new(w: &Win, zi: usize, rng: &mut Rng) -> Pool {
        let n = cell_count(w.rect[2]);
        Pool {
            id: w.hwnd,
            frame: w.rect,
            rank: w.rank,
            zi,
            n,
            dx: w.rect[2] / n as f32,
            h: vec![0.0; n],
            q: vec![0.0; n + 1],
            exposure: vec![1.0; n],
            spill_l: 0.0,
            spill_r: 0.0,
            left: Rivulet::new(rng.range(0.0, 100.0)),
            right: Rivulet::new(rng.range(0.0, 100.0)),
            last_seen: 0.0,
            visible: true,
            last_origin: v2(w.rect[0], w.rect[1]),
            vel: V2::default(),
            accel: V2::default(),
            water_vy: 0.0,
            droplet_clock: 0.0,
            screen: 0,
            wobble: [rng.range(0.0, 6.28), rng.range(0.0, 6.28), rng.range(0.0, 6.28)],
        }
    }
    fn x(&self) -> f32 {
        self.frame[0]
    }
    fn y(&self) -> f32 {
        self.frame[1]
    }
    fn w(&self) -> f32 {
        self.frame[2]
    }
    fn ht(&self) -> f32 {
        self.frame[3]
    }
    fn max_x(&self) -> f32 {
        self.frame[0] + self.frame[2]
    }
    fn max_y(&self) -> f32 {
        self.frame[1] + self.frame[3]
    }
    fn volume(&self) -> f32 {
        self.h.iter().sum::<f32>() * self.dx
    }
    fn average_height(&self) -> f32 {
        self.volume() / self.w().max(1.0)
    }
    /// 창 크기가 바뀌면 부피를 보존하며 재표본화
    fn resize(&mut self, frame: [f32; 4]) {
        let new_n = cell_count(frame[2]);
        let new_dx = frame[2] / new_n as f32;
        if new_n != self.n {
            let vol = self.volume();
            let n = self.n;
            let mut nh = vec![0.0f32; new_n];
            let mut ne = vec![1.0f32; new_n];
            for j in 0..new_n {
                let t = (j as f32 + 0.5) / new_n as f32 * n as f32 - 0.5;
                let i0 = (t.floor().max(0.0) as usize).min(n - 1);
                let i1 = (i0 + 1).min(n - 1);
                let f = (t - i0 as f32).clamp(0.0, 1.0);
                nh[j] = self.h[i0] * (1.0 - f) + self.h[i1] * f;
                ne[j] = self.exposure[((j as f32 / new_n as f32 * n as f32) as usize).min(n - 1)];
            }
            let nv: f32 = nh.iter().sum::<f32>() * new_dx;
            if nv > 0.0001 {
                let s = vol / nv;
                for x in nh.iter_mut() {
                    *x *= s;
                }
            }
            self.h = nh;
            self.exposure = ne;
            self.n = new_n;
            self.q = vec![0.0; new_n + 1];
        }
        self.dx = new_dx;
        self.frame = frame;
    }
}

struct Drip {
    pos: V2,
    vel: V2,
    r: f32,
    rank: u32,
    source: isize,
    screen: usize,
    /// 떨어질수록 커지는 제각각의 옆 방향 가속
    wander: f32,
    start_y: f32,
    /// 창에서 떨어져 나온 윗변 물방울: 자기 창 윗변에도 다시 떨어진다
    hits_source: bool,
}

struct Spray {
    pos: V2,
    vel: V2,
    r: f32,
    life: f32,
    rank: u32,
    screen: usize,
}

struct GlassDrop {
    win: isize,
    /// 창 좌상단 기준 상대 좌표
    p: V2,
    r: f32,
    target: f32,
    v: f32,
    pause: f32,
    trail: f32,
    trail_next: f32,
    drift: f32,
    bead: bool,
    life: f32,
}

struct Curtain {
    x0: f32,
    x1: f32,
    top: f32,
    bottom: f32,
    age: f32,
    strength: f32,
    rank: u32,
    seed: f32,
    duration: f32,
    clip_top: f32,
    screen: usize,
}

/// GPU로 올릴 평탄화된 프레임 데이터
#[derive(Default)]
pub struct Snapshot {
    pub pools: Vec<[f32; 4]>,
    pub heights: Vec<f32>,
    pub rivulets: Vec<[f32; 4]>,
    pub drops: Vec<[f32; 4]>,
    pub curtains: Vec<[f32; 4]>,
    pub edges: Vec<[f32; 4]>,
    pub edge_length: f32,
}

impl Snapshot {
    fn clear(&mut self) {
        self.pools.clear();
        self.heights.clear();
        self.rivulets.clear();
        self.drops.clear();
        self.curtains.clear();
        self.edges.clear();
        self.edge_length = 0.0;
    }
}

/// 순위와 소속 모니터를 float 하나에 담는다
pub fn encode(rank: u32, screen: usize) -> f32 {
    (rank.min(255) + 256 * screen as u32) as f32
}

pub fn screen_of(r: &[f32; 4], mons: &[Monitor]) -> usize {
    let (cx, cy) = (r[0] + r[2] / 2.0, r[1] + r[3] / 2.0);
    let mut best = 0;
    let mut best_d = f32::MAX;
    for (i, m) in mons.iter().enumerate() {
        let m = m.rect;
        let dx = (m[0] - cx).max(0.0).max(cx - m[0] - m[2]);
        let dy = (m[1] - cy).max(0.0).max(cy - m[1] - m[3]);
        let d = dx * dx + dy * dy;
        if d < best_d {
            best_d = d;
            best = i;
        }
    }
    best
}

/// 물이 고이는 창: 일반 앱 창. 최대화한 창은 윗변이 화면 맨 위에 붙어서 뺀다.
fn eligible(w: &Win) -> bool {
    w.kind == Kind::App && !w.maximized
}

fn effective_radius(p: &Pool, s: &Settings) -> f32 {
    s.corner_radius.min(p.w() * 0.5).min(p.ht() * 0.5)
}

/// 물줄기 머리가 아래 모서리 곡선을 따라 가는 거리 (곡선 길이보다 25% 더 가야 셰이더에서 끝까지 그려진다)
fn corner_run(r: f32) -> f32 {
    r * DRIP_ANGLE * 1.25
}

/// 물줄기 머리가 위쪽 모서리 곡선을 얼마나 돌았나 (0 = 시작 전, 1 = 곡선 끝, 그 뒤로는 1.2)
fn corner_reach(riv: &Rivulet, r: f32) -> f32 {
    if !riv.active || r <= 0.5 {
        return 0.0;
    }
    if riv.head >= r {
        return 1.2;
    }
    (1.0 - riv.head / r).max(-1.0).acos() / (PI / 2.0)
}

/// 물이 떨어지는 지점: 아래 모서리 곡선 위, 밑변 쪽으로 65° 돈 곳
fn drip_point(p: &Pool, side: f32, s: &Settings) -> V2 {
    let e = effective_radius(p, s);
    let n = CORNER_EXPONENT;
    let edge_x = if side < 0.0 { p.x() } else { p.max_x() };
    let (cx, cy) = (edge_x - side * e, p.max_y() - e);
    let dx = e * DRIP_ANGLE.cos().powf(2.0 / n);
    let dy = e * DRIP_ANGLE.sin().powf(2.0 / n);
    v2(cx + side * dx, cy + dy)
}

/// 물줄기 끝에 매달린 방울 중심
fn pendant_center(p: &Pool, side: f32, riv: &Rivulet, r: f32, s: &Settings) -> V2 {
    let outward = v2(side * 0.42, 0.91);
    drip_point(p, side, s) + outward * (riv.width * 0.25) + v2(0.0, r * 0.75)
}

fn rivulet_width(r: &Rivulet, s: &Settings) -> f32 {
    (0.32 * r.flow.sqrt()).clamp(1.2, 6.0) * s.stream_width
}

fn spawn_drip(drips: &mut Vec<Drip>, rng: &mut Rng, pos: V2, r: f32, rank: u32, source: isize, screen: usize, vx: f32, wander: f32) {
    if drips.len() >= 1500 {
        return;
    }
    drips.push(Drip { pos, vel: v2(vx, rng.range(20.0, 60.0)), r, rank, source, screen, wander, start_y: pos.y, hits_source: false });
}

pub struct Water {
    pools: HashMap<isize, Pool>,
    /// 보이는 풀 (앞에서 뒤)
    visible: Vec<isize>,
    wins: Vec<Win>,
    drips: Vec<Drip>,
    sprays: Vec<Spray>,
    glass: Vec<GlassDrop>,
    curtains: Vec<Curtain>,
    pub screens: Vec<Monitor>,
    rng: Rng,
    sway_time: f32,
    s: Settings,
    last_cleanup: f64,
    pub snap: Snapshot,
}

impl Water {
    pub fn new(seed: u64) -> Water {
        Water {
            pools: HashMap::new(),
            visible: Vec::new(),
            wins: Vec::new(),
            drips: Vec::new(),
            sprays: Vec::new(),
            glass: Vec::new(),
            curtains: Vec::new(),
            screens: Vec::new(),
            rng: Rng::new(seed),
            sway_time: 0.0,
            s: Settings::default(),
            last_cleanup: 0.0,
            snap: Snapshot::default(),
        }
    }

    /// 움직이는 물이 있는지 (비가 멈춰도 계속 그려야 하는지)
    pub fn is_active(&self) -> bool {
        if !self.drips.is_empty() || !self.sprays.is_empty() || !self.curtains.is_empty() || !self.glass.is_empty() {
            return true;
        }
        self.visible.iter().any(|id| {
            let p = &self.pools[id];
            p.left.active || p.right.active || p.q.iter().any(|q| q.abs() > 0.5)
        })
    }

    /// 부드러운 프레임이 필요한 빠른 움직임이 있는지 (적응형 FPS용)
    pub fn needs_smooth_motion(&self) -> bool {
        !self.curtains.is_empty()
    }

    pub fn clear_all(&mut self) {
        self.pools.clear();
        self.visible.clear();
        self.wins.clear();
        self.drips.clear();
        self.sprays.clear();
        self.glass.clear();
        self.curtains.clear();
        self.snap.clear();
    }

    /// 떨어지는 물의 가로 초기 속도. 천천히 왼쪽으로 갔다가 돌아왔다가 은은하게 흔들린다.
    fn sway(&self, seed: f32) -> f32 {
        let t = self.sway_time;
        55.0 * ((t * 0.9 + seed).sin() * 0.6 + (t * 0.37 + seed * 2.1).sin() * 0.4)
    }

    /// 창이 곧 사라진다: 지금 자리에서 물을 수막으로 흘려보내고 풀을 없앤다
    fn let_go(&mut self, id: isize, curtain: bool) {
        if curtain && self.s.curtain {
            if let Some(p) = self.pools.get(&id) {
                let avg = p.average_height() + if p.left.active { 0.3 } else { 0.0 } + if p.right.active { 0.3 } else { 0.0 };
                let (x0, front, w, rank, screen) = (p.x(), p.y(), p.w(), p.rank, p.screen);
                let clip = front - self.s.pool_capacity * 2.5;
                self.spawn_curtain(x0, x0 + w, front, avg, rank, 0.0, clip, screen);
            }
        }
        self.release_glass_drops(id);
        self.pools.remove(&id);
        self.visible.retain(|&v| v != id);
    }

    /// 창 목록이 그대로일 때: 속도는 0으로 감쇠
    pub fn idle(&mut self) {
        for id in &self.visible {
            if let Some(p) = self.pools.get_mut(id) {
                p.vel *= 0.5;
                p.accel = V2::default();
            }
        }
    }

    /// 창 목록이 바뀌었을 때
    pub fn sync(&mut self, wins: &[Win], reason: &dyn Fn(isize) -> Vanish, now: f64, dt: f32) {
        let new_ids: HashSet<isize> = wins.iter().filter(|w| eligible(w)).map(|w| w.hwnd).collect();
        let vanished: Vec<isize> = self.visible.iter().copied().filter(|id| !new_ids.contains(id)).collect();
        let mut spill = Vec::new();
        for id in vanished {
            match reason(id) {
                // 닫힘·최소화: 원래 자리에서 바로 수막 (맥판처럼 기다리지 않는다)
                Vanish::Closed | Vanish::Minimized => spill.push(id),
                // 다른 가상 데스크톱으로 간 창: 물은 보관
                Vanish::Cloaked => {
                    if let Some(p) = self.pools.get_mut(&id) {
                        p.visible = false;
                    }
                }
                // 최대화 등으로 물이 고이지 않는 창이 됨: 조용히 없앤다
                Vanish::Other => self.let_go(id, false),
            }
        }
        // 한꺼번에 여러 창이 사라지면(바탕화면 보기 등) 수막 없이 물만 사라진다
        let mass = spill.len() >= 3;
        for id in spill {
            self.let_go(id, !mass);
        }

        self.wins = wins.to_vec();
        self.visible.clear();
        let step = dt.max(1.0 / 240.0);
        for (zi, w) in wins.iter().enumerate() {
            if !eligible(w) {
                continue;
            }
            let screen = screen_of(&w.rect, &self.screens);
            let Water { pools, drips, rng, s, .. } = self;
            let p = pools.entry(w.hwnd).or_insert_with(|| Pool::new(w, zi, rng));
            let origin = v2(w.rect[0], w.rect[1]);
            if p.visible && p.last_seen > 0.0 {
                let raw = ((origin - p.last_origin) / step).clamp(-6000.0, 6000.0);
                let new_vel = p.vel * 0.35 + raw * 0.65;
                p.accel = ((new_vel - p.vel) / step).clamp(-12000.0, 12000.0);
                p.vel = new_vel;
                handle_vertical_motion(p, p.last_origin.y, origin.y, p.last_origin.x, step, drips, rng, s);
            } else {
                p.vel = V2::default();
                p.accel = V2::default();
            }
            p.last_origin = origin;
            if w.rect[2] != p.frame[2] || w.rect[3] != p.frame[3] {
                p.resize(w.rect);
            } else {
                p.frame = w.rect;
            }
            p.rank = w.rank;
            p.zi = zi;
            p.visible = true;
            p.last_seen = now;
            p.screen = screen;
            self.visible.push(w.hwnd);
        }
        self.compute_exposure();
    }

    /// 앞 창에 가려진 셀 계산. 새로 가려진 곳에 고여 있던 물은 앞 창 위로 수막이 되어 쓸려 내려간다.
    fn compute_exposure(&mut self) {
        let mut sweeps: Vec<(f32, f32, f32, f32, u32, usize, isize)> = Vec::new();
        let mut covers: Vec<(f32, f32, u32)> = Vec::new();
        for id in &self.visible {
            let Some(p) = self.pools.get_mut(id) else { continue };
            let top = p.y() - 1.5;
            let x0 = p.x();
            covers.clear();
            // 이 창 윗변 높이를 가로지르는 앞 창들 (앞 창부터: 처음 맞는 게 가장 앞). 가리기만 하는 창은 순위 1로
            for w in &self.wins[..p.zi.min(self.wins.len())] {
                let f = w.rect;
                if f[1] <= top && top <= f[1] + f[3] && f[0] + f[2] >= x0 && f[0] <= x0 + p.w() {
                    covers.push((f[0], f[0] + f[2], w.rank.max(1)));
                }
            }
            let mut run_start: i64 = -1;
            let mut run_rank = 0u32;
            let mut run_vol = 0.0f32;
            let top_y = p.y();
            for i in 0..=p.n {
                let mut cover_rank: i64 = -1;
                if i < p.n {
                    let x = x0 + (i as f32 + 0.5) * p.dx;
                    for c in &covers {
                        if c.0 <= x && x <= c.1 {
                            cover_rank = c.2 as i64;
                            break;
                        }
                    }
                    let was_exposed = p.exposure[i] > 0.0;
                    p.exposure[i] = if cover_rank >= 0 { 0.0 } else { 1.0 };
                    if was_exposed && cover_rank >= 0 && p.h[i] > 0.2 {
                        if run_start < 0 {
                            run_start = i as i64;
                            run_rank = cover_rank as u32;
                        }
                        run_vol += p.h[i] * p.dx;
                        p.h[i] = 0.0;
                        continue;
                    }
                }
                if run_start >= 0 {
                    let a = x0 + run_start as f32 * p.dx;
                    let b = x0 + i as f32 * p.dx;
                    sweeps.push((a, b, run_vol, top_y, run_rank, p.screen, p.id));
                    run_start = -1;
                    run_vol = 0.0;
                }
            }
        }
        for (x0, x1, volume, top, rank, screen, source) in sweeps {
            let width = x1 - x0;
            let avg = volume / width.max(1.0);
            if width > 12.0 && avg > 0.3 && self.s.curtain {
                self.spawn_curtain(x0, x1, top, avg, rank, 0.0, top - avg - 2.0, screen);
            } else if volume > 6.0 && self.s.drips {
                let r = (volume / PI).sqrt().min(3.5);
                let Water { drips, rng, .. } = self;
                spawn_drip(drips, rng, v2((x0 + x1) / 2.0, top), r, rank, source, screen, 0.0, 0.0);
            }
        }
    }

    pub fn update(&mut self, raw_dt: f32, now: f64, s: &Settings, wind: f32) {
        self.s = *s;
        self.sway_time = (now % 10000.0) as f32;
        let dt = raw_dt.min(1.0 / 20.0);
        let intensity = s.intensity;

        // 30분 이상 보이지 않은 풀 정리
        if now - self.last_cleanup > 30.0 {
            self.last_cleanup = now;
            self.pools.retain(|_, p| p.visible || now - p.last_seen < 1800.0);
        }

        let ids = self.visible.clone();
        for id in &ids {
            let sways = [self.sway(self.pools.get(id).map(|p| p.left.seed).unwrap_or(0.0)), self.sway(self.pools.get(id).map(|p| p.right.seed).unwrap_or(0.0))];
            let Water { pools, drips, rng, .. } = self;
            let Some(p) = pools.get_mut(id) else { continue };
            if s.pooling {
                simulate_pool(p, dt, s, intensity, rng);
            } else {
                p.h.iter_mut().for_each(|h| *h = 0.0);
            }
            // 옆면 직선 끝 + 아래 모서리 곡선. 머리가 곡선도 따라 내려가야 곡선 부분이 한꺼번에 툭 생기지 않는다
            let r = effective_radius(p, s);
            let length = p.max_y() - r - p.y() + corner_run(r);
            let spill_scale = if s.streams { 1.0 } else { 0.0 };
            // 창이 움직이는 동안은 옆 물줄기로 물이 공급되지 않고, 물줄기에 있던 물은 방울이 되어 튄다
            let speed = p.vel.len();
            let moving = speed > 250.0;
            if moving && s.drips {
                for side in [-1.0f32, 1.0] {
                    let riv = if side < 0.0 { &p.left } else { &p.right };
                    if !riv.active || riv.width <= 0.5 {
                        continue;
                    }
                    let y0 = p.y() + riv.tail;
                    let y1 = (p.y() + riv.head).min(p.max_y() - r);
                    if y1 <= y0 + 4.0 {
                        continue;
                    }
                    let rate = riv.width * (y1 - y0) / 100.0 * (speed / 800.0).min(1.0) * 26.0;
                    let mut k = (rate * dt) as i32;
                    if rng.float() < rate * dt - k as f32 {
                        k += 1;
                    }
                    let edge_x = if side < 0.0 { p.x() } else { p.max_x() };
                    let rw = riv.width;
                    for _ in 0..k.min(8) {
                        if drips.len() >= 1500 {
                            break;
                        }
                        let pos = v2(edge_x + side * rw * 0.5, rng.range(y0, y1));
                        let vel = p.vel * 0.5 + v2(side * rng.range(20.0, 90.0) + rng.range(-40.0, 40.0), rng.range(-60.0, 40.0));
                        let wander = rng.range(-60.0, 60.0);
                        drips.push(Drip { pos, vel, r: rng.range(1.1, 2.2), rank: p.rank, source: p.id, screen: p.screen, wander, start_y: pos.y, hits_source: false });
                    }
                }
            }
            let feed = if moving { 0.0 } else { spill_scale };
            let dl = p.left.update(p.spill_l * feed, length, dt);
            let dr = p.right.update(p.spill_r * feed, length, dt);
            for (k, (side, count)) in [(-1.0f32, dl), (1.0, dr)].into_iter().enumerate() {
                let mut riv = if side < 0.0 { p.left.clone() } else { p.right.clone() };
                let target = if s.streams && riv.active && riv.tail < 1.0 { 1.0 } else { 0.0 };
                riv.width += (rivulet_width(&riv, s) - riv.width) * (dt * 4.0).min(1.0);
                riv.connect += (target - riv.connect) * (dt * 8.0).min(1.0);
                if s.drips && count > 0 {
                    // 매달려 있던 방울 자리에서 그대로 떨어진다. 유량이 많으면 더 큰 방울로
                    let rr = (riv.drop_area() / PI).sqrt() * (count as f32).sqrt().min(1.35);
                    let c = pendant_center(p, side, &riv, rr, s);
                    let vx = (p.vel.x * 0.3).clamp(-150.0, 150.0) + sways[k];
                    let wander = rng.range(-110.0, 110.0);
                    spawn_drip(drips, rng, c, rr, p.rank, p.id, p.screen, vx, wander);
                }
                if side < 0.0 {
                    p.left = riv;
                } else {
                    p.right = riv;
                }
            }
        }

        self.update_glass_drops(dt, s, intensity);
        self.update_drips(dt, wind);
        self.update_sprays(dt);
        for c in self.curtains.iter_mut() {
            c.age += dt;
        }
        self.curtains.retain(|c| c.age <= c.duration);
        self.build_snapshot(s);
    }

    fn update_drips(&mut self, dt: f32, wind: f32) {
        // 창에서 떨어져 나온 방울이 착지하지 못하고 그 창의 윗변 아래로 내려가면 수막으로 바뀐다 (창별로 모아서)
        struct Gp {
            x0: f32,
            x1: f32,
            area: f32,
            y: f32,
            vy: f32,
            n: f32,
            rank: u32,
            screen: usize,
        }
        let mut to_curtain: HashMap<isize, Gp> = HashMap::new();
        let mut i = 0;
        while i < self.drips.len() {
            let mut d = std::mem::replace(&mut self.drips[i], Drip { pos: V2::default(), vel: V2::default(), r: 0.0, rank: 0, source: 0, screen: 0, wander: 0.0, start_y: 0.0, hits_source: false });
            let prev_y = d.pos.y;
            d.vel.y = (d.vel.y + GRAVITY * dt).min(2200.0);
            d.vel.x += (wind * d.vel.y * 0.25 - d.vel.x) * (dt * 0.6).min(1.0);
            if d.wander != 0.0 {
                let fallen = d.pos.y - d.start_y;
                let k = ((fallen - 60.0) / 160.0).clamp(0.0, 1.0);
                d.vel.x += d.wander * k * k * dt;
            }
            d.pos += d.vel * dt;
            let mut hit: Option<isize> = None;
            let mut hit_top = f32::MAX;
            // 다른 모니터의 창에는 떨어지지 않는다
            for id in &self.visible {
                let p = &self.pools[id];
                if (p.id == d.source && !d.hits_source) || p.screen != d.screen {
                    continue;
                }
                let top = p.y();
                if prev_y < top && d.pos.y >= top && top < hit_top && d.pos.x >= p.x() && d.pos.x <= p.max_x() {
                    let c = (((d.pos.x - p.x()) / p.dx).max(0.0) as usize).min(p.n - 1);
                    if p.exposure[c] > 0.0 {
                        hit = Some(p.id);
                        hit_top = top;
                    }
                }
            }
            if let Some(hid) = hit {
                let Water { pools, sprays, rng, s, .. } = self;
                let p = pools.get_mut(&hid).unwrap();
                let c = (((d.pos.x - p.x()) / p.dx).max(0.0) as usize).min(p.n - 1);
                if s.pooling {
                    p.h[c] += PI * d.r * d.r / p.dx;
                    // 철푸덕: 큰 방울이 빠르게 떨어질수록 물결을 세게 일으킨다
                    let imp = (d.r * d.vel.y * 0.25).min(400.0);
                    if c > 1 && c < p.n - 1 {
                        p.q[c] -= imp;
                        p.q[c + 1] += imp;
                    }
                }
                if s.splashes {
                    let count = if d.hits_source { (2.0 + d.r * 1.5 * (d.vel.y / 500.0).min(1.5)) as i32 } else { 3 };
                    for _ in 0..count {
                        let vy = rng.range(60.0, 200.0) * if d.hits_source { (0.7 + d.vel.y / 1200.0).min(1.4) } else { 1.0 };
                        // 약 65%는 꼭대기를 지나면 곧 사라진다
                        let life = if rng.float() < 0.65 { vy / 1800.0 + rng.range(0.03, 0.08) } else { rng.range(0.25, 0.4) };
                        let vx = rng.range(-110.0, 110.0);
                        let r = rng.range(0.5, 1.1);
                        sprays.push(Spray { pos: v2(d.pos.x, hit_top - 2.0), vel: v2(vx, -vy), r, life, rank: p.rank, screen: p.screen });
                    }
                }
                self.drips.swap_remove(i);
                continue;
            }
            // 창 앞면 위에 걸린 방울만 수막으로 (창 옆 허공으로 비껴간 방울은 그냥 방울로 계속 떨어진다)
            if d.hits_source {
                if let Some(src) = self.pools.get(&d.source) {
                    if src.visible && d.pos.y > src.y() + 1.0 && d.pos.x > src.x() + 2.0 && d.pos.x < src.max_x() - 2.0 {
                        let gp = to_curtain.entry(d.source).or_insert(Gp { x0: d.pos.x, x1: d.pos.x, area: 0.0, y: 0.0, vy: 0.0, n: 0.0, rank: d.rank, screen: d.screen });
                        gp.x0 = gp.x0.min(d.pos.x - d.r);
                        gp.x1 = gp.x1.max(d.pos.x + d.r);
                        gp.area += PI * d.r * d.r;
                        gp.y += d.pos.y;
                        gp.vy += d.vel.y;
                        gp.n += 1.0;
                        self.drips.swap_remove(i);
                        continue;
                    }
                }
            }
            let bottom = self.screens.get(d.screen).map(|m| m.rect[1] + m.rect[3]).unwrap_or(5000.0);
            if d.pos.y > bottom + 30.0 {
                self.drips.swap_remove(i);
                continue;
            }
            self.drips[i] = d;
            i += 1;
        }
        if !self.s.curtain {
            return;
        }
        for (_, gp) in to_curtain {
            let (x0, x1) = (gp.x0 - 10.0, gp.x1 + 10.0);
            let y = gp.y / gp.n;
            // 머리가 방울이 있던 자리에서 또렷하게 시작하도록, 위쪽 페이드는 그보다 충분히 위에서 시작
            self.spawn_curtain(x0, x1, y + 2.0, gp.area / (x1 - x0) * 1.5, gp.rank, gp.vy / gp.n, y - 45.0, gp.screen);
        }
    }

    fn update_sprays(&mut self, dt: f32) {
        if self.sprays.len() > 600 {
            let extra = self.sprays.len() - 600;
            self.sprays.drain(..extra);
        }
        let mut i = 0;
        while i < self.sprays.len() {
            let sp = &mut self.sprays[i];
            sp.life -= dt;
            if sp.life <= 0.0 {
                self.sprays.swap_remove(i);
                continue;
            }
            sp.vel.y += 1800.0 * dt;
            sp.pos += sp.vel * dt;
            i += 1;
        }
    }

    fn covers_screen(&self, f: &[f32; 4]) -> bool {
        self.screens.iter().any(|m| {
            let m = m.rect;
            f[0] - 2.0 <= m[0] && f[1] - 2.0 <= m[1] && f[0] + f[2] + 2.0 >= m[0] + m[2] && f[1] + f[3] + 2.0 >= m[1] + m[3]
        })
    }

    // 창 유리 위를 흐르는 물방울
    fn update_glass_drops(&mut self, dt: f32, s: &Settings, intensity: f32) {
        if s.window_droplets {
            let front = self.wins.iter().find(|w| w.kind == Kind::App).map(|w| w.hwnd);
            let ids: Vec<isize> = self
                .visible
                .iter()
                .copied()
                .filter(|&id| if s.droplets_except_front { Some(id) != front } else { s.droplets_on_all_windows || Some(id) == front })
                .collect();
            for id in ids {
                let (fr, avg) = {
                    let p = &self.pools[&id];
                    (p.frame, p.average_height())
                };
                if fr[3] <= 110.0 || fr[2] <= 110.0 || self.covers_screen(&fr) {
                    continue;
                }
                let fullness = (avg / s.pool_capacity.max(0.5) * 1.5).min(1.0);
                let wet = fullness.max(if intensity > 0.01 { 0.15 } else { 0.0 });
                if wet <= 0.05 {
                    continue;
                }
                let active = self.glass.iter().filter(|g| g.win == id && !g.bead).count();
                if active >= 8 {
                    continue;
                }
                let Water { pools, glass, rng, .. } = self;
                let p = pools.get_mut(&id).unwrap();
                p.droplet_clock += dt * s.droplet_frequency * 0.7 * wet;
                if p.droplet_clock >= 1.0 || rng.float() < p.droplet_clock * dt * 0.5 {
                    p.droplet_clock = (p.droplet_clock - 1.0).max(0.0) * rng.float();
                    let r = s.corner_radius;
                    let x = rng.range(r + 16.0, p.w() - r - 16.0);
                    let target = rng.range(2.4, 4.6);
                    let pause = rng.range(0.4, 1.4);
                    let trail_next = rng.range(5.0, 12.0);
                    let drift = rng.range(-0.3, 0.3);
                    glass.push(GlassDrop { win: id, p: v2(x, 1.5), r: 0.6, target, v: 0.0, pause, trail: 0.0, trail_next, drift, bead: false, life: 0.0 });
                    // 고인 물에서 조금 빼 간다
                    let c = ((x / p.dx).max(0.0) as usize).min(p.n - 1);
                    p.h[c] = (p.h[c] - PI * target * target / p.dx * 0.5).max(0.0);
                }
            }
        }

        let mut new_beads: Vec<GlassDrop> = Vec::new();
        let mut i = 0;
        while i < self.glass.len() {
            let Water { pools, glass, drips, rng, .. } = self;
            let Some(p) = pools.get(&glass[i].win) else {
                glass.swap_remove(i);
                continue;
            };
            let g = &mut glass[i];
            if g.bead {
                g.life -= dt;
                if g.life <= 0.0 {
                    glass.swap_remove(i);
                    continue;
                }
                i += 1;
                continue;
            }
            if g.r < g.target && g.v == 0.0 && g.p.y < 4.0 {
                g.r = g.target.min(g.r + 2.5 * dt); // 천장에서 맺히는 중
                g.pause = g.pause.max(0.05);
            }
            if g.pause > 0.0 {
                g.pause -= dt;
                g.v *= (1.0 - 10.0 * dt).max(0.0);
            } else {
                g.v = (g.v + 220.0 * (g.r - 1.6) * dt).min(25.0 + 24.0 * g.r);
                if rng.float() < dt * 1.4 {
                    g.pause = rng.range(0.05, 0.6);
                }
            }
            g.drift += rng.range(-1.0, 1.0) * dt;
            g.drift = g.drift.clamp(-0.4, 0.4);
            let dy = g.v * dt;
            g.p.y += dy;
            g.p.x += g.drift * dy * 0.25;
            g.trail += dy;
            if g.trail > g.trail_next {
                g.trail = 0.0;
                g.trail_next = rng.range(5.0, 13.0);
                if rng.float() < 0.6 && new_beads.len() + glass.len() < 320 {
                    let g = &mut glass[i];
                    let br = g.r * rng.range(0.2, 0.36);
                    let life = rng.range(3.0, 8.0);
                    new_beads.push(GlassDrop { win: g.win, p: g.p - v2(0.0, g.r * 1.1), r: br, target: br, v: 0.0, pause: 0.0, trail: 0.0, trail_next: 8.0, drift: 0.0, bead: true, life });
                    let v3 = g.r * g.r * g.r - br * br * br;
                    g.r = v3.cbrt().max(0.5);
                }
            }
            let g = &mut glass[i];
            if g.r < 1.55 && g.v >= 0.0 && g.p.y > 6.0 {
                g.bead = true;
                g.life = rng.range(2.0, 6.0);
            }
            if g.p.y > p.ht() - 3.0 {
                if s.drips {
                    let vx = (p.vel.x * 0.3).clamp(-150.0, 150.0);
                    spawn_drip(drips, rng, v2(p.x() + g.p.x, p.max_y()), g.r * 0.9, p.rank, p.id, p.screen, vx, 0.0);
                }
                glass.swap_remove(i);
                continue;
            }
            i += 1;
        }
        self.glass.extend(new_beads);
    }

    fn release_glass_drops(&mut self, id: isize) {
        let Some(p) = self.pools.get(&id) else { return };
        let (x, y, rank, screen) = (p.x(), p.y(), p.rank, p.screen);
        let Water { glass, drips, rng, .. } = self;
        for g in glass.iter() {
            if g.win == id && !g.bead {
                spawn_drip(drips, rng, v2(x + g.p.x, y + g.p.y), g.r, rank, id, screen, 0.0, 0.0);
            }
        }
        glass.retain(|g| g.win != id);
    }

    /// velocity: 이미 떨어지던 물이면 그 속도에서 이어지도록 셰이더의 낙하 곡선 시점을 맞춘다
    fn spawn_curtain(&mut self, x0: f32, x1: f32, front_y: f32, avg_height: f32, rank: u32, velocity: f32, clip_top: f32, screen: usize) {
        if avg_height <= 0.25 {
            return;
        }
        let strength = (avg_height / self.s.pool_capacity.max(1.0)).min(1.6) * self.s.curtain_strength;
        if strength <= 0.02 {
            return;
        }
        // 셰이더와 같은 낙하 모델: fall(τ) = vt·(τ − (1 − e^(−kτ))/k)
        let (vt, k) = (900.0f32, 2.5f32);
        let ratio = (velocity.max(0.0) / vt).min(0.9);
        let tau0 = -(1.0 - ratio).ln() / k;
        let fall0 = vt * (tau0 - (1.0 - (-k * tau0).exp()) / k);
        let bottom = self.screens.get(screen).map(|m| m.rect[1] + m.rect[3]).unwrap_or(front_y + 1500.0);
        let dist = (bottom - front_y).max(100.0);
        let duration = tau0 + (0.9 + dist / 700.0 + 2.2).min(8.0);
        let seed = self.rng.range(0.0, 500.0);
        self.curtains.push(Curtain { x0, x1, top: front_y - fall0, bottom, age: tau0, strength, rank, seed, duration, clip_top, screen });
        if self.curtains.len() > 24 {
            self.curtains.remove(0);
        }
    }

    fn build_snapshot(&mut self, s: &Settings) {
        let mut snap = std::mem::take(&mut self.snap);
        snap.clear();
        let cap = s.pool_capacity;
        for id in &self.visible {
            let p = &self.pools[id];
            let r = effective_radius(p, s);
            let enc = encode(p.rank, p.screen);
            // 모서리에서 옆면 물줄기로 이어지는 폭
            let join_l = p.left.width * p.left.connect;
            let join_r = p.right.width * p.right.connect;
            let max_h = (cap * 1.6).min(p.h.iter().cloned().fold(0.0, f32::max));
            if max_h > 0.2 || join_l > 0.2 || join_r > 0.2 {
                let offset = snap.heights.len() as f32;
                snap.heights.extend_from_slice(&p.h);
                snap.pools.push([p.x(), p.y(), p.w(), enc]);
                snap.pools.push([offset, p.n as f32, p.dx, 1.0]);
                snap.pools.push([join_l, join_r, r, max_h.max(join_l).max(join_r)]);
                snap.pools.push([corner_reach(&p.left, r), corner_reach(&p.right, r), 0.0, 0.0]);
            }
            append_edges(&mut snap, p, r);
            // 옆면 물줄기와 아래 모서리에 매달린 방울
            for (riv, side) in [(&p.left, -1.0f32), (&p.right, 1.0)] {
                let top = p.y();
                let end_y = p.max_y() - r;
                if riv.active && riv.width > 0.3 {
                    let edge_x = if side < 0.0 { p.x() } else { p.max_x() };
                    snap.rivulets.push([edge_x, top, p.max_y(), side]);
                    snap.rivulets.push([top + riv.head, top + riv.tail, riv.width, enc]);
                    snap.rivulets.push([riv.seed, (riv.flow / 150.0).min(1.0), r, 0.0]);
                    snap.rivulets.push([riv.connect, 0.0, 0.0, 0.0]);
                }
                let pr = riv.pendant_radius();
                if s.drips && pr > 0.0 && (!riv.active || riv.head >= end_y - top + corner_run(r) - 0.5) {
                    let c = pendant_center(p, side, riv, pr, s);
                    snap.drops.push([c.x, c.y, pr, 1.0]);
                    snap.drops.push([0.0, 1.0, 1.15, enc]);
                }
            }
        }

        // 바닥(작업 표시줄 윗변 또는 화면 아래) 튀김. 창 윗변보다 낮은 비중
        if s.desktop_rain > 0.05 {
            for (i, m) in self.screens.iter().enumerate() {
                let weight = 0.25;
                snap.edges.push([m.rect[0], m.rect[0] + m.rect[2], m.floor - 1.0, encode(255, i)]);
                snap.edges.push([snap.edge_length, weight, 0.0, 0.0]);
                snap.edge_length += m.rect[2] * weight;
            }
        }

        for d in &self.drips {
            let speed = d.vel.len();
            let dir = if speed > 1.0 { d.vel / speed } else { v2(0.0, 1.0) };
            snap.drops.push([d.pos.x, d.pos.y, d.r, 1.0]);
            // 작은 방울은 빠를수록 길게 늘어나 연달아 떨어질 때 물줄기처럼 이어진다
            let stretch = (1.0 + speed * 0.0045 / d.r.max(0.8)).min(10.0);
            snap.drops.push([dir.x, dir.y, stretch, encode(d.rank, d.screen)]);
        }
        for sp in &self.sprays {
            let speed = sp.vel.len();
            let dir = if speed > 1.0 { sp.vel / speed } else { v2(0.0, 1.0) };
            snap.drops.push([sp.pos.x, sp.pos.y, sp.r, -(sp.life * 5.0).min(1.0)]); // 음수 알파 = 튀김(연하게)
            snap.drops.push([dir.x, dir.y, 1.0 + (speed * 0.004).min(2.0), encode(sp.rank, sp.screen)]);
        }
        for g in &self.glass {
            let Some(p) = self.pools.get(&g.win) else { continue };
            if !p.visible {
                continue;
            }
            let alpha = if g.bead { (g.life / 1.5).min(1.0) } else { 1.0 };
            let stretch = if g.bead { 1.0 } else { 1.15 + (g.v * 0.012).min(0.9) };
            snap.drops.push([p.x() + g.p.x, p.y() + g.p.y, g.r, alpha]);
            snap.drops.push([0.0, 1.0, stretch, encode(p.rank, p.screen)]);
        }
        for c in &self.curtains {
            snap.curtains.push([c.x0, c.x1, c.top, c.bottom]);
            snap.curtains.push([c.age, c.strength, encode(c.rank, c.screen), c.seed]);
            snap.curtains.push([c.duration, c.clip_top, 0.0, 0.0]);
        }
        self.snap = snap;
    }
}

fn append_edges(snap: &mut Snapshot, p: &Pool, r: f32) {
    let x0 = p.x();
    let top = p.y();
    let mut run_start: i64 = -1;
    let mut sum = 0.0f32;
    for i in 0..=p.n {
        if i < p.n && p.exposure[i] > 0.0 {
            if run_start < 0 {
                run_start = i as i64;
            }
            sum += p.h[i];
            continue;
        }
        if run_start >= 0 {
            let a = x0 + run_start as f32 * p.dx;
            let b = x0 + i as f32 * p.dx;
            let lo = a.max(x0 + r * 0.6);
            let hi = b.min(x0 + p.w() - r * 0.6);
            if hi - lo > 8.0 {
                let avg = sum / (i as i64 - run_start).max(1) as f32;
                snap.edges.push([lo, hi, top - avg, encode(p.rank, p.screen)]);
                snap.edges.push([snap.edge_length, 1.0, 0.0, 0.0]);
                snap.edge_length += hi - lo;
            }
            run_start = -1;
            sum = 0.0;
        }
    }
}

/// 창이 중력보다 빨리 내려가면, 받침을 잃은 윗변의 물은 여러 방울로 흩어져 공중에 남는다.
fn handle_vertical_motion(p: &mut Pool, old_y: f32, new_y: f32, old_x: f32, dt: f32, drips: &mut Vec<Drip>, rng: &mut Rng, s: &Settings) {
    let drop = new_y - old_y;
    if !s.pool_inertia || p.average_height() <= 0.15 {
        p.water_vy = drop / dt;
        return;
    }
    let fall_reach = p.water_vy * dt + 0.5 * GRAVITY * dt * dt;
    if drop <= fall_reach + 1.5 {
        p.water_vy = drop / dt;
        return;
    }
    // 6~10pt 구간마다 물을 모아 방울 하나로 (얇은 막 10%는 남긴다)
    let mut i = 0;
    while i < p.n && drips.len() < 1500 {
        let end = (i + ((rng.range(6.0, 10.0) / p.dx) as usize).max(1)).min(p.n);
        let mut vol = 0.0;
        for k in i..end {
            vol += p.h[k] * p.dx * 0.9;
            p.h[k] *= 0.1;
        }
        if vol > 1.5 {
            let r = (vol / PI).sqrt().clamp(0.9, 3.6);
            let cx = old_x + (i as f32 + (end - i) as f32 * rng.float()) * p.dx;
            let vel = v2((p.vel.x * 0.3).clamp(-150.0, 150.0) + rng.range(-25.0, 25.0), p.water_vy.max(0.0) + rng.range(0.0, 80.0));
            drips.push(Drip { pos: v2(cx, old_y - r * 0.8), vel, r, rank: p.rank, source: p.id, screen: p.screen, wander: 0.0, start_y: 0.0, hits_source: true });
        }
        i = end;
    }
    p.q.iter_mut().for_each(|q| *q = 0.0);
    p.spill_l = 0.0;
    p.spill_r = 0.0;
    p.water_vy = drop / dt;
}

fn simulate_pool(p: &mut Pool, dt: f32, s: &Settings, intensity: f32, rng: &mut Rng) {
    let n = p.n;
    let dx = p.dx;
    let cap = s.pool_capacity;
    let g = 3000.0f32;
    let rain = intensity * s.accumulation * 0.7;
    let evap = s.evaporation * 0.08;
    // 바람에 흔들리듯 느리게 변하는 기울임
    p.wobble[0] += 0.43 * dt;
    p.wobble[1] += 0.71 * dt;
    p.wobble[2] += 1.13 * dt;
    let wob = p.wobble[0].sin() * 0.5 + p.wobble[1].sin() * 0.3 + p.wobble[2].sin() * 0.2;
    let slosh = -p.accel.x * s.sloshing * 0.5 + wob * 160.0 * (0.3 + intensity) * s.sloshing;

    // 빗방울 충돌: 충돌 지점 주변 몇 칸에 걸쳐 물을 바깥으로 밀어내 부드러운 파문이 퍼지게 한다
    let impacts = (0.3 + intensity) * p.w() * 0.07 * dt;
    let mut k = impacts as i32;
    if rng.float() < impacts - k as f32 {
        k += 1;
    }
    let weights = [0.45f32, 0.33, 0.22];
    for _ in 0..k {
        if n <= 8 {
            break;
        }
        let i = 4 + (rng.float() * (n - 8) as f32) as usize;
        let hl = p.h[i];
        if hl > 0.4 {
            let imp = rng.range(150.0, 330.0) * hl.sqrt();
            for (j, w) in weights.iter().enumerate() {
                p.q[i + 1 + j] += imp * w;
                p.q[i - j] -= imp * w;
            }
        }
    }

    let steps = ((dt / (1.0 / 120.0)).ceil() as usize).max(1);
    let sdt = dt / steps as f32;
    let damp = (-4.0 * sdt).exp();
    let mut spill_l = 0.0f32;
    let mut spill_r = 0.0f32;
    let (h, q, e) = (&mut p.h, &mut p.q, &p.exposure);
    for _ in 0..steps {
        for i in 0..n {
            h[i] = (h[i] + (rain * e[i] - evap) * sdt).max(0.0);
        }
        // 가상 파이프 모델: 내부 경계 q[1..n-1]
        for i in 1..n {
            let ha = 0.5 * (h[i - 1] + h[i]);
            if ha <= 0.0001 && h[i - 1] <= 0.0 && h[i] <= 0.0 {
                q[i] = 0.0;
                continue;
            }
            q[i] = q[i] * damp + sdt * (g * ha * (h[i - 1] - h[i]) / dx + slosh * ha);
        }
        q[0] = 0.0;
        q[n] = 0.0;
        // 음수 방지 스케일링
        for i in 0..n {
            let out = q[i + 1].max(0.0) + (-q[i]).max(0.0);
            let avail = h[i] * dx / sdt;
            if out > avail && out > 0.0 {
                let sc = avail / out;
                if q[i + 1] > 0.0 {
                    q[i + 1] *= sc;
                }
                if q[i] < 0.0 {
                    q[i] *= sc;
                }
            }
        }
        for i in 0..n {
            h[i] = (h[i] + sdt * (q[i] - q[i + 1]) / dx).max(0.0);
        }
        // 약한 점성: 격자 크기의 잔떨림만 빠르게 죽인다 (부피 보존)
        let mut prev = h[0];
        for i in 1..(n - 1) {
            let cur = h[i];
            h[i] = cur + 0.03 * (prev - 2.0 * cur + h[i + 1]);
            prev = cur;
        }
        // 양 끝 넘침
        let lip = cap;
        if h[0] > lip {
            let out = ((h[0] - lip) * 500.0).min(h[0] * dx / sdt);
            h[0] -= out * sdt / dx;
            spill_l += out / steps as f32;
        }
        if h[n - 1] > lip {
            let out = ((h[n - 1] - lip) * 500.0).min(h[n - 1] * dx / sdt);
            h[n - 1] -= out * sdt / dx;
            spill_r += out / steps as f32;
        }
        // 과도한 수위 제한 (강한 출렁임 시)
        for x in h.iter_mut() {
            if *x > cap * 1.6 {
                *x = cap * 1.6;
            }
        }
    }
    p.spill_l = spill_l;
    p.spill_r = spill_r;
}
