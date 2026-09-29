// 설정 창 (맥판 SettingsView.swift). egui로 그리고, 렌더 루프와 따로 자기 스레드에서 돈다.
// 창은 winit, 그리기는 Direct3D 11 (egui-directx11). 윈도우 ARM에는 OpenGL이 없는 경우가 있어서 D3D11을 쓴다.
// 창을 닫으면 숨기기만 한다 (winit 이벤트 루프는 프로세스에서 한 번만 만들 수 있다).

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use egui::{self, Align, Color32, Layout, RichText};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalPosition, LogicalSize, PhysicalSize};
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Icon, Window, WindowButtons, WindowId};

use crate::settings::{IconStyle, L, Lang, Preset, Settings, Shared, set_language};

#[derive(Clone, Copy, PartialEq)]
enum Tab {
    Rain,
    Water,
    Drop,
    Look,
    Speed,
}

impl Tab {
    const ALL: [Tab; 5] = [Tab::Rain, Tab::Water, Tab::Drop, Tab::Look, Tab::Speed];
    fn label(self) -> &'static str {
        match self {
            Tab::Rain => L("비", "Rain"),
            Tab::Water => L("물", "Water"),
            Tab::Drop => L("물방울", "Drops"),
            Tab::Look => L("질감", "Look"),
            Tab::Speed => L("성능", "Speed"),
        }
    }
}

/// 설정 창을 그린 횟수 (디버그 로그용)
pub static PAINTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// 시험용: --tab water|drops|look|speed 로 처음 보여 줄 탭
fn start_tab() -> Tab {
    let args: Vec<String> = std::env::args().collect();
    match args.iter().position(|a| a == "--tab").and_then(|i| args.get(i + 1)).map(|s| s.as_str()) {
        Some("water") => Tab::Water,
        Some("drops") => Tab::Drop,
        Some("look") => Tab::Look,
        Some("speed") => Tab::Speed,
        _ => Tab::Rain,
    }
}

pub const WIDTH: f32 = 380.0;
pub const HEIGHT: f32 = 700.0;

enum UserEvent {
    Show([f32; 2]),
}

pub struct SettingsWindow {
    proxy: Option<EventLoopProxy<UserEvent>>,
    shared: Arc<Shared>,
}

impl SettingsWindow {
    pub fn new(shared: Arc<Shared>) -> SettingsWindow {
        SettingsWindow { proxy: None, shared }
    }

    /// pos: 창 왼쪽 위 (논리 픽셀)
    pub fn open(&mut self, pos: [f32; 2]) {
        if let Some(p) = &self.proxy {
            if p.send_event(UserEvent::Show(pos)).is_ok() {
                return;
            }
        }
        let (tx, rx) = channel();
        let shared = self.shared.clone();
        std::thread::spawn(move || {
            use winit::platform::windows::EventLoopBuilderExtWindows;
            let el = match EventLoop::<UserEvent>::with_user_event().with_any_thread(true).build() {
                Ok(el) => el,
                Err(e) => {
                    crate::log(&format!("settings window: {e}"));
                    return;
                }
            };
            let _ = tx.send(el.create_proxy());
            let egui_ctx = egui::Context::default();
            setup_fonts(&egui_ctx);
            let mut runner = Runner {
                pos,
                egui: egui_ctx,
                app: App { shared, tab: start_tab(), dirty_at: None, icon: None },
                window: None,
                gfx: None,
                visible: true,
                next_paint: None,
            };
            if let Err(e) = el.run_app(&mut runner) {
                crate::log(&format!("settings window: {e}"));
            }
        });
        self.proxy = rx.recv_timeout(Duration::from_secs(3)).ok();
    }
}

struct Gfx {
    device: ID3D11Device,
    ctx: ID3D11DeviceContext,
    swap: IDXGISwapChain1,
    rtv: Option<ID3D11RenderTargetView>,
    renderer: egui_directx11::Renderer,
    winit: egui_winit::State,
}

