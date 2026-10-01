//! C ABI ownership: Swift copies input synchronously; callbacks lend UTF-8 only
//! for the duration of the call. Requests carry numeric IDs, never Rust pointers.
use crate::{CloudKitEvent, Config, Error, Result};
use serde_json::Value;
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::Duration,
};
use tokio::sync::oneshot;

type Sender = oneshot::Sender<Result<Value>>;
type EventHandler = Box<dyn Fn(CloudKitEvent) + Send + Sync>;
static PENDING: OnceLock<Mutex<HashMap<u64, Sender>>> = OnceLock::new();
static EVENTS: OnceLock<EventHandler> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
extern "C" {
    fn cloudkit_sharing_initialize(
        config: *const c_char,
        event: extern "C" fn(*const c_char),
    ) -> *mut c_char;
    fn cloudkit_sharing_free(value: *mut c_char);
    fn cloudkit_sharing_register_presentation(value: *mut std::ffi::c_void) -> u64;
    fn cloudkit_sharing_release_presentation(id: u64);
    fn cloudkit_sharing_execute(
        id: u64,
        command: *const c_char,
        payload: *const c_char,
        callback: extern "C" fn(u64, *const c_char),
    );
}
fn pending() -> &'static Mutex<HashMap<u64, Sender>> {
    PENDING.get_or_init(Mutex::default)
}
fn decode(value: Value) -> Result<Value> {
    if let Some(error) = value.get("error") {
        Err(serde_json::from_value(error.clone()).map_err(Error::bridge)?)
    } else {
        value
            .get("ok")
            .cloned()
            .ok_or_else(|| Error::new("bridgeError", "Missing response envelope"))
    }
}
extern "C" fn complete(id: u64, payload: *const c_char) {
    // No panic may unwind through Swift frames.
    let _ = std::panic::catch_unwind(|| {
        let result = if payload.is_null() {
            Err(Error::new("bridgeError", "Null response"))
        } else {
            // SAFETY: Swift lends a NUL-terminated UTF-8 buffer for this callback.
            let bytes = unsafe { CStr::from_ptr(payload) }.to_bytes();
            serde_json::from_slice(bytes)
                .map_err(Error::bridge)
                .and_then(decode)
        };
        if let Ok(mut requests) = pending().lock() {
            if let Some(sender) = requests.remove(&id) {
                let _ = sender.send(result);
            }
        }
    });
}
extern "C" fn event(payload: *const c_char) {
    let _ = std::panic::catch_unwind(|| {
        if payload.is_null() {
            return;
        }
        // SAFETY: borrowed only within this synchronous callback.
        let bytes = unsafe { CStr::from_ptr(payload) }.to_bytes();
        if let (Ok(value), Some(handler)) = (serde_json::from_slice(bytes), EVENTS.get()) {
            handler(value);
        }
    });
}
pub(crate) fn initialize(config: &Config, handler: EventHandler) -> Result<()> {
    EVENTS.set(handler).map_err(|_| {
        Error::new(
            "alreadyInitialized",
            "Only one CloudKit plugin instance is supported per process",
        )
    })?;
    let input =
        CString::new(serde_json::to_vec(config).map_err(Error::bridge)?).map_err(Error::bridge)?;
    // SAFETY: native initialization copies config and retains a static function pointer.
    let output = unsafe { cloudkit_sharing_initialize(input.as_ptr(), event) };
    if output.is_null() {
        return Err(Error::new(
            "bridgeError",
            "Native initialization returned null",
        ));
    }
    // SAFETY: output is a NUL-terminated allocation owned by Swift until the matching free.
    let result = serde_json::from_slice(unsafe { CStr::from_ptr(output) }.to_bytes())
        .map_err(Error::bridge)
        .and_then(decode);
    unsafe { cloudkit_sharing_free(output) };
    result.map(|_| ())
}
struct PendingRequest(u64);
impl Drop for PendingRequest {
    fn drop(&mut self) {
        if let Ok(mut requests) = pending().lock() {
            requests.remove(&self.0);
        }
    }
}
pub(crate) async fn request(command: &str, payload: Value) -> Result<Value> {
    let command = CString::new(command).map_err(Error::bridge)?;
    let payload = CString::new(serde_json::to_vec(&payload).map_err(Error::bridge)?)
        .map_err(Error::bridge)?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = oneshot::channel();
    pending().lock().map_err(Error::bridge)?.insert(id, tx);
    let _guard = PendingRequest(id);
    // SAFETY: buffers outlive this synchronous call. Swift copies them before returning.
    unsafe { cloudkit_sharing_execute(id, command.as_ptr(), payload.as_ptr(), complete) };
    tokio::time::timeout(Duration::from_secs(120), rx)
        .await
        .map_err(|_| {
            Error::new(
                "timeout",
                "CloudKit response timed out; the operation may still complete on the server",
            )
        })?
        .map_err(Error::bridge)?
}
/// A native strong reference registered only on the platform main thread.
pub(crate) struct Presentation(u64);
impl Presentation {
    pub(crate) unsafe fn register(pointer: *mut std::ffi::c_void) -> Result<Self> {
        if pointer.is_null() {
            return Err(Error::new("windowNotFound", "Window has already closed"));
        }
        let id = unsafe { cloudkit_sharing_register_presentation(pointer) };
        if id == 0 {
            Err(Error::new(
                "windowNotFound",
                "Native window cannot be retained",
            ))
        } else {
            Ok(Self(id))
        }
    }
    pub(crate) fn id(&self) -> u64 {
        self.0
    }
}
impl Drop for Presentation {
    fn drop(&mut self) {
        // SAFETY: native registry owns the reference and releases on the main queue.
        unsafe { cloudkit_sharing_release_presentation(self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn decodes_void_and_partial_failure() {
        assert_eq!(decode(serde_json::json!({"ok":null})).unwrap(), Value::Null);
        assert_eq!(
            decode(serde_json::json!({"error":{"code":"permissionFailure","message":"Denied"}}))
                .unwrap_err()
                .code,
            "permissionFailure"
        );
        assert!(decode(serde_json::json!({"value":true})).is_err());
    }
    #[test]
    fn late_callback_after_cancellation_is_safe() {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        pending().lock().unwrap().insert(id, tx);
        drop(PendingRequest(id));
        drop(rx);
        let value = CString::new("{\"ok\":null}").unwrap();
        complete(id, value.as_ptr());
        assert!(!pending().lock().unwrap().contains_key(&id));
    }
}
