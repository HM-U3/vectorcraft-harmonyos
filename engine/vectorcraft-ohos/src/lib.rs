//! VectorCraft 的鸿蒙原生宿主。
//!
//! 没有 WebView：ArkTS 的 `XComponent` 把 surface id 交过来，我们解析成 `OHNativeWindow`，
//! wgpu 通过 GLES/EGL 直接渲染进去。编辑器的 UI 仍是桌面 / Web 构建用的同一份
//! `vectorcraft-ui-egui`，只是由我们自己的循环驱动 `logic` / `ui` 两段，而不是 eframe 的 runner。
//!
//! 与 ArkTS 的分工：这里只做「系统能力代理」——文件选择、保存到用户可见位置、打开外链
//! 都排成请求，由 ArkTS 轮询取走并弹系统界面；结果再通过 `open_file` / `place_file` 送回来。

mod ndk;

macro_rules! logi {
    ($($arg:tt)*) => { crate::ndk::log(crate::ndk::LOG_INFO, &format!($($arg)*)) };
}
macro_rules! loge {
    ($($arg:tt)*) => { crate::ndk::log(crate::ndk::LOG_ERROR, &format!($($arg)*)) };
}

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use egui::{Context, Pos2, RawInput, Rect, Vec2};
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::Buffer;
use raw_window_handle::{OhosDisplayHandle, OhosNdkWindowHandle, RawDisplayHandle, RawWindowHandle};
use vectorcraft_engine::Session as EngineSession;
use vectorcraft_ui_egui::place::{PlaceArrival, PlaceInbox};
use vectorcraft_ui_egui::{Services, VectorcraftApp, i18n};

/// Files handed to the editor by ArkTS (system picker results); `VectorcraftApp::logic`
/// drains them through `Services::inbox`.
type Inbox = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

enum Cmd {
    Resize { width: u32, height: u32, dpi: f32 },
    Stop,
}

struct Session {
    tx: Sender<Cmd>,
    join: std::thread::JoinHandle<()>,
}

static SESSION: OnceLock<Mutex<Option<Session>>> = OnceLock::new();

fn session() -> &'static Mutex<Option<Session>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

/// App sandbox directory (`UIAbilityContext.filesDir`), set from ArkTS before `start`.
static DATA_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

static INBOX: OnceLock<Inbox> = OnceLock::new();

fn inbox() -> &'static Inbox {
    INBOX.get_or_init(|| Arc::new(Mutex::new(Vec::new())))
}

static PLACE_INBOX: OnceLock<PlaceInbox> = OnceLock::new();

fn place_inbox() -> &'static PlaceInbox {
    PLACE_INBOX.get_or_init(PlaceInbox::default)
}

/// Platform requests only ArkTS can fulfil (system pickers, opening links).
///
/// A poll queue rather than a callback: `Services`' hooks are plain synchronous closures, and
/// blocking the render thread on a modal dialog would freeze the UI while the user browses files.
static REQUESTS: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn request(cmd: String) {
    logi!("[vectorcraft-ohos] request {cmd}");
    REQUESTS.lock().unwrap().push(cmd);
}

/// Drains pending platform requests (called from ArkTS on a short interval).
#[napi]
pub fn take_requests() -> Vec<String> {
    std::mem::take(&mut *REQUESTS.lock().unwrap())
}

/// Tells the native side where it may keep exports (the app sandbox).
#[napi]
pub fn set_data_dir(dir: String) {
    logi!("[vectorcraft-ohos] data dir {dir}");
    *DATA_DIR.lock().unwrap() = Some(PathBuf::from(dir));
}

/// Queues a file (from the ArkTS system picker) for the editor to open.
#[napi]
pub fn open_file(name: String, data: Buffer) -> bool {
    logi!("[vectorcraft-ohos] open_file {name} ({} bytes)", data.len());
    inbox().lock().unwrap().push((name, data.to_vec()));
    true
}

/// Queues a file picked for File › Place… (it lands on the canvas instead of opening).
#[napi]
pub fn place_file(name: String, data: Buffer) -> bool {
    logi!("[vectorcraft-ohos] place_file {name} ({} bytes)", data.len());
    place_inbox().lock().unwrap().push(PlaceArrival { name, bytes: data.to_vec(), drop: None });
    true
}

