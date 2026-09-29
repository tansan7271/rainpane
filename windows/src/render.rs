// Direct3D 11 + DirectComposition. 모니터마다 클릭이 통과하는 투명 창 하나에 그린다.

use std::ffi::c_void;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::Fxc::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::DirectComposition::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{Interface, PCSTR, Result, w};

use crate::scene::Scene;
use crate::tracker::Monitor;
use crate::water::Snapshot;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Uniforms {
    pub screen: [f32; 4],
    pub time_info: [f32; 4],
    pub rain: [f32; 4],
    pub rain2: [f32; 4],
    pub rain_color: [f32; 4],
    pub light: [f32; 4],
    pub water: [f32; 4],
    pub counts: [f32; 4],
    pub glass: [f32; 4],
}

const SHADERS: &str = include_str!("shaders.hlsl");

struct Stage {
    vs: ID3D11VertexShader,
    ps: ID3D11PixelShader,
}

pub struct Gpu {
    device: ID3D11Device,
    ctx: ID3D11DeviceContext,
    factory: IDXGIFactory2,
    dcomp: IDCompositionDevice,
    cb: ID3D11Buffer,
    blend: ID3D11BlendState,
    raster: ID3D11RasterizerState,
    mask: Stage,
    rain: Stage,
    splash: Stage,
    drop: Stage,
    pool: Stage,
    rivulet: Stage,
    curtain: Stage,
    press: Stage,
    press_shadow: Stage,
    press_glass: Stage,
    sampler: ID3D11SamplerState,
    dxgi_adapter: IDXGIAdapter,
    pub adapter: String,
}

fn compile(entry: &str, target: &str) -> Result<Vec<u8>> {
    let entry = std::ffi::CString::new(entry).unwrap();
    let target = std::ffi::CString::new(target).unwrap();
    let mut code = None;
    let mut err = None;
    let r = unsafe {
        D3DCompile(
            SHADERS.as_ptr() as *const c_void,
            SHADERS.len(),
            PCSTR::null(),
            None,
            None,
            PCSTR(entry.as_ptr() as *const u8),
            PCSTR(target.as_ptr() as *const u8),
            D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &mut code,
            Some(&mut err),
        )
    };
    if let Err(e) = r {
        if let Some(err) = err {
            let msg = unsafe { std::slice::from_raw_parts(err.GetBufferPointer() as *const u8, err.GetBufferSize()) };
            crate::log(&format!("shader {:?}: {}", entry, String::from_utf8_lossy(msg)));
        }
        return Err(e);
    }
    let code = code.unwrap();
    Ok(unsafe { std::slice::from_raw_parts(code.GetBufferPointer() as *const u8, code.GetBufferSize()) }.to_vec())
}

