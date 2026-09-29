// 마우스로 누른 자리의 물 (맥판 PressEffect.swift). 유리와 비닐 랩 사이에 낀 물을 손가락으로 누르는 모습:
// 누르는 동안 물이 닿는 면이 넓어지고, 끌면 말랑하게 늘어나며 따라오고, 떼면 매끈하게 작아져 사라진다.
// 화면 표면에서 일어나는 일이라 창 순서와 상관없이 맨 위에 그린다.

use crate::settings::Settings;
use crate::v2::{Rng, V2, v2};

#[derive(Clone)]
struct Blob {
    id: u32,
    pos: V2,
    target: V2,
    vel: V2,
    r: f32,
    vr: f32,
    held: bool,
    age: f32,
    release_age: f32,
    base_r: f32,
    /// 톡 클릭처럼 덜 퍼진 채 뗐으면 톡 클릭 크기의 90%까지는 마저 퍼진 뒤 줄어든다
    tap_grow: bool,
    /// 이 나이가 되면 잔 물방울을 쏜다
    burst_at: f32,
    shape: V2,
    wobble: V2,
    wobble_vel: V2,
}

impl Blob {
    fn new(id: u32, p: V2) -> Blob {
        Blob {
            id,
            pos: p,
            target: p,
            vel: V2::default(),
            r: 0.0,
            vr: 0.0,
            held: true,
            age: 0.0,
            release_age: 0.0,
            base_r: 0.0,
            tap_grow: false,
            burst_at: -1.0,
            shape: V2::default(),
            wobble: V2::default(),
            wobble_vel: V2::default(),
        }
    }
    /// 타원 늘어남 e·(cos2φ, sin2φ)
    fn stretch(&self) -> V2 {
        let s = self.shape + self.wobble;
        let e = s.len();
        if e > 0.9 { s * (0.9 / e) } else { s }
    }
}

struct Satellite {
    group: u32,
    pos: V2,
    from: V2,
    dir: V2,
    dist: f32,
    r0: f32,
    r: f32,
    age: f32,
    life: f32,
}

struct Tuning {
    max_r: f32,
    tap_r: f32,
    grow: f32,
    shrink: f32,
    stretch: f32,
    wobble: f32,
    satellites: bool,
    sat_count: f32,
    sat_size: f32,
    sat_distance: f32,
    neck: f32,
    shadow: f32,
    shadow_spread: f32,
    scroll_dust: bool,
}

impl Tuning {
    fn from(s: &Settings) -> Tuning {
        Tuning {
            max_r: s.press_max_radius,
            tap_r: s.press_tap_radius.min(s.press_max_radius),
            grow: s.press_grow,
            shrink: s.press_shrink,
            stretch: s.press_stretch,
            wobble: s.press_wobble,
            satellites: s.press_satellites,
            sat_count: s.press_sat_count,
            sat_size: s.press_sat_size,
            sat_distance: s.press_sat_distance,
            neck: s.press_neck,
            shadow: s.press_shadow,
            shadow_spread: s.press_shadow_spread,
            scroll_dust: s.press_scroll_dust,
        }
    }
    /// 잔 물방울과 합쳐지는 거리 (목이 생기는 거리)
    fn k(&self) -> f32 {
        self.max_r * 0.2 * self.neck
    }
}

pub struct Press {
    blobs: Vec<Blob>,
    sats: Vec<Satellite>,
    next_id: u32,
    tune: Tuning,
    rng: Rng,
    /// GPU로 올릴 데이터. 앞쪽은 무리당 3개, 그 뒤로 잔 물방울이 하나씩
    pub data: Vec<[f32; 4]>,
    pub groups: u32,
    /// 스크롤 먼지: 스크롤한 거리를 모아 간격마다 하나씩, 너무 많아지지 않게 시간 간격도 둔다
    scroll_acc: f32,
    scroll_next: f32,
    last_dust: f64,
}

impl Press {
    pub fn new(seed: u64) -> Press {
        Press { blobs: Vec::new(), sats: Vec::new(), next_id: 0, tune: Tuning::from(&Settings::default()), rng: Rng::new(seed), data: Vec::new(), groups: 0, scroll_acc: 0.0, scroll_next: 24.0, last_dust: 0.0 }
    }

