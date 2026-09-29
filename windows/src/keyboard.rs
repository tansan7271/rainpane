// 키보드 물방울 (맥판 KeyboardFocus.swift). 선택 기능, 기본 끔.
// Tab으로 포커스를 옮기면 그 자리(텍스트 커서, 없으면 포커스된 요소 가운데)에 톡 물방울,
// Enter로 무언가를 보내거나 누르면 그 칸 가장자리에서 잔 물방울이 튄다.
// 입력칸의 글은 읽지 않는다 (칸 종류·위치·크기·텍스트 커서 위치만). Enter·Tab 말고는 어떤 키인지 보지 않는다.
// 비밀번호 칸에서는 텍스트 커서 위치도 묻지 않는다 (비밀번호 길이가 드러난다).
// 포커스 조회(UI Automation)는 다른 앱에 묻는 일이라 느릴 수 있어서 따로 둔 스레드에서 한다.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Ole::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
use windows::core::Interface;

use crate::v2::{V2, v2};

pub fn key_down(vk: i32) -> bool {
    unsafe { GetAsyncKeyState(vk) < 0 }
}

pub enum Event {
    /// 톡 물방울 (pt)
    Tap(V2),
    /// 칸 가장자리에서 잔 물방울 (pt: x, y, w, h)
    Pop([f32; 4]),
}

enum Req {
    Enter { newline: bool },
    Tab,
}

/// 조회 결과 (물리 픽셀)
enum Found {
    Point(f32, f32),
    Rect(RECT),
}

pub struct Keyboard {
    tx: Option<Sender<Req>>,
    rx: Option<Receiver<Found>>,
}

impl Keyboard {
    pub fn new() -> Keyboard {
        Keyboard { tx: None, rx: None }
    }

    /// Enter·Tab이 눌렸다 (Shift·Alt 상태와 함께)
    pub fn key(&mut self, vk: u16, shift: bool, alt: bool, _now: f64) {
        if self.tx.is_none() {
            let (tx, rx_req) = channel::<Req>();
            let (tx_found, rx) = channel::<Found>();
            std::thread::spawn(move || worker(rx_req, tx_found));
            self.tx = Some(tx);
            self.rx = Some(rx);
        }
        let req = if vk == 0x09 { Req::Tab } else { Req::Enter { newline: shift || alt } };
        if let Some(tx) = &self.tx {
            let _ = tx.send(req);
        }
    }

    pub fn poll(&mut self, _now: f64, scale: f32) -> Vec<Event> {
        let Some(rx) = &self.rx else { return Vec::new() };
        rx.try_iter()
            .map(|f| match f {
                Found::Point(x, y) => Event::Tap(v2(x / scale, y / scale)),
                Found::Rect(r) => Event::Pop([r.left as f32 / scale, r.top as f32 / scale, (r.right - r.left) as f32 / scale, (r.bottom - r.top) as f32 / scale]),
            })
            .collect()
    }

    /// 조회 스레드를 끝낸다 (채널을 닫으면 스스로 끝난다)
    pub fn stop(&mut self) {
        self.tx = None;
        self.rx = None;
    }
}

/// 포커스된 칸 (글은 읽지 않는다)
#[derive(Clone, Copy)]
struct Field {
    pid: i32,
    rect: RECT,
    is_text: bool,
    password: bool,
    /// 코드 편집기 (칸 종류 설명에 "editor": VSCode 편집기): Enter는 줄바꿈이다
    code_editor: bool,
}

impl Field {
    /// 같은 칸, 같은 자리 (Tab이 포커스를 옮겼는지 볼 때)
    fn same_spot(&self, o: &Field) -> bool {
        let d = |a: i32, b: i32| (a - b).abs() < 8;
        self.pid == o.pid && d(self.rect.left, o.rect.left) && d(self.rect.top, o.rect.top) && d(self.rect.right, o.rect.right) && d(self.rect.bottom, o.rect.bottom)
    }
}

struct Uia {
    auto: IUIAutomation,
}

impl Uia {
    fn new() -> Option<Uia> {
        unsafe {
            let auto: IUIAutomation = CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER).or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)).ok()?;
            // 응답이 느린 앱 때문에 오래 붙잡히지 않게
            if let Ok(a2) = auto.cast::<IUIAutomation2>() {
                let _ = a2.SetConnectionTimeout(200);
                let _ = a2.SetTransactionTimeout(200);
            }
            Some(Uia { auto })
        }
    }

    fn focused(&self) -> Option<(IUIAutomationElement, Field)> {
        unsafe {
            let el = self.auto.GetFocusedElement().ok()?;
            let rect = el.CurrentBoundingRectangle().ok()?;
            let pid = el.CurrentProcessId().unwrap_or(0);
            let password = el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false);
            // 텍스트 칸인지는 "텍스트 패턴이 있나"로만 본다 (내용은 묻지 않음)
            let is_text = el.GetCurrentPattern(UIA_TextPatternId).is_ok_and(|p| !p.as_raw().is_null()) || password;
            let code_editor = el.CurrentLocalizedControlType().map(|s| s.to_string().to_lowercase().contains("editor")).unwrap_or(false);
            Some((el, Field { pid, rect, is_text, password, code_editor }))
        }
    }

    /// 텍스트 커서 자리. 길이 0 범위로 먼저 묻고, 빈 사각형이면 커서 앞 글자의 오른쪽 끝으로 (글자 자체는 읽지 않음)
    fn caret(&self, el: &IUIAutomationElement) -> Option<(f32, f32)> {
        unsafe {
            let tp2: IUIAutomationTextPattern2 = el.GetCurrentPatternAs(UIA_TextPattern2Id).ok()?;
            let mut active = windows::core::BOOL::default();
            let range = tp2.GetCaretRange(&mut active).ok()?;
            if let Some(r) = first_rect(&range) {
                return Some((r[0] + r[2] / 2.0, r[1] + r[3] / 2.0));
            }
            let prev = range.Clone().ok()?;
            if prev.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1).is_ok_and(|n| n != 0) {
                if let Some(r) = first_rect(&prev) {
                    return Some((r[0] + r[2], r[1] + r[3] / 2.0));
                }
            }
            let next = range.Clone().ok()?;
            if next.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1).is_ok_and(|n| n != 0) {
                if let Some(r) = first_rect(&next) {
                    return Some((r[0], r[1] + r[3] / 2.0));
                }
            }
            None
        }
    }
}