/// Starts (or restarts) native rendering into an `XComponent` surface.
#[napi]
pub fn start(surface_id: f64, width: f64, height: f64, dpi: f64, locale: Option<String>) -> bool {
    stop();

    if let Some(tag) = locale.as_deref().filter(|t| !t.is_empty()) {
        // 系统语言：ArkTS 把设备语言传过来，界面按它选词条（中文设备即简体中文）。
        i18n::set_system_locales(&[tag]);
        logi!("[vectorcraft-ohos] system locale {tag}");
    }

    let surface_id = surface_id as u64;
    let width = width.max(1.0) as u32;
    let height = height.max(1.0) as u32;
    let dpi = if dpi > 0.1 { dpi as f32 } else { 1.0 };

    let (tx, rx) = channel();
    let spawned = std::thread::Builder::new().name("vectorcraft-render".to_owned()).spawn(move || run(surface_id, width, height, dpi, rx));

    match spawned {
        Ok(join) => {
            *session().lock().unwrap() = Some(Session { tx, join });
            true
        }
        Err(err) => {
            logi!("[vectorcraft-ohos] spawn failed: {err}");
            false
        }
    }
}

/// Stops rendering and joins the render thread.
#[napi]
pub fn stop() {
    let taken = session().lock().unwrap().take();
    if let Some(s) = taken {
        let _ = s.tx.send(Cmd::Stop);
        let _ = s.join.join();
    }
}

/// Tells the renderer that the surface changed size.
#[napi]
pub fn resize(width: f64, height: f64, dpi: f64) {
    if let Some(s) = session().lock().unwrap().as_ref() {
        let _ = s.tx.send(Cmd::Resize {
            width: width.max(1.0) as u32,
            height: height.max(1.0) as u32,
            dpi: if dpi > 0.1 { dpi as f32 } else { 1.0 },
        });
    }
}

#[napi]
pub fn is_running() -> bool {
    session().lock().unwrap().is_some()
}

/// Touch input from the ArkTS `XComponent` (`onTouch`), in logical points relative to it.
/// `phase`: 0 = down, 1 = move, 2 = up, 3 = cancel.
#[napi]
pub fn touch(phase: i32, x: f64, y: f64) {
    let kind = match phase {
        0 => TouchKind::Down,
        1 => TouchKind::Move,
        2 => TouchKind::Up,
        _ => TouchKind::Cancel,
    };
    input().lock().unwrap().push(InputEvent::Touch { kind, pos: egui::pos2(x as f32, y as f32) });
}

/// Mouse / stylus (`onMouse`). `phase`: 0 = press, 1 = move, 2 = release, 3 = cancel.
/// `button`: 0 = primary, 1 = secondary, 2 = middle.
#[napi]
pub fn mouse(phase: i32, button: i32, x: f64, y: f64) {
    let kind = match phase {
        0 => TouchKind::Down,
        1 => TouchKind::Move,
        2 => TouchKind::Up,
        _ => TouchKind::Cancel,
    };
    let button = match button {
        1 => egui::PointerButton::Secondary,
        2 => egui::PointerButton::Middle,
        _ => egui::PointerButton::Primary,
    };
    input().lock().unwrap().push(InputEvent::Mouse { kind, button, pos: egui::pos2(x as f32, y as f32) });
}

/// Wheel / trackpad scroll (points).
#[napi]
pub fn wheel(dx: f64, dy: f64, ctrl: bool, shift: bool, alt: bool) {
    let modifiers = egui::Modifiers { ctrl, shift, alt, ..Default::default() };
    input().lock().unwrap().push(InputEvent::Wheel { delta: egui::vec2(dx as f32, dy as f32), modifiers });
}

/// Keyboard. `phase`: 0 = down, 1 = up. `text` is the characters the key produced, if any.
#[napi]
pub fn key(phase: i32, code: i32, ctrl: bool, shift: bool, alt: bool, text: String) {
    let modifiers = egui::Modifiers { ctrl, shift, alt, ..Default::default() };
    if let Some(k) = map_key(code) {
        input().lock().unwrap().push(InputEvent::Key { key: k, pressed: phase == 0, modifiers });
    }
    if !text.is_empty() && !ctrl && !alt {
        input().lock().unwrap().push(InputEvent::Text(text));
    }
}