    pub fn is_active(&self) -> bool {
        !self.blobs.is_empty() || !self.sats.is_empty()
    }

    pub fn held(&self) -> bool {
        self.blobs.iter().any(|b| b.held)
    }

    pub fn clear(&mut self) {
        self.blobs.clear();
        self.sats.clear();
        self.data.clear();
        self.groups = 0;
    }

    pub fn begin(&mut self, p: V2) {
        self.end();
        // 아직 오므라드는 중인 방울을 다시 누르면 그 방울이 다시 부푼다 (더블클릭). 최대 크기는 넘지 않게
        if let Some(i) = self.blobs.iter().rposition(|b| b.pos.dist(p) < b.r.max(8.0)) {
            let max_r = self.tune.max_r;
            let b = &mut self.blobs[i];
            b.held = true;
            b.age = 0.0;
            b.base_r = b.r.min(max_r);
            b.target = p;
            let (id, pos, r) = (b.id, b.pos, b.r);
            self.burst(id, pos, r, 3, 4, r);
            return;
        }
        self.next_id += 1;
        let mut b = Blob::new(self.next_id, p);
        // 본 방울이 조금 퍼진 뒤 가장자리에서 떨어져 나가게 (바로 쏘면 이어진 목 없이 점만 생긴다)
        b.burst_at = 0.07;
        self.blobs.push(b);
        if self.blobs.len() > 6 {
            self.blobs.remove(0);
        }
    }

    /// 스크롤할 때 본 방울 없이 커서 둘레에서 잔 물방울이 먼지처럼 흩날린다. 내용이 움직이는 방향으로,
    /// 빠를수록 멀리·많이. delta: 화면에서 내용이 움직이는 방향 (pt, y 아래)
    pub fn scroll(&mut self, p: V2, delta: V2, now: f64) {
        if !self.tune.scroll_dust {
            return;
        }
        let len = delta.len();
        if len <= 0.5 {
            return;
        }
        self.scroll_acc += len;
        if self.scroll_acc < self.scroll_next || now - self.last_dust <= 1.0 / 40.0 {
            return;
        }
        self.scroll_acc = 0.0;
        self.scroll_next = self.rng.range(18.0, 32.0);
        self.last_dust = now;
        let dir = delta / len;
        let perp = v2(-dir.y, dir.x);
        let a = self.rng.range(-0.4, 0.4);
        let fly = v2(dir.x * a.cos() - dir.y * a.sin(), dir.x * a.sin() + dir.y * a.cos());
        let r0 = self.tune.max_r * (0.03 + 0.09 * self.rng.float().powi(2)) * self.tune.sat_size;
        let start = p + perp * self.rng.range(-26.0, 26.0) + dir * self.rng.range(-12.0, 12.0);
        let dist = (len * 2.5).clamp(10.0, 90.0) * self.rng.range(0.6, 1.2);
        let life = self.rng.range(0.5, 0.8);
        self.sats.push(Satellite { group: 0, pos: start, from: start, dir: fly, dist, r0, r: r0, age: 0.0, life });
        self.trim();
    }

    /// 톡 클릭과 같은 물방울을 하나 띄운다 (키보드 Tab). 누르고 있는 마우스 방울은 건드리지 않는다
    pub fn tap(&mut self, p: V2) {
        self.next_id += 1;
        let mut b = Blob::new(self.next_id, p);
        b.held = false;
        b.tap_grow = true;
        b.burst_at = 0.07;
        self.blobs.push(b);
        if self.blobs.len() > 6 {
            self.blobs.remove(0);
        }
    }