impl Gfx {
    fn new(window: &Window, egui_ctx: &egui::Context) -> windows::core::Result<Gfx> {
        use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
        let hwnd = match window.window_handle().map(|h| h.as_raw()) {
            Ok(RawWindowHandle::Win32(h)) => HWND(h.hwnd.get() as _),
            _ => return Err(windows::core::Error::from(E_FAIL)),
        };
        let PhysicalSize { width, height } = window.inner_size();
        unsafe {
            let mut device = None;
            let mut ctx = None;
            let levels = [D3D_FEATURE_LEVEL_11_0];
            let flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            if D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, HMODULE::default(), flags, Some(&levels), D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx)).is_err() {
                D3D11CreateDevice(None, D3D_DRIVER_TYPE_WARP, HMODULE::default(), flags, Some(&levels), D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx))?;
            }
            let device: ID3D11Device = device.unwrap();
            let ctx = ctx.unwrap();
            let dxgi: IDXGIDevice = windows::core::Interface::cast(&device)?;
            let factory: IDXGIFactory2 = dxgi.GetAdapter()?.GetParent()?;
            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Width: width.max(1),
                Height: height.max(1),
                Format: DXGI_FORMAT_R8G8B8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                ..Default::default()
            };
            let swap = factory.CreateSwapChainForHwnd(&device, hwnd, &desc, None, None)?;
            let _ = factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);
            let renderer = egui_directx11::Renderer::new(&device)?;
            let winit = egui_winit::State::new(egui_ctx.clone(), egui_ctx.viewport_id(), window, None, None, None);
            let mut g = Gfx { device, ctx, swap, rtv: None, renderer, winit };
            g.make_rtv()?;
            Ok(g)
        }
    }

    fn make_rtv(&mut self) -> windows::core::Result<()> {
        unsafe {
            let tex: ID3D11Texture2D = self.swap.GetBuffer(0)?;
            let mut rtv = None;
            self.device.CreateRenderTargetView(&tex, None, Some(&mut rtv))?;
            self.rtv = rtv;
        }
        Ok(())
    }

    fn resize(&mut self, w: u32, h: u32) {
        self.rtv = None;
        unsafe {
            let _ = self.swap.ResizeBuffers(2, w.max(1), h.max(1), DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SWAP_CHAIN_FLAG(0));
        }
        let _ = self.make_rtv();
    }
}

struct Runner {
    pos: [f32; 2],
    egui: egui::Context,
    app: App,
    window: Option<Window>,
    gfx: Option<Gfx>,
    visible: bool,
    next_paint: Option<Instant>,
}

impl Runner {
    fn paint(&mut self) {
        let (Some(window), Some(gfx)) = (self.window.as_ref(), self.gfx.as_mut()) else { return };
        if !self.visible {
            return;
        }
        PAINTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let input = gfx.winit.take_egui_input(window);
        let app = &mut self.app;
        let out = self.egui.run_ui(input, |ui| app.ui(ui));
        let delay = out.viewport_output.get(&egui::ViewportId::ROOT).map(|v| v.repaint_delay);
        let (ro, po, _) = egui_directx11::split_output(out);
        gfx.winit.handle_platform_output(window, po);
        if let Some(rtv) = &gfx.rtv {
            unsafe {
                // 창 아래쪽 빈 곳도 패널 색으로
                let c = self.egui.global_style().visuals.panel_fill.to_normalized_gamma_f32();
                gfx.ctx.ClearRenderTargetView(rtv, &c);
            }
            let _ = gfx.renderer.render(&gfx.ctx, rtv, &self.egui, ro);
            unsafe {
                let _ = gfx.swap.Present(1, DXGI_PRESENT(0));
            }
        }
        self.app.tick();
        match delay {
            Some(d) if d.is_zero() => window.request_redraw(),
            Some(d) if d < Duration::from_secs(3600) => {
                let t = Instant::now() + d;
                self.next_paint = Some(self.next_paint.map_or(t, |n| n.min(t)));
            }
            _ => {}
        }
        // 저장을 기다리는 동안에는 한 번 더 깨운다
        if self.app.dirty_at.is_some() {
            let t = Instant::now() + Duration::from_millis(550);
            self.next_paint = Some(self.next_paint.map_or(t, |n| n.min(t)));
        }
    }
}