/// 범위의 첫 사각형 (left, top, width, height)
fn first_rect(range: &IUIAutomationTextRange) -> Option<[f32; 4]> {
    unsafe {
        let arr = range.GetBoundingRectangles().ok()?;
        if arr.is_null() {
            return None;
        }
        let mut out = None;
        let lo = SafeArrayGetLBound(arr, 1).unwrap_or(0);
        let hi = SafeArrayGetUBound(arr, 1).unwrap_or(-1);
        if hi - lo + 1 >= 4 {
            let mut data: *mut std::ffi::c_void = std::ptr::null_mut();
            if SafeArrayAccessData(arr, &mut data).is_ok() {
                let v = std::slice::from_raw_parts(data as *const f64, 4);
                if v[3] > 1.0 {
                    out = Some([v[0] as f32, v[1] as f32, v[2] as f32, v[3] as f32]);
                }
                let _ = SafeArrayUnaccessData(arr);
            }
        }
        let _ = SafeArrayDestroy(arr);
        out
    }
}

fn poppable(r: &RECT, scale: f32) -> bool {
    let (w, h) = ((r.right - r.left) as f32 / scale, (r.bottom - r.top) as f32 / scale);
    (24.0..=1600.0).contains(&w) && (12.0..=500.0).contains(&h)
}

fn worker(rx: Receiver<Req>, tx: Sender<Found>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let Some(uia) = Uia::new() else { return };
    let scale = unsafe { windows::Win32::UI::HiDpi::GetDpiForSystem() } as f32 / 96.0;
    // 마지막으로 본 칸. Tab이 포커스를 옮겼는지 알기 위해 (곧바로 포커스를 옮기는 앱은 Tab 순간에 물어도 이미 옮겨 간 뒤라)
    let mut last: Option<(Field, Instant)> = None;
    while let Ok(req) = rx.recv() {
        match req {
            // Enter: 버튼·링크, 비밀번호 칸에서는 늘 누름·제출. 텍스트 칸은 Shift·Alt+Enter(줄바꿈),
            // 코드 편집기, 폭 80pt 미만의 숨은 입력칸만 빼고 보냄으로 본다
            Req::Enter { newline } => {
                let Some((_, f)) = uia.focused() else { continue };
                last = Some((f, Instant::now()));
                if !poppable(&f.rect, scale) {
                    continue;
                }
                let narrow = ((f.rect.right - f.rect.left) as f32 / scale) < 80.0;
                if f.is_text && !f.password && (newline || f.code_editor || narrow) {
                    continue;
                }
                let _ = tx.send(Found::Rect(f.rect));
            }
            // Tab: 포커스가 다른 칸(또는 같은 칸이라도 다른 자리)으로 옮겨 갔을 때만.
            // 편집기 들여쓰기처럼 칸 안에서 처리된 Tab은 같은 칸·같은 자리에 그대로 있다
            Req::Tab => {
                let before = last.filter(|(_, at)| at.elapsed() < Duration::from_secs(30)).map(|(f, _)| f).or_else(|| uia.focused().map(|(_, f)| f));
                std::thread::sleep(Duration::from_millis(80));
                let Some((el, f)) = uia.focused() else { continue };
                last = Some((f, Instant::now()));
                if before.is_some_and(|b| b.same_spot(&f)) {
                    continue;
                }
                // 비밀번호 칸의 커서 위치는 비밀번호 길이를 드러내니 묻지 않고 칸 가운데로
                let caret = if f.is_text && !f.password { uia.caret(&el) } else { None };
                if let Some((x, y)) = caret {
                    let _ = tx.send(Found::Point(x, y));
                    continue;
                }
                // 편집기 전체·웹 페이지 본문처럼 큰 요소의 가운데는 의미가 없다
                let (w, h) = ((f.rect.right - f.rect.left) as f32 / scale, (f.rect.bottom - f.rect.top) as f32 / scale);
                if w > 0.0 && w < 700.0 && h < 300.0 {
                    let _ = tx.send(Found::Point((f.rect.left + f.rect.right) as f32 / 2.0, (f.rect.top + f.rect.bottom) as f32 / 2.0));
                }
            }
        }
    }
    unsafe {
        CoUninitialize();
    }
}