/// HarmonyOS `KeyCode` (18+) → egui key. Modifiers are carried separately.
fn map_key(code: i32) -> Option<egui::Key> {
    use egui::Key;
    Some(match code {
        2012 => Key::ArrowUp,
        2013 => Key::ArrowDown,
        2014 => Key::ArrowLeft,
        2015 => Key::ArrowRight,
        2049 => Key::Tab,
        2050 => Key::Space,
        2054 => Key::Enter,
        2055 => Key::Backspace,
        2070 => Key::Escape,
        2071 => Key::Delete,
        2062 => Key::Home,
        2063 => Key::End,
        2064 => Key::PageUp,
        2065 => Key::PageDown,
        // KEYCODE_0 .. KEYCODE_9
        c @ 2000..=2009 => [
            Key::Num0,
            Key::Num1,
            Key::Num2,
            Key::Num3,
            Key::Num4,
            Key::Num5,
            Key::Num6,
            Key::Num7,
            Key::Num8,
            Key::Num9,
        ][(c - 2000) as usize],
        // KEYCODE_A .. KEYCODE_Z
        c @ 2017..=2042 => [
            Key::A,
            Key::B,
            Key::C,
            Key::D,
            Key::E,
            Key::F,
            Key::G,
            Key::H,
            Key::I,
            Key::J,
            Key::K,
            Key::L,
            Key::M,
            Key::N,
            Key::O,
            Key::P,
            Key::Q,
            Key::R,
            Key::S,
            Key::T,
            Key::U,
            Key::V,
            Key::W,
            Key::X,
            Key::Y,
            Key::Z,
        ][(c - 2017) as usize],
        _ => return None,
    })
}

/// Committed text from the system IME (the hidden ArkTS `TextInput` proxy).
#[napi]
pub fn ime_text(text: String) {
    if text.is_empty() {
        return;
    }
    input().lock().unwrap().push(InputEvent::Text(text));
}

/// Backspaces from the IME (its own delete key never reaches `onKeyEvent`).
#[napi]
pub fn ime_backspace(count: i32) {
    let mut q = input().lock().unwrap();
    for _ in 0..count.max(0) {
        q.push(InputEvent::Key { key: egui::Key::Backspace, pressed: true, modifiers: egui::Modifiers::default() });
        q.push(InputEvent::Key { key: egui::Key::Backspace, pressed: false, modifiers: egui::Modifiers::default() });
    }
}

/// Whether the editor wants the system keyboard right now (ArkTS shows / hides its hidden input).
#[napi]
pub fn wants_text_input() -> bool {
    *WANTS_TEXT.lock().unwrap()
}

static WANTS_TEXT: Mutex<bool> = Mutex::new(false);

#[derive(Clone, Copy)]
enum TouchKind {
    Down,
    Move,
    Up,
    Cancel,
}

enum InputEvent {
    Touch { kind: TouchKind, pos: Pos2 },
    Mouse { kind: TouchKind, button: egui::PointerButton, pos: Pos2 },
    Wheel { delta: Vec2, modifiers: egui::Modifiers },
    Key { key: egui::Key, pressed: bool, modifiers: egui::Modifiers },
    Text(String),
}

static INPUT: OnceLock<Mutex<Vec<InputEvent>>> = OnceLock::new();

fn input() -> &'static Mutex<Vec<InputEvent>> {
    INPUT.get_or_init(|| Mutex::new(Vec::new()))
}

/// Platform services the editor needs: the system pickers, sandbox writes and link opening.
///
/// Save / export has no desktop dialog here: the bytes land in `<sandbox>/exports/` and ArkTS
/// offers a user-visible location afterwards (and remembers it for later saves).
fn build_services() -> Services {
    let dir = DATA_DIR.lock().unwrap().clone();
    Services {
        open_async: Some(Box::new(|| request("pickOpen".to_owned()))),
        place_async: Some(Box::new(|| request("pickPlace".to_owned()))),
        inbox: Some(inbox().clone()),
        place_inbox: Some(place_inbox().clone()),
        download: Some(Box::new(move |name: &str, bytes: &[u8]| write_export(dir.as_deref(), name, bytes))),
        open_url: Some(Box::new(|url: &str| request(format!("openUrl:{url}")))),
        ..Default::default()
    }
}