impl ApplicationHandler<UserEvent> for Runner {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        // winit은 이벤트 루프를 만들 때 마우스·키보드 원시 입력을 자기 창으로 등록한다. 원시 입력 등록은 프로세스에
        // 하나뿐이라, 그대로 두면 렌더 루프의 마우스 물방울·키보드 입력이 끊긴다. winit 쪽은 끄고 렌더 루프가 다시 등록한다
        el.listen_device_events(winit::event_loop::DeviceEvents::Never);
        crate::REREGISTER_INPUT.store(true, std::sync::atomic::Ordering::Relaxed);
        let s = self.app.shared.settings();
        let icon = Icon::from_rgba(crate::icons::rgba(s.icon_style, true, 64, [70, 52, 40]), 64, 64).ok();
        let attrs = Window::default_attributes()
            .with_title("Rainpane")
            .with_inner_size(LogicalSize::new(WIDTH, HEIGHT))
            .with_resizable(false)
            .with_enabled_buttons(WindowButtons::CLOSE | WindowButtons::MINIMIZE)
            .with_position(LogicalPosition::new(self.pos[0], self.pos[1]))
            .with_window_icon(icon);
        let window = match el.create_window(attrs) {
            Ok(w) => w,
            Err(e) => {
                crate::log(&format!("settings window: {e}"));
                el.exit();
                return;
            }
        };
        match Gfx::new(&window, &self.egui) {
            Ok(g) => self.gfx = Some(g),
            Err(e) => crate::log(&format!("settings window d3d11: {e:?}")),
        }
        window.request_redraw();
        self.window = Some(window);
    }

    fn window_event(&mut self, _el: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(window) = self.window.as_ref() else { return };
        if matches!(event, WindowEvent::CloseRequested) {
            // 닫기: 숨기기만 한다
            window.set_visible(false);
            self.visible = false;
            self.next_paint = None;
            self.app.save_now();
            return;
        }
        if let Some(gfx) = self.gfx.as_mut() {
            let r = gfx.winit.on_window_event(window, &event);
            // egui-winit은 그리기 이벤트 자체도 "다시 그려야 함"으로 돌려준다. 그대로 따르면 끝없이 다시 그린다
            if r.repaint && !matches!(event, WindowEvent::RedrawRequested) {
                window.request_redraw();
            }
        }
        match event {
            WindowEvent::RedrawRequested => self.paint(),
            WindowEvent::Resized(sz) => {
                if let Some(g) = self.gfx.as_mut() {
                    g.resize(sz.width, sz.height);
                }
            }
            _ => {}
        }
    }

    fn user_event(&mut self, _el: &ActiveEventLoop, ev: UserEvent) {
        let Some(window) = self.window.as_ref() else { return };
        match ev {
            UserEvent::Show(pos) => {
                window.set_outer_position(LogicalPosition::new(pos[0], pos[1]));
                window.set_visible(true);
                window.set_minimized(false);
                window.focus_window();
                self.visible = true;
                window.request_redraw();
            }
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        match self.next_paint {
            Some(t) if Instant::now() >= t => {
                self.next_paint = None;
                if let Some(w) = self.window.as_ref() {
                    w.request_redraw();
                }
                el.set_control_flow(ControlFlow::Wait);
            }
            Some(t) => el.set_control_flow(ControlFlow::WaitUntil(t)),
            None => el.set_control_flow(ControlFlow::Wait),
        }
    }
}

/// 한글: 맑은 고딕을 대체 글꼴로 붙인다
fn setup_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
    for (name, file) in [("malgun", "malgun.ttf"), ("segoe", "segoeui.ttf")] {
        if let Ok(bytes) = std::fs::read(format!("{windir}\\Fonts\\{file}")) {
            fonts.font_data.insert(name.into(), Arc::new(egui::FontData::from_owned(bytes)));
        }
    }
    let prop = fonts.families.get_mut(&egui::FontFamily::Proportional).unwrap();
    if fonts.font_data.contains_key("segoe") {
        prop.insert(0, "segoe".into());
    }
    if fonts.font_data.contains_key("malgun") {
        prop.insert(if fonts.font_data.contains_key("segoe") { 1 } else { 0 }, "malgun".into());
        fonts.families.get_mut(&egui::FontFamily::Monospace).unwrap().push("malgun".into());
    }
    ctx.set_fonts(fonts);
}

