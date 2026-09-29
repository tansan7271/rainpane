// Rainpane 윈도우판. 트레이 아이콘, 모니터마다 투명 비 창, 창 뒤로 내리는 비, 창 윗변에 고이는 물,
// 옆면 물줄기, 닫을 때 흘러내리는 수막, 마우스로 누른 물방울, 설정 창.
#![windows_subsystem = "windows"]

mod icons;
mod keyboard;
mod press;
mod render;
mod scene;
mod settings;
mod tracker;
mod ui;
mod v2;
mod water;

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::DwmFlush;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Registry::*;
use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::Input::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, Result, w};

use settings::{L, Settings, Shared, Stats, set_language};

static QUIT: AtomicBool = AtomicBool::new(false);
static DISPLAY_CHANGED: AtomicBool = AtomicBool::new(false);
static THEME_CHANGED: AtomicBool = AtomicBool::new(false);
static OPEN_SETTINGS: AtomicBool = AtomicBool::new(false);
/// 원시 입력(마우스·키보드)을 다시 등록해야 함 (설정 창의 winit이 덮어썼을 때)
pub static REREGISTER_INPUT: AtomicBool = AtomicBool::new(false);
static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);
static LOG: Mutex<Option<std::fs::File>> = Mutex::new(None);
static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

/// 마우스·키보드 입력 (물리 픽셀 좌표)
pub enum Input {
    Down(i32, i32),
    Up,
    /// 화면에서 내용이 움직이는 방향 (pt, y 아래)
    Wheel(f32, f32),
    /// Enter·Tab (가상 키, Shift, Alt)
    Key(u16, bool, bool),
}
pub static INPUTS: Mutex<Vec<Input>> = Mutex::new(Vec::new());

pub fn log(s: &str) {
    if let Ok(mut g) = LOG.lock() {
        if let Some(f) = g.as_mut() {
            let _ = writeln!(f, "{}", s);
        }
    }
}

pub fn request_quit() {
    QUIT.store(true, Ordering::Relaxed);
}

const WM_TRAY: u32 = WM_APP + 1;
const ID_ENABLE: usize = 1;
const ID_RAIN: usize = 2;
const ID_PRESS: usize = 3;
const ID_SETTINGS: usize = 4;
const ID_QUIT: usize = 5;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn tray_data(hwnd: HWND, s: &Settings) -> NOTIFYICONDATAW {
    let size = unsafe { GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem()) }.max(16) as usize;
    let mut nid = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
        uCallbackMessage: WM_TRAY,
        hIcon: icons::tray_icon(s.icon_style, s.enabled, size),
        ..Default::default()
    };
    for (i, c) in "Rainpane".encode_utf16().enumerate() {
        nid.szTip[i] = c;
    }
    nid
}

fn update_tray(hwnd: HWND, s: &Settings) {
    let nid = tray_data(hwnd, s);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
        let _ = DestroyIcon(nid.hIcon);
    }
}

fn edit_settings(f: impl FnOnce(&mut Settings)) {
    if let Some(sh) = SHARED.get() {
        let mut g = sh.settings.lock().unwrap();
        f(&mut g);
        g.save();
    }
}

fn show_menu(hwnd: HWND) {
    let Some(sh) = SHARED.get() else { return };
    let s = sh.settings();
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let check = |b: bool| if b { MF_CHECKED } else { MF_UNCHECKED };
        let item = |flags: MENU_ITEM_FLAGS, id: usize, text: &str| {
            let t = wide(text);
            let _ = AppendMenuW(menu, flags, id, PCWSTR(t.as_ptr()));
        };
        item(MF_STRING, ID_ENABLE, if s.enabled { L("Rainpane 끄기", "Turn off Rainpane") } else { L("Rainpane 켜기", "Turn on Rainpane") });
        let dis = if s.enabled { MF_ENABLED } else { MF_GRAYED };
        item(MF_STRING | dis | check(s.rain_enabled), ID_RAIN, L("비", "Rain"));
        item(MF_STRING | dis | check(s.press_effect), ID_PRESS, L("마우스 물방울", "Mouse drops"));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
        item(MF_STRING, ID_SETTINGS, L("설정…", "Settings…"));
        item(MF_STRING, ID_QUIT, L("종료", "Quit"));
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // 메뉴 밖을 누르면 닫히게 하려면 먼저 앞으로 가져와야 한다
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, None, hwnd, None);
        let _ = DestroyMenu(menu);
        match cmd.0 as usize {
            ID_ENABLE => edit_settings(|s| s.enabled = !s.enabled),
            ID_RAIN => edit_settings(|s| s.rain_enabled = !s.rain_enabled),
            ID_PRESS => edit_settings(|s| s.press_effect = !s.press_effect),
            ID_SETTINGS => OPEN_SETTINGS.store(true, Ordering::Relaxed),
            ID_QUIT => QUIT.store(true, Ordering::Relaxed),
            _ => {}
        }
    }
}