/// Writes an export into `<sandbox>/exports/` and asks ArkTS to copy it where the user wants it.
fn write_export(base: Option<&Path>, path: &str, bytes: &[u8]) -> Result<(), String> {
    let base = base.map(Path::to_path_buf).unwrap_or_else(std::env::temp_dir);
    let out = base.join("exports");
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    let name = Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "export.svg".to_owned());
    let target = out.join(&name);
    std::fs::write(&target, bytes).map_err(|e| e.to_string())?;
    logi!("[vectorcraft-ohos] wrote {}", target.display());
    request(format!("saveAs:{name}"));
    Ok(())
}

/// 把一个按下/移动/抬起翻成 egui 的指针事件。触摸固定走主键，鼠标带上真实按键
/// （右键要能弹出引擎自己的上下文菜单）。
fn pointer(events: &mut Vec<egui::Event>, kind: TouchKind, button: egui::PointerButton, pos: Pos2) {
    match kind {
        TouchKind::Down => {
            events.push(egui::Event::PointerMoved(pos));
            events.push(egui::Event::PointerButton { pos, button, pressed: true, modifiers: egui::Modifiers::default() });
        }
        TouchKind::Move => events.push(egui::Event::PointerMoved(pos)),
        TouchKind::Up => {
            events.push(egui::Event::PointerButton { pos, button, pressed: false, modifiers: egui::Modifiers::default() });
        }
        TouchKind::Cancel => events.push(egui::Event::PointerGone),
    }
}

