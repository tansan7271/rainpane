// 설정 (맥판 Settings.swift). %APPDATA%\Rainpane\settings.json에 JSON으로 저장한다.
// 저장된 파일에 없는 값은 기본값으로 채운다.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lang {
    En,
    Ko,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IconStyle {
    FontAwesome,
    Fluent,
}

static KOREAN: AtomicBool = AtomicBool::new(false);

pub fn set_language(l: Lang) {
    KOREAN.store(l == Lang::Ko, Ordering::Relaxed);
}

/// 화면 문구: 한국어와 영어를 나란히 적는다
#[allow(non_snake_case)]
pub fn L(ko: &'static str, en: &'static str) -> &'static str {
    if KOREAN.load(Ordering::Relaxed) { ko } else { en }
}

#[derive(Clone, Copy, PartialEq, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    // 일반
    pub enabled: bool,
    pub language: Lang,
    pub rain_enabled: bool,
    // 비
    pub intensity: f32,
    pub wind: f32,
    pub gustiness: f32,
    pub fall_speed: f32,
    pub streak_length: f32,
    pub streak_width: f32,
    pub rain_opacity: f32,
    pub depth_step: f32,
    pub desktop_rain: f32,
    pub depth_of_field: f32,
    pub rain_rgb: [f32; 3],
    // 물
    pub pooling: bool,
    pub pool_capacity: f32,
    pub accumulation: f32,
    pub evaporation: f32,
    pub streams: bool,
    pub stream_width: f32,
    pub drips: bool,
    pub sloshing: f32,
    pub pool_inertia: bool,
    pub corner_radius: f32,
    pub curtain: bool,
    pub curtain_strength: f32,
    pub window_droplets: bool,
    pub droplet_frequency: f32,
    pub droplets_on_all_windows: bool,
    pub droplets_except_front: bool,
    pub splashes: bool,
    pub splash_amount: f32,
    // 마우스 물방울
    pub press_effect: bool,
    pub press_tap_radius: f32,
    pub press_max_radius: f32,
    pub press_grow: f32,
    pub press_shrink: f32,
    pub press_stretch: f32,
    pub press_wobble: f32,
    pub press_satellites: bool,
    pub press_sat_count: f32,
    pub press_sat_size: f32,
    pub press_sat_distance: f32,
    pub press_neck: f32,
    pub press_shadow: f32,
    pub press_shadow_spread: f32,
    pub press_scroll_dust: bool,
    pub keyboard_press: bool,
    /// 실험: 물방울 뒤 화면을 굴절시켜 유리처럼 그린다 (Desktop Duplication)
    pub press_glass: bool,
    pub press_glass_refraction: f32,
    pub press_glass_blur: f32,
    pub press_glass_light_bg: f32,
    pub press_glass_dark_bg: f32,
    // 질감
    pub light_angle: f32,
    pub specular: f32,
    pub rim_darkness: f32,
    pub water_tint: f32,
    // 성능
    pub max_fps: u32,
    pub adaptive_fps: bool,
    pub render_scale: f32,
    pub battery_saver: bool,
    pub pause_when_covered: bool,
    pub hide_in_captures: bool,
    pub launch_at_login: bool,
    pub icon_style: IconStyle,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            enabled: true,
            language: Lang::En,
            rain_enabled: true,
            intensity: 0.271,
            wind: 0.35,
            gustiness: 0.448,
            fall_speed: 1.0,
            streak_length: 1.0,
            streak_width: 1.911,
            rain_opacity: 0.774,
            depth_step: 0.099,
            desktop_rain: 1.0,
            depth_of_field: 1.0,
            rain_rgb: [0.72, 0.762, 0.843],
            pooling: true,
            pool_capacity: 2.533,
            accumulation: 4.0,
            evaporation: 0.15,
            streams: true,
            stream_width: 1.498,
            drips: true,
            sloshing: 0.999,
            pool_inertia: true,
            // 윈도우 11 창 모서리
            corner_radius: 8.0,
            curtain: true,
            curtain_strength: 1.096,
            window_droplets: true,
            droplet_frequency: 2.0,
            droplets_on_all_windows: true,
            droplets_except_front: false,
            splashes: true,
            splash_amount: 2.0,
            press_effect: true,
            press_tap_radius: 25.0,
            press_max_radius: 48.0,
            press_grow: 1.0,
            press_shrink: 1.0,
            press_stretch: 1.0,
            press_wobble: 1.0,
            press_satellites: true,
            press_sat_count: 1.0,
            press_sat_size: 1.0,
            press_sat_distance: 1.0,
            press_neck: 1.0,
            press_shadow: 0.15,
            press_shadow_spread: 1.0,
            press_scroll_dust: false,
            keyboard_press: false,
            press_glass: false,
            press_glass_refraction: 1.0,
            press_glass_blur: 0.0,
            press_glass_light_bg: 0.25,
            press_glass_dark_bg: 1.0,
            light_angle: 40.341,
            specular: 1.398,
            rim_darkness: 0.499,
            water_tint: 0.198,
            max_fps: 60,
            adaptive_fps: false,
            render_scale: 1.0,
            battery_saver: false,
            pause_when_covered: true,
            hide_in_captures: true,
            launch_at_login: false,
            icon_style: IconStyle::FontAwesome,
        }
    }
}