impl Gpu {
    pub fn new() -> Result<Gpu> {
        unsafe {
            let mut device = None;
            let mut ctx = None;
            let levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0];
            let flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
            let hw = D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, HMODULE::default(), flags, Some(&levels), D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx));
            if hw.is_err() {
                crate::log(&format!("hardware device failed: {:?}, using WARP", hw));
                D3D11CreateDevice(None, D3D_DRIVER_TYPE_WARP, HMODULE::default(), flags, Some(&levels), D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx))?;
            }
            let device: ID3D11Device = device.unwrap();
            let ctx = ctx.unwrap();
            let dxgi: IDXGIDevice = device.cast()?;
            let adapter = dxgi.GetAdapter()?;
            let desc = adapter.GetDesc()?;
            let name = String::from_utf16_lossy(&desc.Description).trim_end_matches('\0').to_string();
            let factory: IDXGIFactory2 = adapter.GetParent()?;
            let dcomp: IDCompositionDevice = DCompositionCreateDevice(&dxgi)?;

            let mut cb = None;
            device.CreateBuffer(
                &D3D11_BUFFER_DESC {
                    ByteWidth: std::mem::size_of::<Uniforms>() as u32,
                    Usage: D3D11_USAGE_DEFAULT,
                    BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                    ..Default::default()
                },
                None,
                Some(&mut cb),
            )?;

            // 프리멀티플라이드 알파 합성
            let mut bd = D3D11_BLEND_DESC::default();
            bd.RenderTarget[0] = D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: true.into(),
                SrcBlend: D3D11_BLEND_ONE,
                DestBlend: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            };
            let mut blend = None;
            device.CreateBlendState(&bd, Some(&mut blend))?;
            let mut raster = None;
            device.CreateRasterizerState(
                &D3D11_RASTERIZER_DESC { FillMode: D3D11_FILL_SOLID, CullMode: D3D11_CULL_NONE, DepthClipEnable: true.into(), ..Default::default() },
                Some(&mut raster),
            )?;

            let stage = |v: &str, p: &str| -> Result<Stage> {
                let vb = compile(v, "vs_5_0")?;
                let pb = compile(p, "ps_5_0")?;
                let mut vs = None;
                let mut ps = None;
                device.CreateVertexShader(&vb, None, Some(&mut vs))?;
                device.CreatePixelShader(&pb, None, Some(&mut ps))?;
                Ok(Stage { vs: vs.unwrap(), ps: ps.unwrap() })
            };
            Ok(Gpu {
                mask: stage("maskVertex", "maskFragment")?,
                rain: stage("rainVertex", "rainFragment")?,
                splash: stage("splashVertex", "dropFragment")?,
                drop: stage("dropVertex", "dropFragment")?,
                pool: stage("poolVertex", "poolFragment")?,
                rivulet: stage("rivuletVertex", "rivuletFragment")?,
                curtain: stage("curtainVertex", "curtainFragment")?,
                press: stage("pressVertex", "pressFragment")?,
                press_shadow: stage("pressVertex", "pressShadowFragment")?,
                press_glass: stage("pressVertex", "pressGlassFragment")?,
                sampler: {
                    let mut sm = None;
                    device.CreateSamplerState(
                        &D3D11_SAMPLER_DESC {
                            Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                            AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                            AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                            AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                            MaxLOD: f32::MAX,
                            ..Default::default()
                        },
                        Some(&mut sm),
                    )?;
                    sm.unwrap()
                },
                dxgi_adapter: adapter.clone(),
                device,
                ctx,
                factory,
                dcomp,
                cb: cb.unwrap(),
                blend: blend.unwrap(),
                raster: raster.unwrap(),
                adapter: name,
            })
        }
    }
}

/// 프레임마다 내용을 바꾸는 구조화 버퍼 (float4 또는 float 배열)
struct Items {
    buf: Option<ID3D11Buffer>,
    srv: Option<ID3D11ShaderResourceView>,
    cap: usize,
}

impl Items {
    fn new() -> Items {
        Items { buf: None, srv: None, cap: 0 }
    }
    fn upload<T: Copy>(&mut self, gpu: &Gpu, data: &[T]) -> Result<()> {
        let stride = std::mem::size_of::<T>();
        let n = data.len().max(1);
        unsafe {
            if n > self.cap {
                let cap = n.next_power_of_two().max(64);
                let mut buf = None;
                gpu.device.CreateBuffer(
                    &D3D11_BUFFER_DESC {
                        ByteWidth: (cap * stride) as u32,
                        Usage: D3D11_USAGE_DYNAMIC,
                        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
                        MiscFlags: D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.0 as u32,
                        StructureByteStride: stride as u32,
                    },
                    None,
                    Some(&mut buf),
                )?;
                let buf = buf.unwrap();
                let sd = D3D11_SHADER_RESOURCE_VIEW_DESC {
                    Format: DXGI_FORMAT_UNKNOWN,
                    ViewDimension: D3D_SRV_DIMENSION_BUFFER,
                    Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 {
                        Buffer: D3D11_BUFFER_SRV {
                            Anonymous1: D3D11_BUFFER_SRV_0 { FirstElement: 0 },
                            Anonymous2: D3D11_BUFFER_SRV_1 { NumElements: cap as u32 },
                        },
                    },
                };
                let mut srv = None;
                gpu.device.CreateShaderResourceView(&buf, Some(&sd), Some(&mut srv))?;
                self.buf = Some(buf);
                self.srv = srv;
                self.cap = cap;
            }
            let buf = self.buf.as_ref().unwrap();
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            gpu.ctx.Map(buf, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut m))?;
            std::ptr::copy_nonoverlapping(data.as_ptr() as *const u8, m.pData as *mut u8, data.len() * stride);
            gpu.ctx.Unmap(buf, 0);
        }
        Ok(())
    }
}