struct App {
    shared: Arc<Shared>,
    tab: Tab,
    /// 바뀐 설정을 저장할 시각 (0.5초 동안 더 안 바뀌면 저장)
    dirty_at: Option<Instant>,
    icon: Option<(IconStyle, bool, egui::TextureHandle)>,
}

impl App {
    fn tick(&mut self) {
        if self.dirty_at.is_some_and(|t| t.elapsed() >= Duration::from_millis(500)) {
            self.save_now();
        }
    }

    fn save_now(&mut self) {
        if self.dirty_at.take().is_some() {
            self.shared.settings().save();
        }
    }

    fn ui(&mut self, ui: &mut egui::Ui) {
        let before = self.shared.settings();
        let mut s = before;
        egui::Frame::central_panel(ui.style()).show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = 6.0;
            self.header(ui, &mut s);
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                for t in Tab::ALL {
                    ui.selectable_value(&mut self.tab, t, t.label());
                }
            });
            ui.separator();
            let footer_h = 64.0;
            egui::ScrollArea::vertical().max_height(ui.available_height() - footer_h).auto_shrink([false, false]).show(ui, |ui| {
                ui.spacing_mut().slider_width = ui.available_width() - 8.0;
                match self.tab {
                    Tab::Rain => rain_tab(ui, &mut s),
                    Tab::Water => water_tab(ui, &mut s),
                    Tab::Drop => drop_tab(ui, &mut s),
                    Tab::Look => look_tab(ui, &mut s),
                    Tab::Speed => speed_tab(ui, &mut s),
                }
                ui.add_space(8.0);
            });
            if let Some(msg) = self.shared.status.lock().unwrap().clone() {
                ui.label(RichText::new(msg).small().color(Color32::from_rgb(230, 140, 40)));
            }
            ui.separator();
            self.footer(ui, &mut s);
        });
        if s != before {
            set_language(s.language);
            *self.shared.settings.lock().unwrap() = s;
            self.dirty_at = Some(Instant::now());
        }
        // 통계는 1초마다
        ui.ctx().request_repaint_after(Duration::from_secs(1));
    }

    fn header(&mut self, ui: &mut egui::Ui, s: &mut Settings) {
        let dark = ui.visuals().dark_mode;
        let need = match &self.icon {
            Some((st, on, _)) => *st != s.icon_style || *on != s.enabled,
            None => true,
        };
        if need {
            let rgb = if dark { [235, 235, 235] } else { [40, 40, 40] };
            let img = egui::ColorImage::from_rgba_unmultiplied([48, 48], &crate::icons::rgba(s.icon_style, s.enabled, 48, rgb));
            let tex = ui.ctx().load_texture("header-icon", img, egui::TextureOptions::LINEAR);
            self.icon = Some((s.icon_style, s.enabled, tex));
        }
        ui.horizontal(|ui| {
            if let Some((_, _, tex)) = &self.icon {
                ui.image((tex.id(), egui::vec2(22.0, 22.0)));
            }
            ui.label(RichText::new("Rainpane").strong().size(17.0));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                toggle(ui, &mut s.enabled);
                // 언어 전환: 바꿀 언어 이름을 보여 준다
                let other = if s.language == Lang::En { "한국어" } else { "English" };
                if ui.small_button(other).clicked() {
                    s.language = if s.language == Lang::En { Lang::Ko } else { Lang::En };
                }
            });
        });
        // 비만, 또는 마우스 물방울만 쓸 수 있게 따로 켜고 끈다
        ui.add_enabled_ui(s.enabled, |ui| {
            ui.horizontal(|ui| {
                toggle(ui, &mut s.rain_enabled);
                ui.label(L("비", "Rain"));
                ui.add_space(14.0);
                toggle(ui, &mut s.press_effect);
                ui.label(L("마우스 물방울", "Mouse drops"));
            });
        });
        ui.horizontal_wrapped(|ui| {
            for p in Preset::ALL {
                if ui.button(p.label()).clicked() {
                    p.apply(s);
                }
            }
        });
    }

    fn footer(&mut self, ui: &mut egui::Ui, s: &mut Settings) {
        let st = *self.shared.stats.lock().unwrap();
        let text = if st.idle {
            L("대기 중 (비 없음)", "Idle (no rain)").to_string()
        } else if s.language == Lang::Ko {
            format!("{:.0} fps · CPU {:.0}% · 창 {}", st.fps, st.cpu, st.windows)
        } else {
            format!("{:.0} fps · CPU {:.0}% · windows {}", st.fps, st.cpu, st.windows)
        };
        ui.horizontal(|ui| {
            ui.label(RichText::new(text).small().monospace().weak());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if ui.small_button(L("종료", "Quit")).clicked() {
                    self.shared.settings().save();
                    crate::request_quit();
                }
                if ui.small_button(L("기본값", "Defaults")).clicked() {
                    let (enabled, language, login, icon) = (s.enabled, s.language, s.launch_at_login, s.icon_style);
                    *s = Settings::default();
                    s.enabled = enabled;
                    s.language = language;
                    s.launch_at_login = login;
                    s.icon_style = icon;
                }
            });
        });
    }
}

