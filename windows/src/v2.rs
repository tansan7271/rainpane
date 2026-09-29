// 2차원 벡터 (맥판 SIMD2<Float> 대신)

use std::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};

#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub struct V2 {
    pub x: f32,
    pub y: f32,
}

pub const fn v2(x: f32, y: f32) -> V2 {
    V2 { x, y }
}

impl V2 {
    pub fn len(self) -> f32 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
    pub fn dist(self, o: V2) -> f32 {
        (self - o).len()
    }
    pub fn clamp(self, lo: f32, hi: f32) -> V2 {
        v2(self.x.clamp(lo, hi), self.y.clamp(lo, hi))
    }
}

impl Add for V2 {
    type Output = V2;
    fn add(self, o: V2) -> V2 {
        v2(self.x + o.x, self.y + o.y)
    }
}
impl Sub for V2 {
    type Output = V2;
    fn sub(self, o: V2) -> V2 {
        v2(self.x - o.x, self.y - o.y)
    }
}
impl Mul<f32> for V2 {
    type Output = V2;
    fn mul(self, k: f32) -> V2 {
        v2(self.x * k, self.y * k)
    }
}
impl Mul<V2> for V2 {
    type Output = V2;
    fn mul(self, o: V2) -> V2 {
        v2(self.x * o.x, self.y * o.y)
    }
}
impl Div<f32> for V2 {
    type Output = V2;
    fn div(self, k: f32) -> V2 {
        v2(self.x / k, self.y / k)
    }
}
impl Div<V2> for V2 {
    type Output = V2;
    fn div(self, o: V2) -> V2 {
        v2(self.x / o.x, self.y / o.y)
    }
}
impl Neg for V2 {
    type Output = V2;
    fn neg(self) -> V2 {
        v2(-self.x, -self.y)
    }
}
impl AddAssign for V2 {
    fn add_assign(&mut self, o: V2) {
        self.x += o.x;
        self.y += o.y;
    }
}
impl SubAssign for V2 {
    fn sub_assign(&mut self, o: V2) {
        self.x -= o.x;
        self.y -= o.y;
    }
}
impl MulAssign<f32> for V2 {
    fn mul_assign(&mut self, k: f32) {
        self.x *= k;
        self.y *= k;
    }
}

/// 빠른 난수 (xorshift)
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed | 1)
    }
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    /// 0..1
    pub fn float(&mut self) -> f32 {
        (self.next() >> 40) as f32 * (1.0 / 16_777_216.0)
    }
    pub fn range(&mut self, a: f32, b: f32) -> f32 {
        a + (b - a) * self.float()
    }
    pub fn int(&mut self, a: i32, b: i32) -> i32 {
        a + ((self.float() * (b - a + 1) as f32) as i32).min(b - a)
    }
}