pub struct Overlay {
    pub hwnd: HWND,
    pub monitor: Monitor,
    swap: IDXGISwapChain1,
    rtv: ID3D11RenderTargetView,
    _target: IDCompositionTarget,
    _visual: IDCompositionVisual,
    mask_rtv: ID3D11RenderTargetView,
    mask_srv: ID3D11ShaderResourceView,
    mask_version: u64,
    width: u32,
    height: u32,
    /// 렌더 해상도 배율 (1 = 모니터 해상도)
    pub render_scale: f32,
    rects: Items,
    edges: Items,
    pools: Items,
    heights: Items,
    rivs: Items,
    drops: Items,
    curtains: Items,
    press: Items,
    cleared: bool,
    /// 유리 물방울: 이 모니터 화면 복제와 마지막으로 받은 화면
    dup: Option<IDXGIOutputDuplication>,
    desk_tex: Option<ID3D11Texture2D>,
    desk_srv: Option<ID3D11ShaderResourceView>,
    dup_retry_at: f64,
    /// 화면 복제를 새로 시작해서 다음 프레임은 통째로 복사해야 함
    desk_full: bool,
    /// 받아 오는 데 걸린 시간 (디버그 로그용, 초)
    pub capture_time: f64,
    pub capture_count: u32,
    pub capture_rects: u32,
}

/// 한 프레임에 그릴 것
pub struct Frame<'a> {
    pub scene: &'a Scene,
    pub snap: &'a Snapshot,
    pub press: &'a [[f32; 4]],
    pub press_groups: u32,
    /// 유리 물방울로 그릴지 (화면 복제가 되는 경우만)
    pub press_glass: bool,
    pub rain_count: u32,
    pub splash_count: u32,
}

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_NCHITTEST {
        return LRESULT(HTTRANSPARENT as isize);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

/// 스크린샷과 화면 녹화에서 비 창을 뺀다 (윈도우 10 2004 이상). 내 화면에는 그대로 보인다
fn set_exclude(hwnd: HWND, on: bool) {
    unsafe {
        let _ = SetWindowDisplayAffinity(hwnd, if on { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE });
    }
}

/// 이번 프레임에 바뀐 곳: 옮겨진 곳의 도착 사각형 + 다시 그려진 사각형. 못 받으면 None (통째로 복사)
unsafe fn changed_rects(dup: &IDXGIOutputDuplication, info: &DXGI_OUTDUPL_FRAME_INFO) -> Option<Vec<RECT>> {
    let n = info.TotalMetadataBufferSize as usize;
    if n == 0 {
        return Some(Vec::new());
    }
    let mut out = Vec::new();
    unsafe {
        let mut moves = vec![DXGI_OUTDUPL_MOVE_RECT::default(); n / std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>() + 1];
        let mut got = 0u32;
        dup.GetFrameMoveRects((moves.len() * std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>()) as u32, moves.as_mut_ptr(), &mut got).ok()?;
        for m in &moves[..got as usize / std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>()] {
            out.push(m.DestinationRect);
        }
        let mut dirty = vec![RECT::default(); n / std::mem::size_of::<RECT>() + 1];
        let mut got = 0u32;
        dup.GetFrameDirtyRects((dirty.len() * std::mem::size_of::<RECT>()) as u32, dirty.as_mut_ptr(), &mut got).ok()?;
        out.extend_from_slice(&dirty[..got as usize / std::mem::size_of::<RECT>()]);
    }
    Some(out)
}

impl Gpu {
    /// 이 모니터의 화면 복제 (같은 GPU에 붙은 모니터만)
    fn duplicate(&self, hmon: isize) -> Result<IDXGIOutputDuplication> {
        unsafe {
            let mut i = 0;
            while let Ok(out) = self.dxgi_adapter.EnumOutputs(i) {
                i += 1;
                if out.GetDesc()?.Monitor.0 as isize == hmon {
                    let o1: IDXGIOutput1 = out.cast()?;
                    return o1.DuplicateOutput(&self.device);
                }
            }
        }
        Err(windows::core::Error::from(E_FAIL))
    }
}

pub fn register_class() -> Result<()> {
    unsafe {
        let inst = GetModuleHandleW(None)?;
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(overlay_proc),
            hInstance: inst.into(),
            lpszClassName: w!("RainpaneOverlay"),
            ..Default::default()
        };
        RegisterClassExW(&wc);
    }
    Ok(())
}

