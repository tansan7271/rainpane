// 화면의 창 목록과 모니터 읽기. 창 제목과 내용은 읽지 않는다 (클래스 이름, 위치, 크기, 스타일만).

use std::ffi::c_void;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::BOOL;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    /// 물이 고이는 일반 앱 창
    App,
    /// 작업 표시줄, 메뉴, 항상 위 창 등: 비와 물을 가리기만 한다
    Occluder,
}

/// 물이 고이던 창이 목록에서 빠진 이유
pub enum Vanish {
    Closed,
    Minimized,
    /// 다른 가상 데스크톱으로 감 (물은 보관)
    Cloaked,
    /// 아직 보이지만 물이 고이지 않는 창이 됨 (최대화 등)
    Other,
}

pub fn vanish_reason(id: isize) -> Vanish {
    let h = HWND(id as *mut c_void);
    unsafe {
        if !IsWindow(Some(h)).as_bool() || !IsWindowVisible(h).as_bool() {
            return Vanish::Closed;
        }
        if IsIconic(h).as_bool() {
            return Vanish::Minimized;
        }
        let mut cloaked = 0u32;
        if DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut c_void, 4).is_ok() && cloaked != 0 {
            return Vanish::Cloaked;
        }
    }
    Vanish::Other
}

#[derive(Clone, PartialEq, Debug)]
pub struct Win {
    pub hwnd: isize,
    /// 앱 창은 앞에서부터 1, 2, ... 가리기만 하는 창은 0 (그 아래 물과 비를 모두 가린다)
    pub rank: u32,
    /// pt 단위 (x, y, w, h)
    pub rect: [f32; 4],
    pub kind: Kind,
    pub radius: f32,
    pub maximized: bool,
    pub class: String,
}

#[derive(Clone, PartialEq, Debug)]
pub struct Monitor {
    pub hmon: isize,
    /// 물리 픽셀
    pub px: RECT,
    /// pt 단위 (x, y, w, h)
    pub rect: [f32; 4],
    /// 비가 떨어지는 바닥 (pt). 작업 표시줄이 아래에 있으면 그 윗변, 아니면 화면 아래.
    pub floor: f32,
}

pub fn monitors(scale: f32) -> Vec<Monitor> {
    unsafe extern "system" fn cb(h: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        unsafe { (*(data.0 as *mut Vec<HMONITOR>)).push(h) };
        true.into()
    }
    let mut list: Vec<HMONITOR> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(cb), LPARAM(&mut list as *mut _ as isize));
    }
    let mut out = Vec::new();
    for h in list {
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !unsafe { GetMonitorInfoW(h, &mut mi) }.as_bool() {
            continue;
        }
        let m = mi.rcMonitor;
        out.push(Monitor {
            hmon: h.0 as isize,
            px: m,
            rect: [m.left as f32 / scale, m.top as f32 / scale, (m.right - m.left) as f32 / scale, (m.bottom - m.top) as f32 / scale],
            // 작업 영역의 아래 = 아래 작업 표시줄의 윗변 (옆이나 위에 있거나 자동 숨김이면 화면 아래)
            floor: mi.rcWork.bottom as f32 / scale,
        });
    }
    // 주 모니터(원점 포함)를 먼저
    out.sort_by_key(|m| if m.px.left == 0 && m.px.top == 0 { 0 } else { 1 });
    out
}

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 128];
    let n = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// 앞에서 뒤 순서의 창 목록
pub fn windows(own_pid: u32, scale: f32, corner: f32) -> Vec<Win> {
    unsafe extern "system" fn cb(h: HWND, data: LPARAM) -> BOOL {
        unsafe { (*(data.0 as *mut Vec<HWND>)).push(h) };
        true.into()
    }
    let mut list: Vec<HWND> = Vec::with_capacity(256);
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut list as *mut _ as isize));
    }
    let mut out = Vec::new();
    for h in list {
        unsafe {
            if !IsWindowVisible(h).as_bool() || IsIconic(h).as_bool() {
                continue;
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(h, Some(&mut pid));
            let own = pid == own_pid;
            // 다른 가상 데스크톱의 창, 숨은 시작 메뉴 등
            let mut cloaked = 0u32;
            if DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut c_void, 4).is_ok() && cloaked != 0 {
                continue;
            }
            let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
            // 클릭이 통과하는 투명 오버레이 (다른 앱의 화면 효과 등)
            if ex & WS_EX_LAYERED.0 != 0 && ex & WS_EX_TRANSPARENT.0 != 0 {
                continue;
            }
            // 그림자를 뺀 실제로 보이는 창 크기
            let mut r = RECT::default();
            if DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut c_void, std::mem::size_of::<RECT>() as u32).is_err() {
                let _ = GetWindowRect(h, &mut r);
            }
            let (w, hgt) = ((r.right - r.left) as f32 / scale, (r.bottom - r.top) as f32 / scale);
            if w < 4.0 || hgt < 4.0 {
                continue;
            }
            let class = class_name(h);
            if class == "Progman" || class == "WorkerW" {
                continue; // 바탕화면
            }
            // 우리 비 창과 숨은 창은 빼고, 설정 창은 다른 창처럼 다룬다
            if own && class.starts_with("Rainpane") {
                continue;
            }
            let taskbar = class == "Shell_TrayWnd" || class == "Shell_SecondaryTrayWnd";
            let topmost = ex & WS_EX_TOPMOST.0 != 0;
            let tool = ex & WS_EX_TOOLWINDOW.0 != 0;
            let owned = GetWindow(h, GW_OWNER).map(|o| !o.is_invalid()).unwrap_or(false);
            let appwin = ex & WS_EX_APPWINDOW.0 != 0;
            let maximized = IsZoomed(h).as_bool();
            let app = !taskbar && !topmost && !tool && (!owned || appwin) && w >= 80.0 && hgt >= 40.0;
            out.push(Win {
                hwnd: h.0 as isize,
                rank: 0,
                rect: [r.left as f32 / scale, r.top as f32 / scale, w, hgt],
                kind: if app { Kind::App } else { Kind::Occluder },
                // 윈도우 11 창 모서리는 8pt 원호. 최대화한 창과 작업 표시줄은 각진 모서리.
                radius: if taskbar || maximized { 0.0 } else { corner },
                maximized,
                class,
            });
        }
    }
    let mut next = 1;
    for w in out.iter_mut().filter(|w| w.kind == Kind::App) {
        w.rank = next;
        next += 1;
    }
    out
}