fn push_input(i: Input) {
    if let Ok(mut q) = INPUTS.lock() {
        if q.len() < 256 {
            q.push(i);
        }
    }
}

unsafe extern "system" fn main_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY => {
            match (lp.0 as u32) & 0xffff {
                WM_LBUTTONUP => OPEN_SETTINGS.store(true, Ordering::Relaxed),
                WM_RBUTTONUP | WM_CONTEXTMENU => show_menu(hwnd),
                _ => {}
            }
            LRESULT(0)
        }
        WM_INPUT => {
            // 마우스 버튼·휠과 Enter·Tab만 본다. 다른 키는 버린다 (권한이 필요 없고, 시스템 입력 경로에 끼어들지 않는다)
            let mut raw = RAWINPUT::default();
            let mut size = std::mem::size_of::<RAWINPUT>() as u32;
            let n = unsafe { GetRawInputData(HRAWINPUT(lp.0 as *mut _), RID_INPUT, Some(&mut raw as *mut _ as *mut _), &mut size, std::mem::size_of::<RAWINPUTHEADER>() as u32) };
            if n != u32::MAX {
                if raw.header.dwType == RIM_TYPEMOUSE.0 {
                    let (flags, data) = unsafe { (raw.data.mouse.Anonymous.Anonymous.usButtonFlags as u32, raw.data.mouse.Anonymous.Anonymous.usButtonData as i16) };
                    if flags & 0x0002 != 0 {
                        push_input(Input::Up);
                    }
                    if flags & 0x0001 != 0 {
                        let mut pt = POINT::default();
                        let _ = unsafe { GetCursorPos(&mut pt) };
                        push_input(Input::Down(pt.x, pt.y));
                    }
                    // 휠 한 칸(120)은 대략 세 줄. 앞으로 굴리면 내용이 아래로 움직인다
                    if flags & 0x0400 != 0 {
                        push_input(Input::Wheel(0.0, data as f32 * 0.3));
                    }
                    if flags & 0x0800 != 0 {
                        push_input(Input::Wheel(-(data as f32) * 0.3, 0.0));
                    }
                } else if raw.header.dwType == RIM_TYPEKEYBOARD.0 {
                    let k = unsafe { raw.data.keyboard };
                    // 누를 때만 (RI_KEY_BREAK = 1은 뗌)
                    if k.Flags & 1 == 0 && (k.VKey == 0x0D || k.VKey == 0x09) {
                        push_input(Input::Key(k.VKey, keyboard::key_down(0x10), keyboard::key_down(0x12)));
                    }
                }
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_DISPLAYCHANGE | WM_DPICHANGED => {
            DISPLAY_CHANGED.store(true, Ordering::Relaxed);
            LRESULT(0)
        }
        WM_SETTINGCHANGE => {
            // 작업 표시줄 밝기·어둡기가 바뀌면 트레이 아이콘 색을 다시 칠한다
            THEME_CHANGED.store(true, Ordering::Relaxed);
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        _ if msg != 0 && msg == TASKBAR_CREATED.load(Ordering::Relaxed) => {
            // 탐색기가 다시 시작되면 트레이 아이콘을 다시 올린다
            if let Some(sh) = SHARED.get() {
                let nid = tray_data(hwnd, &sh.settings());
                let _ = unsafe { Shell_NotifyIconW(NIM_ADD, &nid) };
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

fn now(freq: i64) -> f64 {
    let mut c = 0i64;
    unsafe {
        let _ = QueryPerformanceCounter(&mut c);
    }
    c as f64 / freq as f64
}

/// 앱 전체 CPU 시간 (초)
fn cpu_time() -> f64 {
    let (mut a, mut b, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    unsafe {
        let _ = GetProcessTimes(GetCurrentProcess(), &mut a, &mut b, &mut k, &mut u);
    }
    let t = |f: FILETIME| ((f.dwHighDateTime as u64) << 32 | f.dwLowDateTime as u64) as f64 * 1e-7;
    t(k) + t(u)
}

/// 배터리로 돌거나 절전 모드인지
fn on_battery() -> bool {
    let mut p = SYSTEM_POWER_STATUS::default();
    unsafe { GetSystemPowerStatus(&mut p) }.is_ok() && (p.ACLineStatus == 0 || p.SystemStatusFlag == 1)
}

/// 로그인할 때 자동 실행 (HKCU\...\Run)
fn set_login_item(on: bool) -> std::result::Result<(), String> {
    let key = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    unsafe {
        if on {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let v = wide(&format!("\"{}\"", exe.display()));
            let r = RegSetKeyValueW(HKEY_CURRENT_USER, key, w!("Rainpane"), REG_SZ.0, Some(v.as_ptr() as *const _), (v.len() * 2) as u32);
            if r.is_err() {
                return Err(format!("{r:?}"));
            }
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, key, w!("Rainpane"));
        }
    }
    Ok(())
}

fn intersects(a: &[f32; 4], b: &[f32; 4]) -> bool {
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let debug = args.iter().any(|a| a == "--debug");
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    // 시험용: --quit-after N (N초 뒤 종료), --intensity X (비 세기 덮어쓰기), --press "x,y,누름,뗌[,dx,dy]" (pt), --settings (설정 창 열기)
    let quit_after: Option<f64> = arg("--quit-after").and_then(|s| s.parse().ok());
    let intensity_override: Option<f32> = arg("--intensity").and_then(|v| v.parse().ok());
    let test_press: Vec<f32> = arg("--press").map(|v| v.split(',').filter_map(|x| x.parse().ok()).collect()).unwrap_or_default();
    let open_settings_at_start = args.iter().any(|a| a == "--settings");
    // 시험용: --glass (유리 물방울 켜기, 설정 파일은 그대로)
    let glass_override = args.iter().any(|a| a == "--glass");
    if debug {
        if let Ok(exe) = std::env::current_exe() {
            *LOG.lock().unwrap() = std::fs::File::create(exe.with_file_name("rainpane.log")).ok();
        }
    }

    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let scale = unsafe { GetDpiForSystem() } as f32 / 96.0;
    let own_pid = std::process::id();
    log(&format!("scale {scale}, pid {own_pid}"));

    let loaded = Settings::load();
    set_language(loaded.language);
    let shared = Arc::new(Shared { settings: Mutex::new(loaded), stats: Mutex::new(Stats::default()), status: Mutex::new(None) });
    let _ = SHARED.set(shared.clone());
    let mut settings_window = ui::SettingsWindow::new(shared.clone());
    // 로그인 항목이 설정과 다르면 맞춘다 (exe를 옮긴 경우 등)
    if loaded.launch_at_login {
        let _ = set_login_item(true);
    }

    // 트레이 아이콘과 입력을 받는 숨은 창
    let hwnd = unsafe {
        let inst = GetModuleHandleW(None)?;
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(main_proc),
            hInstance: inst.into(),
            lpszClassName: w!("RainpaneMain"),
            ..Default::default()
        };
        RegisterClassExW(&wc);
        TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::Relaxed);
        CreateWindowExW(WINDOW_EX_STYLE(0), w!("RainpaneMain"), w!("Rainpane"), WS_POPUP, 0, 0, 0, 0, None, None, Some(inst.into()), None)?
    };
    unsafe {
        let nid = tray_data(hwnd, &loaded);
        let _ = Shell_NotifyIconW(NIM_ADD, &nid);
        let _ = DestroyIcon(nid.hIcon);
        let dev = [
            RAWINPUTDEVICE { usUsagePage: 1, usUsage: 2, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd },
            RAWINPUTDEVICE { usUsagePage: 1, usUsage: 6, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd },
        ];
        // 키보드는 "키보드 물방울"을 켰을 때만 받는다
        let n = if loaded.keyboard_press { 2 } else { 1 };
        if let Err(e) = RegisterRawInputDevices(&dev[..n], std::mem::size_of::<RAWINPUTDEVICE>() as u32) {
            log(&format!("raw input failed: {e:?}"));
        }
    }
    let mut keyboard_on = loaded.keyboard_press;
    let mut kb = keyboard::Keyboard::new();

    render::register_class()?;
    let gpu = match render::Gpu::new() {
        Ok(g) => g,
        Err(e) => {
            log(&format!("gpu init failed: {e:?}"));
            return Err(e);
        }
    };
    log(&format!("adapter: {}", gpu.adapter));

    let make_overlays = |gpu: &render::Gpu, s: &Settings| -> Vec<render::Overlay> {
        tracker::monitors(scale)
            .into_iter()
            .filter_map(|m| match render::Overlay::new(gpu, m, s.hide_in_captures || s.press_glass, s.render_scale.clamp(0.5, 1.0)) {
                Ok(o) => Some(o),
                Err(e) => {
                    log(&format!("overlay failed: {e:?}"));
                    None
                }
            })
            .collect()
    };
    let mut first = loaded;
    first.press_glass |= glass_override;
    let mut overlays = make_overlays(&gpu, &first);
    for o in &overlays {
        log(&format!("monitor {:?} floor {}", o.monitor.rect, o.monitor.floor));
    }

    let mut freq = 0i64;
    unsafe {
        let _ = QueryPerformanceFrequency(&mut freq);
    }
    let t0 = now(freq);
    let seed = {
        let mut c = 0i64;
        unsafe {
            let _ = QueryPerformanceCounter(&mut c);
        }
        c as u64
    };
    let mut scene = scene::Scene::default();
    let mut water = water::Water::new(seed);
    water.screens = overlays.iter().map(|o| o.monitor.clone()).collect();
    let mut press = press::Press::new(seed ^ 0x9E37_79B9_7F4A_7C15);
    let mut last_wins: Vec<tracker::Win> = Vec::new();
    let mut prev = loaded;
    let mut msg = MSG::default();
    let mut test_down = false;
    if open_settings_at_start {
        OPEN_SETTINGS.store(true, Ordering::Relaxed);
    }

    // 프레임 속도·유휴
    let mut last_frame = t0;
    let mut hot_until = 0.0f64;
    let mut boost_until = 0.0f64;
    let mut quiet_frames = 0u32;
    let mut idle = false;
    let mut last_idle_poll = 0.0f64;
    let mut battery = on_battery();
    let mut last_power = t0;
    // 통계
    let mut frames = 0u32;
    let mut last_stats = t0;
    let mut last_cpu = cpu_time();
    let mut last_glass = 0.0f64;

    'run: loop {
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    break 'run;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let t = now(freq);
        if QUIT.load(Ordering::Relaxed) || quit_after.is_some_and(|q| t - t0 > q) {
            break;
        }
        if OPEN_SETTINGS.swap(false, Ordering::Relaxed) {
            // 작업 표시줄 위, 오른쪽 아래 (트레이 쪽)
            let m = overlays.first().map(|o| o.monitor.clone());
            let pos = m.map(|m| [m.rect[0] + m.rect[2] - ui::WIDTH - 20.0, m.floor - ui::HEIGHT - 52.0]).unwrap_or([100.0, 100.0]);
            settings_window.open(pos);
        }

        // 설정 반영
        let mut s = shared.settings();
        if let Some(v) = intensity_override {
            s.intensity = v;
        }
        if glass_override {
            s.press_glass = true;
        }
        let changed = s != prev;
        if changed {
            set_language(s.language);
            if s.enabled != prev.enabled || s.icon_style != prev.icon_style {
                update_tray(hwnd, &s);
            }
            // 유리 물방울은 비 창이 빠진 화면을 읽어야 해서, 켜 두면 늘 캡처에서 뺀다
            if s.hide_in_captures != prev.hide_in_captures || s.press_glass != prev.press_glass {
                for o in &mut overlays {
                    o.set_exclude_capture(s.hide_in_captures || s.press_glass);
                    if !s.press_glass {
                        o.release_capture();
                    }
                }
            }
            if s.render_scale != prev.render_scale {
                DISPLAY_CHANGED.store(true, Ordering::Relaxed);
            }
            if s.launch_at_login != prev.launch_at_login {
                *shared.status.lock().unwrap() = set_login_item(s.launch_at_login).err().map(|e| format!("{}{e}", L("로그인 항목 설정 실패: ", "Could not update the login item: ")));
            }
            if s.rain_enabled != prev.rain_enabled || (!s.pooling && prev.pooling) || !s.enabled {
                water.clear_all();
                last_wins.clear();
            }
            if s.corner_radius != prev.corner_radius {
                last_wins.clear();
            }
            if s.keyboard_press != keyboard_on {
                keyboard_on = s.keyboard_press;
                let dev = RAWINPUTDEVICE {
                    usUsagePage: 1,
                    usUsage: 6,
                    dwFlags: if keyboard_on { RIDEV_INPUTSINK } else { RIDEV_REMOVE },
                    hwndTarget: if keyboard_on { hwnd } else { HWND::default() },
                };
                unsafe {
                    let _ = RegisterRawInputDevices(&[dev], std::mem::size_of::<RAWINPUTDEVICE>() as u32);
                }
                if !keyboard_on {
                    kb.stop();
                }
            }
            prev = s;
        }
        if REREGISTER_INPUT.swap(false, Ordering::Relaxed) {
            let dev = [
                RAWINPUTDEVICE { usUsagePage: 1, usUsage: 2, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd },
                RAWINPUTDEVICE { usUsagePage: 1, usUsage: 6, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd },
            ];
            let n = if keyboard_on { 2 } else { 1 };
            unsafe {
                if let Err(e) = RegisterRawInputDevices(&dev[..n], std::mem::size_of::<RAWINPUTDEVICE>() as u32) {
                    log(&format!("raw input re-register failed: {e:?}"));
                }
            }
        }
        if THEME_CHANGED.swap(false, Ordering::Relaxed) {
            update_tray(hwnd, &s);
        }
        if DISPLAY_CHANGED.swap(false, Ordering::Relaxed) {
            for o in &overlays {
                o.destroy();
            }
            overlays = make_overlays(&gpu, &s);
            water.screens = overlays.iter().map(|o| o.monitor.clone()).collect();
            last_wins.clear();
        }

        // 입력
        let inputs: Vec<Input> = INPUTS.lock().map(|mut q| q.drain(..).collect()).unwrap_or_default();
        let mut pt = POINT::default();
        unsafe {
            let _ = GetCursorPos(&mut pt);
        }
        let mut cursor = v2::v2(pt.x as f32 / scale, pt.y as f32 / scale);
        let press_on = s.enabled && s.press_effect;
        let had_input = !inputs.is_empty();
        for i in inputs {
            match i {
                Input::Down(x, y) if press_on => {
                    press.begin(v2::v2(x as f32 / scale, y as f32 / scale));
                    for o in &overlays {
                        o.raise();
                    }
                }
                Input::Up => press.end(),
                Input::Wheel(dx, dy) if press_on => press.scroll(cursor, v2::v2(dx, dy), t),
                Input::Key(vk, shift, alt) if press_on && keyboard_on => kb.key(vk, shift, alt, t),
                _ => {}
            }
        }
        if !press_on {
            press.clear();
        }
        // 키보드 물방울: 포커스 조회는 다른 스레드에서 하고 결과만 받는다
        for ev in kb.poll(t, scale) {
            match ev {
                keyboard::Event::Tap(p) => press.tap(p),
                keyboard::Event::Pop(r) => press.pop(r),
            }
            for o in &overlays {
                o.raise();
            }
        }

        if !s.enabled {
            for o in &mut overlays {
                o.clear(&gpu);
            }
            unsafe {
                MsgWaitForMultipleObjects(None, false, 500, QS_ALLINPUT);
            }
            last_frame = now(freq);
            continue;
        }

        // 유휴: 비가 0이고 물이 잠잠하면 그리지 않고 창 변화만 초당 4번 본다
        if idle {
            let mut wake = changed || had_input || press.is_active();
            if !wake && s.rain_enabled && t - last_idle_poll >= 0.25 {
                last_idle_poll = t;
                let wins = tracker::windows(own_pid, scale, s.corner_radius);
                wake = wins != last_wins;
            }
            if !wake {
                unsafe {
                    MsgWaitForMultipleObjects(None, false, 250, QS_ALLINPUT);
                }
                continue;
            }
            idle = false;
            quiet_frames = 0;
            last_frame = t;
            shared.stats.lock().unwrap().idle = false;
        }

        // 프레임 속도: 창이 움직이거나 수막·누른 물방울이 있으면 최대, 적응형이면 평소 30
        if t - last_power > 10.0 {
            last_power = t;
            battery = on_battery();
        }
        let mut target = s.max_fps.max(15) as f64;
        if s.adaptive_fps && t >= boost_until {
            target = target.min(30.0);
        }
        if s.battery_saver && battery {
            target = target.min(30.0);
        }
        if t - last_frame < 1.0 / target - 0.003 {
            unsafe {
                let _ = DwmFlush();
            }
            continue;
        }
        let dt = (t - last_frame).min(0.1) as f32;
        last_frame = t;

        let rain_on = s.rain_enabled;
        if rain_on {
            // 창 목록: 바뀌었을 때만 마스크를 다시 만들고 물과 맞춘다
            let wins = tracker::windows(own_pid, scale, s.corner_radius);
            if wins != last_wins {
                let mons: Vec<tracker::Monitor> = overlays.iter().map(|o| o.monitor.clone()).collect();
                scene.rebuild(&wins, &mons);
                water.sync(&wins, &tracker::vanish_reason, t, dt);
                hot_until = t + 0.3;
                if debug {
                    log(&format!("--- windows (front to back) v{}", scene.version));
                    for w in &wins {
                        log(&format!("{:?} rank {} {:?} r{} max {} {:?}", w.kind, w.rank, w.rect, w.radius, w.maximized, w.class));
                    }
                }
                last_wins = wins;
            } else {
                water.idle();
            }
        }
        if (rain_on && (t < hot_until || water.needs_smooth_motion())) || press.is_active() {
            boost_until = t + 0.5;
        }

        let time = (t - t0) % 3600.0;
        let gust = (time * 0.37).sin() * 0.5 + (time * 0.91 + 1.3).sin() * 0.3 + (time * 2.3 + 0.7).sin() * 0.2;
        let wind = s.wind + s.gustiness * 0.12 * gust as f32;
        if rain_on {
            water.update(dt, t - t0, &s, wind);
        }
        let mut pressed = unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } < 0;
        if test_press.len() >= 4 {
            let el = (t - t0) as f32;
            let (tx, ty, down, up) = (test_press[0], test_press[1], test_press[2], test_press[3]);
            let (dx, dy) = if test_press.len() >= 6 { (test_press[4], test_press[5]) } else { (0.0, 0.0) };
            let k = ((el - down) / (up - down).max(0.01)).clamp(0.0, 1.0);
            cursor = v2::v2(tx + dx * k, ty + dy * k);
            pressed = el >= down && el < up;
            if pressed && !test_down {
                press.begin(cursor);
            }
            test_down = pressed;
        }
        press.update(dt, &s, (cursor, pressed));

        let a = s.light_angle.to_radians();
        let base = render::Uniforms {
            time_info: [time as f32, scale, s.corner_radius, s.pool_capacity],
            rain: [s.intensity, wind, s.fall_speed, s.streak_length],
            rain2: [s.streak_width, s.rain_opacity, s.depth_step, s.depth_of_field],
            rain_color: [s.rain_rgb[0], s.rain_rgb[1], s.rain_rgb[2], s.desktop_rain],
            light: [a.sin(), -a.cos(), s.specular, s.rim_darkness],
            water: [0.0, 0.0, s.water_tint, 0.0],
            glass: [s.press_glass_refraction, s.press_glass_blur, s.press_glass_light_bg, s.press_glass_dark_bg],
            ..Default::default()
        };
        // 유리 물방울: 물방울이 있는 동안만 화면을 받는다. 3초 동안 안 쓰면 화면 복제를 놓는다
        let glass = s.press_glass && press.groups > 0;
        if glass {
            last_glass = t;
        } else if last_glass > 0.0 && t - last_glass > 3.0 {
            last_glass = 0.0;
            for o in &mut overlays {
                o.release_capture();
            }
        }
        let splash = if rain_on && s.splashes { ((s.splash_amount * (0.15 + s.intensity) * water.snap.edge_length / 9.0) as u32).min(5000) } else { 0 };
        for (i, o) in overlays.iter_mut().enumerate() {
            // 전체 화면 앱이 이 모니터를 덮고 있으면 그리지 않는다
            if s.pause_when_covered && rain_on && !press.is_active() {
                let m = o.monitor.rect;
                let front = last_wins.iter().find(|w| w.kind == tracker::Kind::App && intersects(&w.rect, &m));
                if front.is_some_and(|w| w.rect[0] - 2.0 <= m[0] && w.rect[1] - 2.0 <= m[1] && w.rect[0] + w.rect[2] + 2.0 >= m[0] + m[2] && w.rect[1] + w.rect[3] + 2.0 >= m[1] + m[3]) {
                    o.clear(&gpu);
                    continue;
                }
            }
            let area = o.monitor.rect[2] * o.monitor.rect[3] / (1512.0 * 982.0);
            let rain = if rain_on && s.intensity > 0.001 { (4200.0 * s.intensity.powf(1.2) * area) as u32 } else { 0 };
            let press_glass = glass && o.capture(&gpu, t);
            let frame = render::Frame { scene: &scene, snap: &water.snap, press: &press.data, press_groups: press.groups, press_glass, rain_count: rain, splash_count: splash };
            if let Err(e) = o.draw(&gpu, &frame, i, &base, scale) {
                log(&format!("draw failed: {e:?}"));
            }
        }

        // 유휴 판정
        if (!rain_on || (s.intensity < 0.005 && !water.is_active())) && !press.is_active() {
            quiet_frames += 1;
            if quiet_frames > 20 {
                idle = true;
                for o in &mut overlays {
                    o.clear(&gpu);
                }
                shared.stats.lock().unwrap().idle = true;
            }
        } else {
            quiet_frames = 0;
        }

        // 통계
        frames += 1;
        if t - last_stats >= 1.0 {
            let el = t - last_stats;
            let cpu = cpu_time();
            let st = Stats { fps: (frames as f64 / el) as f32, cpu: ((cpu - last_cpu) / el * 100.0) as f32, windows: last_wins.iter().filter(|w| w.kind == tracker::Kind::App).count(), idle: false };
            *shared.stats.lock().unwrap() = st;
            if debug {
                log(&format!(
                    "fps {:.1} cpu {:.0}%  pools {}  rivulets {}  drops {}  curtains {}  press {}  ui {}",
                    st.fps,
                    st.cpu,
                    water.snap.pools.len() / 4,
                    water.snap.rivulets.len() / 4,
                    water.snap.drops.len() / 2,
                    water.snap.curtains.len() / 3,
                    press.groups,
                    ui::PAINTS.swap(0, Ordering::Relaxed)
                ));
            }
            if debug {
                for o in &mut overlays {
                    if o.capture_count > 0 {
                        log(&format!("glass capture {:.2} ms avg, {} calls, rects {}", o.capture_time * 1000.0 / o.capture_count as f64, o.capture_count, o.capture_rects));
                    }
                    o.capture_time = 0.0;
                    o.capture_count = 0;
                    o.capture_rects = 0;
                }
            }
            frames = 0;
            last_stats = t;
            last_cpu = cpu;
        }
        // 다음 화면 합성까지 기다린다
        unsafe {
            let _ = DwmFlush();
        }
    }

    shared.settings().save();
    unsafe {
        let nid = NOTIFYICONDATAW { cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32, hWnd: hwnd, uID: 1, ..Default::default() };
        let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
    }
    kb.stop();
    for o in &overlays {
        o.destroy();
    }
    log("quit");
    // 설정 창 스레드(winit)가 남아 있어도 끝낸다
    std::process::exit(0);
}