impl Overlay {
    pub fn new(gpu: &Gpu, monitor: Monitor, exclude_capture: bool, render_scale: f32) -> Result<Overlay> {
        unsafe {
            let r = monitor.px;
            let (win_w, win_h) = (r.right - r.left, r.bottom - r.top);
            // 렌더 해상도를 낮추면 작게 그려서 합성할 때 늘인다
            let width = ((win_w as f32 * render_scale).round() as u32).max(1);
            let height = ((win_h as f32 * render_scale).round() as u32).max(1);
            let ex = WS_EX_NOREDIRECTIONBITMAP | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            let hwnd = CreateWindowExW(
                ex,
                w!("RainpaneOverlay"),
                w!("Rainpane"),
                WS_POPUP,
                r.left,
                r.top,
                win_w,
                win_h,
                None,
                None,
                Some(GetModuleHandleW(None)?.into()),
                None,
            )?;
            // 레이어드 창은 이걸 불러야 보인다. 클릭은 WS_EX_TRANSPARENT로 통과한다.
            SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA)?;
            set_exclude(hwnd, exclude_capture);

            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Width: width,
                Height: height,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                Scaling: DXGI_SCALING_STRETCH,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
                AlphaMode: DXGI_ALPHA_MODE_PREMULTIPLIED,
                ..Default::default()
            };
            let swap = gpu.factory.CreateSwapChainForComposition(&gpu.device, &desc, None)?;
            let back: ID3D11Texture2D = swap.GetBuffer(0)?;
            let mut rtv = None;
            gpu.device.CreateRenderTargetView(&back, None, Some(&mut rtv))?;

            let target = gpu.dcomp.CreateTargetForHwnd(hwnd, true)?;
            let visual = gpu.dcomp.CreateVisual()?;
            visual.SetContent(&swap)?;
            if render_scale < 0.999 {
                let k = 1.0 / render_scale;
                let m = windows_numerics::Matrix3x2 { M11: win_w as f32 / width as f32, M12: 0.0, M21: 0.0, M22: win_h as f32 / height as f32, M31: 0.0, M32: 0.0 };
                let _ = k;
                visual.SetTransform2(&m)?;
            }
            target.SetRoot(&visual)?;
            gpu.dcomp.Commit()?;