// ---------- 탭들 ----------

fn rain_tab(ui: &mut egui::Ui, s: &mut Settings) {
    section(ui, L("빗줄기", "Rain streaks"));
    slider(ui, L("양", "Amount"), &mut s.intensity, 0.0..=1.0, pct, None);
    slider(ui, L("바람", "Wind"), &mut s.wind, -0.8..=0.8, signed, None);
    slider(ui, L("돌풍", "Gusts"), &mut s.gustiness, 0.0..=1.0, pct, None);
    slider(ui, L("낙하 속도", "Fall speed"), &mut s.fall_speed, 0.4..=2.0, mult, None);
    slider(ui, L("빗줄기 길이", "Streak length"), &mut s.streak_length, 0.3..=2.5, mult, None);
    slider(ui, L("빗줄기 굵기", "Streak width"), &mut s.streak_width, 0.4..=2.5, mult, None);
    slider(ui, L("밝기", "Brightness"), &mut s.rain_opacity, 0.05..=1.0, pct, None);
    section(ui, L("깊이", "Depth"));
    slider(
        ui,
        L("창 한 겹당 비 가시도", "Rain visibility per window layer"),
        &mut s.depth_step,
        0.0..=1.0,
        pct,
        Some(L("맨 앞 창엔 비가 없고, 뒤 창일수록 이만큼씩 비가 더 보여요", "The front window gets no rain. Each window further back gets this much more")),
    );
    slider(ui, L("바탕화면 비", "Rain on desktop"), &mut s.desktop_rain, 0.0..=1.0, pct, None);
    slider(ui, L("가까운 빗방울 흐림", "Blur on close raindrops"), &mut s.depth_of_field, 0.0..=1.0, pct, None);
    ui.horizontal(|ui| {
        ui.label(L("빗줄기 색", "Streak color"));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.color_edit_button_rgb(&mut s.rain_rgb);
        });
    });
}