fn run(surface_id: u64, mut width: u32, mut height: u32, mut dpi: f32, rx: Receiver<Cmd>) {
    let window = ndk::create_native_window(surface_id);
    if window.is_null() {
        loge!("[vectorcraft-ohos] no native window for surface {surface_id}");
        return;
    }
    let Some(handle) = core::ptr::NonNull::new(window).map(OhosNdkWindowHandle::new) else {
        return;
    };

    let instance =
        wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::GL, ..wgpu::InstanceDescriptor::new_without_display_handle() });

    let surface = match unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(RawDisplayHandle::Ohos(OhosDisplayHandle::new())),
            raw_window_handle: RawWindowHandle::OhosNdk(handle),
        })
    } {
        Ok(surface) => surface,
        Err(err) => {
            loge!("[vectorcraft-ohos] create_surface failed: {err}");
            return;
        }
    };

    let adapter = match pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: Some(&surface),
        apply_limit_buckets: false,
    })) {
        Ok(adapter) => adapter,
        Err(err) => {
            loge!("[vectorcraft-ohos] no adapter: {err}");
            return;
        }
    };
    let info = adapter.get_info();
    logi!("[vectorcraft-ohos] adapter '{}' backend {:?}", info.name, info.backend);

    let (device, queue) = match pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("vectorcraft-ohos"),
        required_features: wgpu::Features::empty(),
        required_limits: adapter.limits(),
        experimental_features: wgpu::ExperimentalFeatures::disabled(),
        memory_hints: wgpu::MemoryHints::default(),
        trace: wgpu::Trace::Off,
    })) {
        Ok(pair) => pair,
        Err(err) => {
            loge!("[vectorcraft-ohos] request_device failed: {err}");
            return;
        }
    };

    let caps = surface.get_capabilities(&adapter);
    if caps.formats.is_empty() {
        loge!("[vectorcraft-ohos] surface reported no formats");
        return;
    }
    let format = caps.formats[0];
    let alpha_mode = caps.alpha_modes.first().copied().unwrap_or(wgpu::CompositeAlphaMode::Auto);
    let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Fifo) { wgpu::PresentMode::Fifo } else { caps.present_modes[0] };
    let mut config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        color_space: wgpu::SurfaceColorSpace::Auto,
        width,
        height,
        present_mode,
        alpha_mode,
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &config);

    let ctx = Context::default();
    let mut app = VectorcraftApp::new(EngineSession::new(), build_services());
    logi!("[vectorcraft-ohos] surface {}x{} @{dpi:.2}x, {format:?}, present {present_mode:?}", width, height);

    let renderer = Arc::new(egui::mutex::RwLock::new(egui_wgpu::Renderer::new(&device, format, egui_wgpu::RendererOptions::default())));

    let mut frames: u64 = 0;
    let mut skipped: u64 = 0;

    'render: loop {
        loop {
            match rx.try_recv() {
                Ok(Cmd::Stop) => break 'render,
                Ok(Cmd::Resize { width: w, height: h, dpi: d }) => {
                    width = w;
                    height = h;
                    dpi = d;
                    config.width = w;
                    config.height = h;
                    surface.configure(&device, &config);
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break 'render,
            }
        }

        let mut events: Vec<egui::Event> = Vec::new();
        for ev in input().lock().unwrap().drain(..) {
            match ev {
                InputEvent::Touch { kind, pos } => pointer(&mut events, kind, egui::PointerButton::Primary, pos),
                InputEvent::Mouse { kind, button, pos } => pointer(&mut events, kind, button, pos),
                InputEvent::Wheel { delta, modifiers } => events.push(egui::Event::MouseWheel {
                    unit: egui::MouseWheelUnit::Point,
                    delta,
                    phase: egui::TouchPhase::Move,
                    modifiers,
                }),
                InputEvent::Key { key, pressed, modifiers } => {
                    events.push(egui::Event::Key { key, physical_key: None, pressed, repeat: false, modifiers })
                }
                InputEvent::Text(text) => events.push(egui::Event::Text(text)),
            }
        }

        let mut raw_input = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, Vec2::new(width as f32 / dpi, height as f32 / dpi))),
            events,
            ..Default::default()
        };
        // egui reads the density from the root viewport's info; setting it only through
        // `Context::set_pixels_per_point` is overwritten on the next pass.
        raw_input
            .viewports
            .insert(egui::ViewportId::ROOT, egui::ViewportInfo { native_pixels_per_point: Some(dpi), ..Default::default() });
        app.raw_input_hook(&mut raw_input);

        let frame_ctx = ctx.clone();
        let output = ctx.run_ui(raw_input, |ui| {
            app.logic(&frame_ctx);
            app.ui(ui);
        });

        // 两类文字输入都要唤起系统输入法：
        // 1. egui 自己的输入控件（各种对话框里的单行/多行框）—— egui 有控件焦点即成立；
        // 2. 文字工具在画布上的就地输入 —— 那是引擎自己的插入符，egui 没有任何控件持有焦点，
        //    只看 `egui_wants_keyboard_input()` 会永远拿到 false（这正是「呼不出虚拟键盘」的原因）。
        *WANTS_TEXT.lock().unwrap() = ctx.egui_wants_keyboard_input() || app.session.tool_wants_text();

        let jobs = ctx.tessellate(output.shapes, output.pixels_per_point);

        // Font atlas and image textures arrive as deltas; without this the glyph meshes sample an
        // empty atlas and every label renders invisible.
        let mut ui_renderer = renderer.write();
        for (id, deltas) in &output.textures_delta.set {
            for delta in deltas {
                ui_renderer.update_texture(&device, &queue, *id, delta);
            }
        }
        for id in &output.textures_delta.free {
            ui_renderer.free_texture(id);
        }

        let screen = egui_wgpu::ScreenDescriptor { size_in_pixels: [width, height], pixels_per_point: output.pixels_per_point };
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("vectorcraft-ohos") });
        let staged = ui_renderer.update_buffers(&device, &queue, &mut encoder, &jobs, &screen);

        let frame = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame) | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                skipped += 1;
                if skipped % 60 == 1 {
                    logi!("[vectorcraft-ohos] surface not ready (timeout/occluded) x{skipped}");
                }
                std::thread::sleep(Duration::from_millis(4));
                continue;
            }
            wgpu::CurrentSurfaceTexture::Outdated => {
                logi!("[vectorcraft-ohos] surface outdated, reconfiguring");
                surface.configure(&device, &config);
                continue;
            }
            wgpu::CurrentSurfaceTexture::Lost | wgpu::CurrentSurfaceTexture::Validation => {
                loge!("[vectorcraft-ohos] surface lost/invalid, stopping");
                break;
            }
        };

        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        {
            let mut pass = encoder
                .begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("egui"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.05, g: 0.06, b: 0.09, a: 1.0 }),
                            store: wgpu::StoreOp::Store,
                        },
                        depth_slice: None,
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                    multiview_mask: None,
                })
                .forget_lifetime();
            ui_renderer.render(&mut pass, &jobs, &screen);
        }

        queue.submit(staged.into_iter().chain(std::iter::once(encoder.finish())));
        queue.present(frame);

        frames += 1;
        if frames % 120 == 0 {
            logi!("[vectorcraft-ohos] presented {frames} frames (skipped {skipped}), primitives {}", jobs.len());
        }
        std::thread::sleep(Duration::from_millis(16));
    }

    logi!("[vectorcraft-ohos] render loop stopped after {frames} frames");
}
