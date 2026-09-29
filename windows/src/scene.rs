// 창 목록으로 모니터마다 가려짐 마스크 사각형을 만든다 (맥판 WaterSimulation.buildRects).

use crate::tracker::{Kind, Monitor, Win};

#[derive(Default)]
pub struct Scene {
    /// 모니터마다 [rect, (전역 순위, 모니터 내 순위, 모서리 반경, 0)] (뒤에서 앞 순서)
    pub screen_rects: Vec<Vec<[f32; 4]>>,
    pub version: u64,
}

fn intersects(a: &[f32; 4], b: &[f32; 4]) -> bool {
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}

impl Scene {
    /// 모니터마다 그 모니터에 걸친 앱 창들만으로 순위를 다시 매긴다 (0 = 맨 앞: 비가 안 보임).
    /// 가리기만 하는 창(작업 표시줄, 메뉴 등)은 (0, 0): 비와 물을 모두 가린다.
    pub fn rebuild(&mut self, wins: &[Win], mons: &[Monitor]) {
        self.screen_rects = mons
            .iter()
            .map(|m| {
                let on: Vec<&Win> = wins.iter().filter(|w| intersects(&w.rect, &m.rect)).collect();
                let mut local = Vec::with_capacity(on.len());
                let mut ln = 0f32;
                for w in &on {
                    if w.kind == Kind::App {
                        local.push(ln);
                        ln += 1.0;
                    } else {
                        local.push(0.0);
                    }
                }
                let mut list = Vec::with_capacity(on.len() * 2);
                for (k, w) in on.iter().enumerate().rev() {
                    list.push(w.rect);
                    list.push([w.rank as f32, local[k], w.radius, 0.0]);
                }
                list
            })
            .collect();
        self.version += 1;
    }
}