fn water_tab(ui: &mut egui::Ui, s: &mut Settings) {
    section(ui, L("고이는 물", "Pooling water"));
    ui.checkbox(&mut s.pooling, L("창 윗변에 물 고이기", "Water pools on window tops"));
    slider(ui, L("최대 높이", "Max height"), &mut s.pool_capacity, 1.0..=12.0, pt, None);
    slider(ui, L("고이는 속도", "Pooling speed"), &mut s.accumulation, 0.1..=4.0, mult, None);
    slider(ui, L("증발", "Evaporation"), &mut s.evaporation, 0.0..=1.0, pct, None);
    slider(ui, L("창 끌 때 출렁임", "Slosh when dragging windows"), &mut s.sloshing, 0.0..=3.0, mult, None);
    ui.checkbox(&mut s.pool_inertia, L("관성 (창을 확 내리면 물이 공중에 남음)", "Inertia (water stays in midair if a window moves down fast)"));
    slider(
        ui,
        L("창 모서리 반경", "Window corner radius"),
        &mut s.corner_radius,
        0.0..=30.0,
        pt,
        Some(L("윈도우 11 창은 8pt예요", "Windows 11 windows use 8 pt")),
    );
    section(ui, L("흐르는 물", "Running water"));
    ui.checkbox(&mut s.streams, L("옆면 물줄기", "Streams down the sides"));
    slider(ui, L("물줄기 굵기", "Stream width"), &mut s.stream_width, 0.3..=2.5, mult, None);
    ui.checkbox(&mut s.drips, L("모서리 낙수", "Drips from corners"));
    ui.checkbox(&mut s.splashes, L("빗방울 튀김", "Raindrop splashes"));
    slider(ui, L("튀김 양", "Splash amount"), &mut s.splash_amount, 0.0..=2.0, mult, None);
    section(ui, L("창 닫을 때", "When a window closes"));
    ui.checkbox(&mut s.curtain, L("수막이 화면을 타고 흘러내림", "Water sheet slides down the screen"));
    slider(ui, L("수막 세기", "Water sheet strength"), &mut s.curtain_strength, 0.2..=2.5, mult, None);
    section(ui, L("창 유리 위 물방울", "Drops on window glass"));
    ui.checkbox(&mut s.window_droplets, L("천장에서 물방울이 또르르", "Drops roll down from the top edge"));
    slider(ui, L("빈도", "Frequency"), &mut s.droplet_frequency, 0.05..=2.0, mult, None);
    // 둘은 함께 켤 수 없다 (둘 다 끄면 맨 앞 창에만)
    let mut all = s.droplets_on_all_windows && !s.droplets_except_front;
    if ui.checkbox(&mut all, L("맨 앞 창뿐 아니라 모든 창에", "On all windows, not just the front one")).changed() {
        s.droplets_on_all_windows = all;
        if all {
            s.droplets_except_front = false;
        }
    }
    let mut except = s.droplets_except_front;
    if ui.checkbox(&mut except, L("맨 앞 창 빼고 모든 창에", "On all windows except the front one")).changed() {
        s.droplets_except_front = except;
        if except {
            s.droplets_on_all_windows = false;
        }
    }
}