    /// Enter로 보냈을 때: 입력칸 가장자리 여기저기에서 잔 물방울이 톡톡 튀어 나가 흩어진다. 본 방울은 없다.
    /// rect: (x, y, w, h) pt
    pub fn pop(&mut self, rect: [f32; 4]) {
        if !self.tune.satellites {
            return;
        }
        let (hx, hy) = (rect[2] / 2.0, rect[3] / 2.0);
        let center = v2(rect[0] + hx, rect[1] + hy);
        let perimeter = 4.0 * (hx + hy);
        let n = ((self.rng.int(11, 19) as f32 * self.tune.sat_count).round() as i32).max(2);
        for _ in 0..n {
            let s = self.rng.range(0.0, perimeter);
            // 위 → 오른쪽 → 아래 → 왼쪽 (y 아래)
            let (p, nrm) = if s < 2.0 * hx {
                (v2(-hx + s, -hy), v2(0.0, -1.0))
            } else if s < 2.0 * hx + 2.0 * hy {
                (v2(hx, -hy + (s - 2.0 * hx)), v2(1.0, 0.0))
            } else if s < 4.0 * hx + 2.0 * hy {
                (v2(hx - (s - 2.0 * hx - 2.0 * hy), hy), v2(0.0, 1.0))
            } else {
                (v2(-hx, hy - (s - 4.0 * hx - 2.0 * hy)), v2(-1.0, 0.0))
            };
            // 모서리 쪽은 대각선으로 퍼지게 가운데에서 바깥 방향을 조금 섞는다
            let rad = p / v2(hx.max(1.0), hy.max(1.0));
            let rad = rad / rad.len().max(1e-4);
            let d0 = nrm + rad * 0.5;
            let d0 = d0 / d0.len().max(1e-4);
            let a = self.rng.range(-0.35, 0.35);
            let dir = v2(d0.x * a.cos() - d0.y * a.sin(), d0.x * a.sin() + d0.y * a.cos());
            // 크기는 작은 것부터 꽤 큰 것까지 (작은 쪽이 더 흔하게)
            let r0 = (3.0 + 12.0 * self.rng.float().powf(1.4)).min(hy.max(4.0) * 0.9) * self.tune.sat_size;
            let start = center + p - nrm * (r0 * 0.5);
            let dist = self.rng.range(8.0, 50.0) * self.tune.sat_distance;
            let life = self.rng.range(0.4, 0.7);
            self.sats.push(Satellite { group: 0, pos: start, from: start, dir, dist, r0, r: r0, age: 0.0, life });
        }
        self.trim();
    }

    fn trim(&mut self) {
        if self.sats.len() > 100 {
            let extra = self.sats.len() - 100;
            self.sats.drain(..extra);
        }
    }

    pub fn move_to(&mut self, p: V2) {
        for b in self.blobs.iter_mut().filter(|b| b.held) {
            b.target = p;
        }
    }

    pub fn end(&mut self) {
        let mut bursts = Vec::new();
        for b in self.blobs.iter_mut().filter(|b| b.held) {
            b.held = false;
            b.release_age = 0.0;
            b.tap_grow = true;
            // 톡 클릭은 누를 때 튄 것만으로 충분하다. 어느 정도 누르고 있었을 때만 뗄 때도 튄다
            if b.age >= 0.4 {
                bursts.push((b.id, b.pos, b.r));
            }
        }
        for (id, pos, r) in bursts {
            self.burst(id, pos, r, 5, 7, r);
        }
    }

    /// 본 방울 가장자리 안쪽에서 고르게 잔 물방울을 쏜다. rest 바깥으로 목 길이(k) 안팎에서 멈추게 한다.
    fn burst(&mut self, group: u32, pos: V2, r: f32, lo: i32, hi: i32, rest: f32) {
        if !self.tune.satellites {
            return;
        }
        let n = (self.rng.int(lo, hi) as f32 * self.tune.sat_count).round() as i32;
        if n <= 0 {
            return;
        }
        let a0 = self.rng.range(0.0, 2.0 * std::f32::consts::PI);
        let k = self.tune.k();
        let max_r = self.tune.max_r;
        for j in 0..n {
            let a = a0 + j as f32 / n as f32 * 2.0 * std::f32::consts::PI + self.rng.range(-0.45, 0.45);
            let dir = v2(a.cos(), a.sin());
            // 크기는 최대 반경의 7~30%, 작은 쪽이 훨씬 흔하게
            let r0 = max_r * (0.07 + 0.23 * self.rng.float().powf(1.8)) * self.tune.sat_size;
            let rim = r.max(max_r * 0.32);
            let start = (rim - r0).max(0.0) * 0.85;
            let stop = rest + r0 + k * self.rng.range(0.3, 2.0) * self.tune.sat_distance;
            let life = self.rng.range(0.5, 0.8);
            let from = pos + dir * start;
            self.sats.push(Satellite { group, pos: from, from, dir, dist: (stop - start).max(4.0), r0, r: r0, age: 0.0, life });
        }
        if self.sats.len() > 100 {
            let extra = self.sats.len() - 100;
            self.sats.drain(..extra);
        }
    }