/// 모서리 곡선 지수 (2 = 원호. 윈도우 11 창 모서리)
pub const CORNER_EXPONENT: f32 = 2.0;

fn path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(std::path::Path::new(&base).join("Rainpane").join("settings.json"))
}

impl Settings {
    pub fn load() -> Settings {
        path()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(p) = path() else { return };
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            // 쓰다가 끊겨도 원래 파일이 망가지지 않게 임시 파일에 쓰고 바꾼다
            let tmp = p.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, &p);
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Preset {
    Drizzle,
    Normal,
    Shower,
    Storm,
}

impl Preset {
    pub const ALL: [Preset; 4] = [Preset::Drizzle, Preset::Normal, Preset::Shower, Preset::Storm];

    pub fn label(self) -> &'static str {
        match self {
            Preset::Drizzle => L("이슬비", "Drizzle"),
            Preset::Normal => L("보통 비", "Moderate rain"),
            Preset::Shower => L("소나기", "Shower"),
            Preset::Storm => L("폭풍우", "Storm"),
        }
    }

    pub fn apply(self, s: &mut Settings) {
        let v = match self {
            Preset::Drizzle => [0.2, 0.05, 0.15, 0.75, 0.7, 0.8, 0.4, 0.5],
            Preset::Normal => [0.5, 0.12, 0.35, 1.0, 1.0, 1.0, 0.5, 1.0],
            Preset::Shower => [0.8, 0.08, 0.3, 1.15, 1.15, 1.1, 0.55, 1.6],
            Preset::Storm => [1.0, 0.35, 0.8, 1.3, 1.3, 1.15, 0.6, 2.2],
        };
        s.intensity = v[0];
        s.wind = v[1];
        s.gustiness = v[2];
        s.fall_speed = v[3];
        s.streak_length = v[4];
        s.streak_width = v[5];
        s.rain_opacity = v[6];
        s.accumulation = v[7];
    }
}

/// 설정 창에 보여 줄 실시간 통계
#[derive(Clone, Copy, Default)]
pub struct Stats {
    pub fps: f32,
    pub cpu: f32,
    pub windows: usize,
    pub idle: bool,
}

/// 렌더 스레드와 설정 창 스레드가 함께 쓰는 상태
pub struct Shared {
    pub settings: Mutex<Settings>,
    pub stats: Mutex<Stats>,
    /// 설정 창에 보여 줄 오류 (로그인 항목 등)
    pub status: Mutex<Option<String>>,
}

impl Shared {
    pub fn settings(&self) -> Settings {
        *self.settings.lock().unwrap()
    }
}