fn drop_tab(ui: &mut egui::Ui, s: &mut Settings) {
    section(ui, L("누르기", "Press"));
    slider(
        ui,
        L("톡 클릭 크기", "Quick click size"),
        &mut s.press_tap_radius,
        8.0..=90.0,
        pt,
        Some(L("짧게 클릭했을 때 퍼지는 반경", "How far a drop spreads on a quick click")),
    );
    slider(ui, L("누르고 있을 때 최대 크기", "Max size while held"), &mut s.press_max_radius, 16.0..=120.0, pt, None);
    slider(ui, L("퍼지는 속도", "Spread speed"), &mut s.press_grow, 0.3..=3.0, mult, None);
    slider(ui, L("사라지는 속도", "Fade speed"), &mut s.press_shrink, 0.3..=3.0, mult, None);
    section(ui, L("끌 때", "Dragging"));
    slider(ui, L("늘어나는 정도", "Stretch"), &mut s.press_stretch, 0.0..=2.5, mult, None);
    slider(ui, L("멈출 때 말랑하게 출렁임", "Soft wobble when it stops"), &mut s.press_wobble, 0.0..=3.0, mult, None);
    section(ui, L("잔 물방울", "Small droplets"));
    ui.checkbox(&mut s.press_satellites, L("누르고 뗄 때 잔 물방울이 튐", "Small droplets fly off on press and release"));
    slider(ui, L("개수", "Count"), &mut s.press_sat_count, 0.3..=2.5, mult, None);
    slider(ui, L("크기", "Size"), &mut s.press_sat_size, 0.4..=2.5, mult, None);
    slider(ui, L("퍼지는 거리", "Spread distance"), &mut s.press_sat_distance, 0.0..=3.0, mult, None);
    slider(
        ui,
        L("이어지는 목 길이", "Neck length"),
        &mut s.press_neck,
        0.2..=3.0,
        mult,
        Some(L("본 방울과 잔 물방울이 이만큼 가까우면 목으로 이어져요", "Small droplets this close to the main drop join it with a neck")),
    );
    section(ui, L("그림자", "Shadow"));
    slider(ui, L("진하기", "Darkness"), &mut s.press_shadow, 0.0..=0.5, pct, None);
    slider(ui, L("퍼짐", "Spread"), &mut s.press_shadow_spread, 0.3..=3.0, mult, None);
    section(ui, L("리퀴드 글래스 (실험)", "Liquid Glass (experimental)"));
    ui.checkbox(&mut s.press_glass, L("유리 물방울", "Glass drops"));
    hint(
        ui,
        L(
            "물방울이 있는 동안 그 뒤 화면을 읽어 굴절시켜요 (윈도우 화면 복제, 권한 필요 없음). 화면 이미지는 GPU 안에서만 쓰고 저장하지 않아요. 켜 두면 비는 늘 캡처에서 빠져요.",
            "While a drop is on screen, it reads the screen behind it and bends it (Windows desktop duplication, no permission needed). The image stays on the GPU and is never saved. While this is on, rain is always left out of captures.",
        ),
    );
    ui.add_enabled_ui(s.press_glass, |ui| {
        slider(ui, L("굴절 세기", "Refraction strength"), &mut s.press_glass_refraction, 0.0..=3.0, mult, None);
        slider(ui, L("흐림", "Blur"), &mut s.press_glass_blur, 0.0..=12.0, pt, Some(L("0이면 완전히 맑아요", "At 0 the glass is fully clear")));
        slider(
            ui,
            L("밝은 배경에서 보이기", "Visibility on light backgrounds"),
            &mut s.press_glass_light_bg,
            0.0..=1.0,
            pct,
            Some(L("밝은 배경을 살짝 어둡게 비춰요. 0이면 완전히 투명해요", "The drop slightly darkens light backgrounds. At 0 it is fully transparent")),
        );
        slider(
            ui,
            L("어두운 배경에서 보이기", "Visibility on dark backgrounds"),
            &mut s.press_glass_dark_bg,
            0.0..=2.0,
            pct,
            Some(L("어두운 배경을 살짝 밝게 비춰요", "The drop slightly brightens dark backgrounds")),
        );
    });
    section(ui, L("다른 입력", "Other input"));
    ui.checkbox(&mut s.press_scroll_dust, L("스크롤할 때 잔 물방울이 흩날림", "Small droplets scatter when scrolling"));
    ui.checkbox(&mut s.keyboard_press, L("키보드: Enter·Tab 때 커서 자리에도", "Keyboard: also at the cursor on Return and Tab"));
    hint(ui, L("Enter·Tab 말고는 보지 않고, 입력한 내용은 읽지 않아요. 비밀번호 칸은 건너뛰어요.", "Watches only Return and Tab. Never reads what you type. Skips password fields."));
}

fn look_tab(ui: &mut egui::Ui, s: &mut Settings) {
    section(ui, L("빛", "Light"));
    slider(ui, L("빛 방향", "Light direction"), &mut s.light_angle, -90.0..=90.0, deg, None);
    slider(ui, L("반짝임", "Highlights"), &mut s.specular, 0.0..=2.0, mult, None);
    slider(ui, L("가장자리 어둠", "Edge darkness"), &mut s.rim_darkness, 0.0..=1.0, pct, None);
    slider(ui, L("물 색조", "Water tint"), &mut s.water_tint, 0.0..=0.5, pct, None);
}