    /// mouse: 지금 커서 위치와 왼쪽 버튼이 눌려 있는지
    pub fn update(&mut self, dt: f32, s: &Settings, mouse: (V2, bool)) {
        if self.held() {
            if !mouse.1 {
                self.end(); // 떼는 이벤트를 놓쳤을 때
            } else {
                self.move_to(mouse.0); // 누른 채로 끌면 따라간다
            }
        }
        self.tune = Tuning::from(s);
        let r_max = self.tune.max_r;
        // 스프링이 발산하지 않도록 작은 스텝으로 나눠 적분
        let steps = ((dt * 240.0).ceil() as i32).max(1);
        let h = dt / steps as f32;
        let mut bursts = Vec::new();
        for i in 0..self.blobs.len() {
            let b = &mut self.blobs[i];
            // 위치는 커서에 바로 붙인다. 속도는 늘어남 계산용으로만 짧게 평활화한다
            let raw = (b.target - b.pos) / dt.max(1e-4);
            b.pos = b.target;
            b.vel += (raw - b.vel) * (1.0 - (-dt / 0.02).exp());
            for _ in 0..steps {
                step(b, h, r_max, &self.tune);
            }
            if b.burst_at >= 0.0 && b.age >= b.burst_at {
                b.burst_at = -1.0;
                bursts.push((b.id, b.pos, b.r));
            }
        }
        let tap_r = self.tune.tap_r;
        for (id, pos, r) in bursts {
            self.burst(id, pos, r, 5, 7, tap_r);
        }

        // 잔 물방울: 강한 ease-out(5차)으로 바깥으로 퍼지다 거의 멈추고, 수명 끝으로 갈수록 빠르게 작아진다
        for m in self.sats.iter_mut() {
            m.age += dt;
            let t = (m.age / m.life).min(1.0);
            let ease = 1.0 - (1.0 - t).powi(5);
            m.pos = m.from + m.dir * m.dist * ease;
            // 처음 0.05초 동안 톡 부풀어 나온다
            m.r = m.r0 * (m.age / 0.05).min(1.0).sqrt() * (1.0 - t.powf(2.2));
        }
        self.sats.retain(|m| m.age < m.life);
        // 본 방울은 자기 잔 물방울이 다 사라질 때까지 남긴다 (무리 단위로 그리므로)
        let sats = &self.sats;
        self.blobs.retain(|b| {
            let gone = !b.held && (b.release_age > 1.5 || (b.release_age > 0.1 && b.r < r_max * 0.04));
            !(gone && !sats.iter().any(|m| m.group == b.id))
        });

        let mut heads: Vec<[f32; 4]> = Vec::new();
        let mut satd: Vec<[f32; 4]> = Vec::new();
        let k = self.tune.k();
        // 그리는 사각형에 그림자가 번질 몫까지 더한다
        let pad = k + 4.0 + 4.0 + 21.0 * self.tune.shadow_spread * 1.5;
        let look = (self.tune.shadow, self.tune.shadow_spread);
        let single = |m: &Satellite, heads: &mut Vec<[f32; 4]>, satd: &mut Vec<[f32; 4]>| {
            heads.push([m.pos.x, m.pos.y, 0.0, 1.0]);
            heads.push([0.0, 0.0, satd.len() as f32, 1.0]);
            heads.push([m.r + pad, k, look.0, look.1]);
            satd.push([m.pos.x, m.pos.y, m.r, 0.0]);
        };
        for b in &self.blobs {
            // 아주 작아지면 옅어져서 점처럼 남지 않게
            let x = ((b.r / r_max - 0.04) / 0.12).clamp(0.0, 1.0);
            let alpha = x * x * (3.0 - 2.0 * x);
            let rr = if alpha > 0.0 { b.r } else { 0.0 };
            let st = b.stretch();
            let r_ext = rr * (1.0 + st.len());
            // 본 방울 근처(목이 생길 수 있는 거리)의 잔 물방울만 한 무리로, 멀리 떨어진 건 각자 작은 사각형으로
            let mut near: Vec<&Satellite> = Vec::new();
            for m in self.sats.iter().filter(|m| m.group == b.id && m.r > 0.3) {
                if m.pos.dist(b.pos) - m.r - r_ext < k * 2.0 {
                    near.push(m);
                } else {
                    single(m, &mut heads, &mut satd);
                }
            }
            if alpha <= 0.0 && near.is_empty() {
                continue;
            }
            let mut ext = r_ext;
            for m in &near {
                ext = ext.max(m.pos.dist(b.pos) + m.r);
            }
            heads.push([b.pos.x, b.pos.y, rr, alpha]);
            heads.push([st.x, st.y, satd.len() as f32, near.len() as f32]);
            heads.push([ext + pad, k, look.0, look.1]);
            for m in near {
                satd.push([m.pos.x, m.pos.y, m.r, 0.0]);
            }
        }
        // 본 방울 없는 잔 물방울은 각자 작은 무리로
        for m in self.sats.iter().filter(|m| m.r > 0.3 && !self.blobs.iter().any(|b| b.id == m.group)) {
            single(m, &mut heads, &mut satd);
        }
        self.groups = (heads.len() / 3) as u32;
        // 잔 물방울 번호는 머리 뒤에서부터
        let base = heads.len() as f32;
        for g in 0..self.groups as usize {
            heads[g * 3 + 1][2] += base;
        }
        heads.extend(satd);
        self.data = heads;
    }
}