            let td = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_R8G8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                ..Default::default()
            };
            let mut tex = None;
            gpu.device.CreateTexture2D(&td, None, Some(&mut tex))?;
            let tex = tex.unwrap();
            let mut mask_rtv = None;
            let mut mask_srv = None;
            gpu.device.CreateRenderTargetView(&tex, None, Some(&mut mask_rtv))?;
            gpu.device.CreateShaderResourceView(&tex, None, Some(&mut mask_srv))?;

            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            Ok(Overlay {
                hwnd,
                monitor,
                swap,
                rtv: rtv.unwrap(),
                _target: target,
                _visual: visual,
                mask_rtv: mask_rtv.unwrap(),
                mask_srv: mask_srv.unwrap(),
                mask_version: u64::MAX,
                width,
                height,
                render_scale,
                rects: Items::new(),
                edges: Items::new(),
                pools: Items::new(),
                heights: Items::new(),
                rivs: Items::new(),
                drops: Items::new(),
                curtains: Items::new(),
                press: Items::new(),
                cleared: false,
                dup: None,
                desk_tex: None,
                desk_srv: None,
                dup_retry_at: 0.0,
                desk_full: true,
                capture_time: 0.0,
                capture_count: 0,
                capture_rects: 0,
            })
        }
    }

    /// 유리 물방울용: 이 모니터 화면(비 창은 빠짐)을 받아 둔다. 바뀐 게 없으면 지난 화면을 그대로 쓴다
    pub fn capture(&mut self, gpu: &Gpu, now: f64) -> bool {
        unsafe {
            if self.dup.is_none() {
                if now < self.dup_retry_at {
                    return false;
                }
                match gpu.duplicate(self.monitor.hmon) {
                    Ok(d) => {
                        self.dup = Some(d);
                        self.desk_full = true;
                    }
                    Err(e) => {
                        crate::log(&format!("desktop duplication failed: {e:?}"));
                        self.dup_retry_at = now + 3.0;
                        return false;
                    }
                }
            }
            let t0 = std::time::Instant::now();
            let dup = self.dup.as_ref().unwrap();
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut res: Option<IDXGIResource> = None;
            match dup.AcquireNextFrame(0, &mut info, &mut res) {
                Ok(()) => {
                    if let Some(tex) = res.and_then(|r| r.cast::<ID3D11Texture2D>().ok()) {
                        let mut d = D3D11_TEXTURE2D_DESC::default();
                        tex.GetDesc(&mut d);
                        let same = self.desk_tex.as_ref().is_some_and(|t| {
                            let mut o = D3D11_TEXTURE2D_DESC::default();
                            t.GetDesc(&mut o);
                            o.Width == d.Width && o.Height == d.Height && o.Format == d.Format
                        });
                        if !same {
                            self.desk_full = true;
                            let nd = D3D11_TEXTURE2D_DESC {
                                Width: d.Width,
                                Height: d.Height,
                                MipLevels: 1,
                                ArraySize: 1,
                                Format: d.Format,
                                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                                Usage: D3D11_USAGE_DEFAULT,
                                BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                                ..Default::default()
                            };
                            let mut t = None;
                            let mut srv = None;
                            if gpu.device.CreateTexture2D(&nd, None, Some(&mut t)).is_ok() {
                                let t = t.unwrap();
                                let _ = gpu.device.CreateShaderResourceView(&t, None, Some(&mut srv));
                                self.desk_tex = Some(t);
                                self.desk_srv = srv;
                            }
                        }
                        if let Some(t) = &self.desk_tex {
                            // 처음엔 통째로, 그 뒤로는 바뀐 곳(옮겨진 곳 포함)만 복사한다
                            let rects = if self.desk_full { None } else { changed_rects(dup, &info) };
                            match rects {
                                Some(rs) => {
                                    self.capture_rects += rs.len() as u32;
                                    for r in rs {
                                        let b = D3D11_BOX { left: r.left.max(0) as u32, top: r.top.max(0) as u32, front: 0, right: (r.right.max(0) as u32).min(d.Width), bottom: (r.bottom.max(0) as u32).min(d.Height), back: 1 };
                                        if b.right > b.left && b.bottom > b.top {
                                            gpu.ctx.CopySubresourceRegion(t, 0, b.left, b.top, 0, &tex, 0, Some(&b));
                                        }
                                    }
                                }
                                None => {
                                    gpu.ctx.CopyResource(t, &tex);
                                    self.capture_rects += 1000;
                                }
                            }
                            self.desk_full = false;
                        }
                    }
                    let _ = dup.ReleaseFrame();
                }
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {}
                Err(e) => {
                    // 화면 모드 변경, 보안 화면 등: 다시 만든다
                    crate::log(&format!("desktop duplication lost: {e:?}"));
                    self.dup = None;
                    self.dup_retry_at = now + 1.0;
                }
            }
            self.capture_time += t0.elapsed().as_secs_f64();
            self.capture_count += 1;
        }
        self.desk_srv.is_some()
    }

    /// 유리 물방울을 한동안 안 쓰면 화면 복제를 놓는다
    pub fn release_capture(&mut self) {
        self.dup = None;
        self.desk_tex = None;
        self.desk_srv = None;
    }

    pub fn set_exclude_capture(&self, on: bool) {
        set_exclude(self.hwnd, on);
    }

    pub fn destroy(&self) {
        unsafe {
            let _ = DestroyWindow(self.hwnd);
        }
    }

    /// 빈 프레임을 한 번 올려서 화면을 비운다
    pub fn clear(&mut self, gpu: &Gpu) {
        if self.cleared {
            return;
        }
        unsafe {
            gpu.ctx.ClearRenderTargetView(&self.rtv, &[0.0; 4]);
            let _ = self.swap.Present(0, DXGI_PRESENT(0));
        }
        self.cleared = true;
    }

    /// 누른 물방울이 작업 표시줄보다 앞에 보이게 비 창을 항상 위 창들 맨 앞으로 다시 올린다
    pub fn raise(&self) {
        unsafe {
            let _ = SetWindowPos(self.hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    pub fn draw(&mut self, gpu: &Gpu, f: &Frame, index: usize, base: &Uniforms, scale: f32) -> Result<()> {
        self.cleared = false;
        let ctx = &gpu.ctx;
        let snap = f.snap;
        let mut u = *base;
        u.screen = self.monitor.rect;
        u.time_info[1] = scale * self.render_scale;
        u.counts = [(snap.edges.len() / 2) as f32, snap.edge_length, index as f32, crate::settings::CORNER_EXPONENT];
        unsafe {
            ctx.UpdateSubresource(&gpu.cb, 0, None, &u as *const _ as *const c_void, 0, 0);
            ctx.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            ctx.IASetInputLayout(None);
            ctx.RSSetState(&gpu.raster);
            ctx.VSSetConstantBuffers(0, Some(&[Some(gpu.cb.clone())]));
            ctx.PSSetConstantBuffers(0, Some(&[Some(gpu.cb.clone())]));
            ctx.RSSetViewports(Some(&[D3D11_VIEWPORT { TopLeftX: 0.0, TopLeftY: 0.0, Width: self.width as f32, Height: self.height as f32, MinDepth: 0.0, MaxDepth: 1.0 }]));

            // 1) 가려짐 마스크: 창 배치가 바뀌었을 때만
            if self.mask_version != f.scene.version {
                self.mask_version = f.scene.version;
                ctx.PSSetShaderResources(0, Some(&[None]));
                ctx.OMSetRenderTargets(Some(&[Some(self.mask_rtv.clone())]), None);
                ctx.OMSetBlendState(None, None, 0xffff_ffff);
                ctx.ClearRenderTargetView(&self.mask_rtv, &[1.0, 1.0, 1.0, 1.0]);
                let rects = f.scene.screen_rects.get(index).map(|v| v.as_slice()).unwrap_or(&[]);
                let n = rects.len() / 2;
                if n > 0 {
                    self.rects.upload(gpu, rects)?;
                    ctx.VSSetShaderResources(1, Some(&[self.rects.srv.clone()]));
                    ctx.PSSetShaderResources(1, Some(&[self.rects.srv.clone()]));
                    ctx.VSSetShader(&gpu.mask.vs, None);
                    ctx.PSSetShader(&gpu.mask.ps, None);
                    ctx.DrawInstanced(4, n as u32, 0, 0);
                }
            }

            // 2) 본 패스
            ctx.OMSetRenderTargets(Some(&[Some(self.rtv.clone())]), None);
            ctx.OMSetBlendState(&gpu.blend, Some(&[0.0; 4]), 0xffff_ffff);
            ctx.ClearRenderTargetView(&self.rtv, &[0.0; 4]);
            ctx.PSSetShaderResources(0, Some(&[Some(self.mask_srv.clone())]));
            let draw = |stage: &Stage, items: &Items, count: u32| {
                ctx.VSSetShaderResources(1, Some(&[items.srv.clone()]));
                ctx.PSSetShaderResources(1, Some(&[items.srv.clone()]));
                ctx.VSSetShader(&stage.vs, None);
                ctx.PSSetShader(&stage.ps, None);
                ctx.DrawInstanced(4, count, 0, 0);
            };
            if f.rain_count > 0 {
                ctx.VSSetShader(&gpu.rain.vs, None);
                ctx.PSSetShader(&gpu.rain.ps, None);
                ctx.DrawInstanced(4, f.rain_count, 0, 0);
            }
            if !snap.curtains.is_empty() {
                self.curtains.upload(gpu, &snap.curtains)?;
                draw(&gpu.curtain, &self.curtains, (snap.curtains.len() / 3) as u32);
            }
            if !snap.pools.is_empty() {
                self.pools.upload(gpu, &snap.pools)?;
                self.heights.upload(gpu, &snap.heights)?;
                ctx.PSSetShaderResources(2, Some(&[self.heights.srv.clone()]));
                draw(&gpu.pool, &self.pools, (snap.pools.len() / 4) as u32);
            }
            if !snap.rivulets.is_empty() {
                self.rivs.upload(gpu, &snap.rivulets)?;
                draw(&gpu.rivulet, &self.rivs, (snap.rivulets.len() / 4) as u32);
            }
            if !snap.drops.is_empty() {
                self.drops.upload(gpu, &snap.drops)?;
                draw(&gpu.drop, &self.drops, (snap.drops.len() / 2) as u32);
            }
            if f.splash_count > 0 && !snap.edges.is_empty() {
                self.edges.upload(gpu, &snap.edges)?;
                draw(&gpu.splash, &self.edges, f.splash_count * 5);
            }
            // 마우스로 누른 물: 화면 표면의 일이라 가려짐 없이 맨 위에. 그림자를 먼저 깔고 물방울
            if f.press_groups > 0 {
                self.press.upload(gpu, f.press)?;
                draw(&gpu.press_shadow, &self.press, f.press_groups);
                if f.press_glass && self.desk_srv.is_some() {
                    ctx.PSSetShaderResources(3, Some(&[self.desk_srv.clone()]));
                    ctx.PSSetSamplers(0, Some(&[Some(gpu.sampler.clone())]));
                    draw(&gpu.press_glass, &self.press, f.press_groups);
                } else {
                    draw(&gpu.press, &self.press, f.press_groups);
                }
            }
            let _ = self.swap.Present(0, DXGI_PRESENT(0));
        }
        Ok(())
    }
}
