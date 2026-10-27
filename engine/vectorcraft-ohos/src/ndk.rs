//! Minimal FFI to the HarmonyOS NDK pieces we need: hilog and the XComponent
//! surface -> `OHNativeWindow` bridge. From there `raw-window-handle` and wgpu
//! take over.

use core::ffi::{c_char, c_void};
use core::ptr;
use std::ffi::CString;

/// Opaque `struct NativeWindow` from `<native_window/external_window.h>`.
#[repr(C)]
pub struct OhNativeWindow {
    _private: [u8; 0],
}

const LOG_APP: i32 = 0;
pub const LOG_INFO: i32 = 4;
pub const LOG_ERROR: i32 = 6;
const LOG_DOMAIN: u32 = 0x3200;

unsafe extern "C" {
    /// `int32_t OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t, OHNativeWindow **)`
    fn OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface_id: u64, window: *mut *mut OhNativeWindow) -> i32;

    /// `int OH_LOG_Print(LogType, LogLevel, unsigned int domain, const char *tag,
    ///                   const char *fmt, ...)`
    fn OH_LOG_Print(log_type: i32, level: i32, domain: u32, tag: *const c_char, fmt: *const c_char, ...) -> i32;
}

/// Write one line to hilog (`hdc shell hilog | grep vectorcraft-ohos`).
///
/// Rust's stdout/stderr do not reach hilog in an ArkTS app, so every diagnostic
/// message has to go through the NDK logger.
pub fn log(level: i32, message: &str) {
    let tag = c"vectorcraft-ohos";
    let fmt = c"%{public}s";
    let Ok(body) = CString::new(message) else {
        return;
    };
    unsafe {
        OH_LOG_Print(LOG_APP, level, LOG_DOMAIN, tag.as_ptr(), fmt.as_ptr(), body.as_ptr());
    }
}

/// Returns the native window for an `XComponent` surface id, or null on failure.
pub fn create_native_window(surface_id: u64) -> *mut c_void {
    let mut window: *mut OhNativeWindow = ptr::null_mut();
    let rc = unsafe { OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface_id, &mut window) };
    if rc != 0 || window.is_null() {
        log(LOG_ERROR, &format!("CreateNativeWindowFromSurfaceId({surface_id}) rc={rc}"));
        ptr::null_mut()
    } else {
        window.cast::<c_void>()
    }
}