fn speed_tab(ui: &mut egui::Ui, s: &mut Settings) {
    section(ui, L("프레임", "Frame rate"));
    ui.horizontal(|ui| {
        ui.label(L("최대 FPS", "Max FPS"));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            for fps in [120, 60, 30] {
                ui.selectable_value(&mut s.max_fps, fps, fps.to_string());
            }
        });
    });
    ui.checkbox(&mut s.adaptive_fps, L("적응형 (평소 30fps, 창 움직일 때만 최대)", "Adaptive (30fps normally, max only while windows move)"));
    hint(
        ui,
        L(
            "투명 전체 화면 창은 그림 내용과 상관없이 갱신할 때마다 화면 합성 부하가 생겨요. 가장 효과가 큰 절약 옵션이에요.",
            "A transparent full-screen window adds compositing load on every refresh, no matter what it draws. This option saves the most.",
        ),
    );
    slider(
        ui,
        L("렌더 해상도", "Render resolution"),
        &mut s.render_scale,
        0.5..=1.0,
        pct,
        Some(L("낮추면 GPU 부담이 줄고 빗줄기가 약간 부드러워져요", "Lower values use less GPU and make streaks a bit softer")),
    );
    ui.checkbox(&mut s.battery_saver, L("배터리·절전 모드일 때 30fps", "30fps on battery or in battery saver"));
    ui.checkbox(&mut s.pause_when_covered, L("전체 화면 앱이 덮고 있으면 그리지 않기", "Pause when a full-screen app covers the screen"));
    section(ui, L("캡처", "Screenshots"));
    ui.checkbox(&mut s.hide_in_captures, L("스크린샷과 화면 녹화에서 비 숨기기", "Hide rain in screenshots and screen recordings"));
    hint(
        ui,
        L(
            "윈도우의 캡처 제외 기능을 써요. 내 화면에서는 그대로 보이고, 캡처한 이미지와 영상에만 빠져요.",
            "Uses the Windows capture exclusion. Rain stays on your screen and is left out of captured images and videos.",
        ),
    );
    section(ui, L("기타", "Other"));
    ui.checkbox(&mut s.launch_at_login, L("로그인 시 자동 실행", "Open at login"));
    ui.horizontal(|ui| {
        ui.label(L("트레이 아이콘", "Tray icon"));
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.selectable_value(&mut s.icon_style, IconStyle::Fluent, "Fluent");
            ui.selectable_value(&mut s.icon_style, IconStyle::FontAwesome, "Font Awesome");
        });
    });
    hint(ui, L("비가 0이고 물이 잠잠해지면 렌더링을 완전히 멈춰요.", "Rendering stops completely when rain is at 0 and the water is still."));
}

// ---------- 도우미 ----------

fn section(ui: &mut egui::Ui, title: &str) {
    ui.add_space(6.0);
    ui.label(RichText::new(title).strong().weak());
}

fn hint(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).small().weak());
}

fn slider(ui: &mut egui::Ui, title: &str, v: &mut f32, range: std::ops::RangeInclusive<f32>, fmt: fn(f32) -> String, hint_text: Option<&str>) {
    ui.horizontal(|ui| {
        ui.label(title);
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.label(RichText::new(fmt(*v)).small().monospace().weak());
        });
    });
    ui.add(egui::Slider::new(v, range).show_value(false));
    if let Some(h) = hint_text {
        hint(ui, h);
    }
}

fn pct(v: f32) -> String {
    format!("{:.0}%", v * 100.0)
}
fn mult(v: f32) -> String {
    format!("×{v:.2}")
}
fn pt(v: f32) -> String {
    format!("{v:.1} pt")
}
fn deg(v: f32) -> String {
    format!("{v:.0}°")
}
fn signed(v: f32) -> String {
    if v == 0.0 {
        "0".into()
    } else if v > 0.0 {
        format!("→ {:.2}", v)
    } else {
        format!("← {:.2}", -v)
    }
}

/// 켜고 끄는 스위치 (egui 데모의 toggle_switch)
fn toggle(ui: &mut egui::Ui, on: &mut bool) -> egui::Response {
    let size = ui.spacing().interact_size.y * egui::vec2(2.0, 1.0);
    let (rect, mut response) = ui.allocate_exact_size(size, egui::Sense::click());
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }
    if ui.is_rect_visible(rect) {
        let how_on = ui.ctx().animate_bool_responsive(response.id, *on);
        let visuals = ui.style().interact_selectable(&response, *on);
        let rect = rect.expand(visuals.expansion);
        let radius = 0.5 * rect.height();
        ui.painter().rect(rect, radius, visuals.bg_fill, visuals.bg_stroke, egui::StrokeKind::Inside);
        let x = egui::lerp((rect.left() + radius)..=(rect.right() - radius), how_on);
        ui.painter().circle(egui::pos2(x, rect.center().y), 0.75 * radius, visuals.bg_fill, visuals.fg_stroke);
    }
    response
}
