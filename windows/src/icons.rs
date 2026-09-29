// 트레이·창 아이콘. 켜짐 똥, 꺼짐 해골 (맥판과 같은 모양).
// assets/*.a8: 맥판 리소스를 128×128 알파 마스크로 구운 것 (tools/make-icons.swift).
// - Font Awesome Free Solid의 poo·skull 글리프 (아이콘 CC BY 4.0)
// - Microsoft Fluent Emoji 고대비 SVG (MIT)
// 작업 표시줄이 어두우면 흰색, 밝으면 검은색으로 칠한다.

use crate::settings::IconStyle;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Registry::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::w;

const N: usize = 128;
static FA_POO: &[u8] = include_bytes!("../assets/fa-poo.a8");
static FA_SKULL: &[u8] = include_bytes!("../assets/fa-skull.a8");
static FLUENT_POO: &[u8] = include_bytes!("../assets/fluent-poo.a8");
static FLUENT_SKULL: &[u8] = include_bytes!("../assets/fluent-skull.a8");

fn mask(style: IconStyle, on: bool) -> &'static [u8] {
    match (style, on) {
        (IconStyle::FontAwesome, true) => FA_POO,
        (IconStyle::FontAwesome, false) => FA_SKULL,
        (IconStyle::Fluent, true) => FLUENT_POO,
        (IconStyle::Fluent, false) => FLUENT_SKULL,
    }
}

/// 128×128 알파를 size×size로 줄인다 (넓이 평균)
fn scaled(src: &[u8], size: usize) -> Vec<u8> {
    let mut out = vec![0u8; size * size];
    let k = N as f32 / size as f32;
    for y in 0..size {
        for x in 0..size {
            let (x0, x1) = (x as f32 * k, (x + 1) as f32 * k);
            let (y0, y1) = (y as f32 * k, (y + 1) as f32 * k);
            let mut sum = 0.0f32;
            let mut area = 0.0f32;
            for sy in y0.floor() as usize..(y1.ceil() as usize).min(N) {
                let wy = (y1.min(sy as f32 + 1.0) - y0.max(sy as f32)).max(0.0);
                for sx in x0.floor() as usize..(x1.ceil() as usize).min(N) {
                    let wx = (x1.min(sx as f32 + 1.0) - x0.max(sx as f32)).max(0.0);
                    sum += src[sy * N + sx] as f32 * wx * wy;
                    area += wx * wy;
                }
            }
            out[y * size + x] = (sum / area.max(1e-6)).round().min(255.0) as u8;
        }
    }
    out
}

/// 창 아이콘용 RGBA (곧은 알파)
pub fn rgba(style: IconStyle, on: bool, size: usize, rgb: [u8; 3]) -> Vec<u8> {
    scaled(mask(style, on), size).iter().flat_map(|&a| [rgb[0], rgb[1], rgb[2], a]).collect()
}

/// 작업 표시줄이 밝은 테마인지 (HKCU\...\Themes\Personalize\SystemUsesLightTheme)
pub fn taskbar_is_light() -> bool {
    let mut v = 0u32;
    let mut len = 4u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut _ as *mut _),
            Some(&mut len),
        )
    };
    r.is_ok() && v != 0
}

/// 트레이 아이콘
pub fn tray_icon(style: IconStyle, on: bool, size: usize) -> HICON {
    let c = if taskbar_is_light() { 0u8 } else { 255u8 };
    let a = scaled(mask(style, on), size);
    unsafe {
        let bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: size as i32,
                biHeight: -(size as i32), // 위에서 아래
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let Ok(color) = CreateDIBSection(None, &bi, DIB_RGB_COLORS, &mut bits, None, 0) else { return HICON::default() };
        let px = std::slice::from_raw_parts_mut(bits as *mut u8, size * size * 4);
        for (i, &al) in a.iter().enumerate() {
            px[i * 4] = c;
            px[i * 4 + 1] = c;
            px[i * 4 + 2] = c;
            px[i * 4 + 3] = al;
        }
        let mono = CreateBitmap(size as i32, size as i32, 1, 1, None);
        let info = ICONINFO { fIcon: true.into(), xHotspot: 0, yHotspot: 0, hbmMask: mono, hbmColor: color };
        let icon = CreateIconIndirect(&info).unwrap_or_default();
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mono.into());
        icon
    }
}