fn step(b: &mut Blob, h: f32, r_max: f32, t: &Tuning) {
    b.age += h;
    if !b.held {
        b.release_age += h;
    }
    // 크기: 누르는 동안 처음엔 빠르게(살짝 넘쳤다가), 점점 느리게 퍼진다. 떼면 출렁임 없이 매끈하게 줄어든다.
    let tap_r = t.tap_r;
    if b.tap_grow && b.r >= tap_r * 0.9 {
        b.tap_grow = false;
    }
    let (tr, wr, zr);
    if b.held {
        let start = (tap_r * 0.48).min(r_max);
        tr = b.base_r.max(start + (r_max - start) * (1.0 - (-b.age * t.grow / 0.33).exp()));
        wr = 24.0 * t.grow;
        zr = 0.5;
    } else if b.tap_grow {
        tr = tap_r;
        wr = 24.0 * t.grow;
        zr = 0.6;
    } else {
        tr = 0.0;
        wr = 12.0 * t.shrink;
        zr = 1.0;
    }
    b.vr += ((tr - b.r) * wr * wr - b.vr * 2.0 * zr * wr) * h;
    b.r = (b.r + b.vr * h).max(0.0);

    // 늘어남: 끌면 움직이는 방향으로 길쭉해진다. 목표는 속도에 비례하다가 부드럽게 포화한다.
    let v = b.vel;
    let sp = v.len();
    let e_max = 0.7 * t.stretch.min(1.25);
    let eq = if sp > 1.0 && e_max > 0.001 {
        v2(v.x * v.x - v.y * v.y, 2.0 * v.x * v.y) / (sp * sp) * (e_max * (sp * 0.0005 * t.stretch / e_max).tanh())
    } else {
        V2::default()
    };
    let prev = b.shape;
    b.shape += (eq - b.shape) * (1.0 - (-h / 0.022).exp());
    // 뗀 뒤에는 출렁임 없이
    let ws = 13.0;
    let zs = if b.held { 0.22 } else { 0.9 };
    if b.held {
        b.wobble_vel += (b.shape - prev) * 5.0 * t.wobble;
    }
    b.wobble_vel += (-b.wobble * ws * ws - b.wobble_vel * 2.0 * zs * ws) * h;
    b.wobble += b.wobble_vel * h;
}
