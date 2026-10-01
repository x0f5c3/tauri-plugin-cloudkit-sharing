//! Native CloudKit sharing for Tauri 2 on iOS, iPadOS and macOS.
//! Configure containers in Rust or `plugins.cloudkit-sharing` in tauri.conf.json.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tauri::{
    ipc::Channel,
    plugin::{Builder as TauriBuilder, TauriPlugin},
    AppHandle, Manager, Runtime,
};

mod commands;
mod error;
mod models;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod native;
pub use error::{Error, ItemError, Result};
pub use models::*;

/// Trusted host configuration. Asset directories must exist and are canonicalized at setup.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub containers: Vec<String>,
    #[serde(default)]
    pub asset_directories: Vec<PathBuf>,
}
impl Config {
    fn validate(mut self) -> Result<Self> {
        if self.containers.is_empty()
            || self
                .containers
                .iter()
                .any(|s| !s.starts_with("iCloud.") || s.len() <= 7)
        {
            return Err(Error::new(
                "invalidConfiguration",
                "Configure at least one iCloud.* container",
            ));
        }
        self.containers.sort();
        self.containers.dedup();
        for path in &mut self.asset_directories {
            *path = path
                .canonicalize()
                .map_err(|e| Error::new("invalidConfiguration", e.to_string()))?;
            if !path.is_dir() {
                return Err(Error::new(
                    "invalidConfiguration",
                    "Asset paths must be directories",
                ));
            }
        }
        Ok(self)
    }
}

type Subscribers = Arc<Mutex<Vec<(String, Channel<CloudKitEvent>)>>>;
/// Managed plugin state; use `CloudkitSharingExt` to access it from Rust.
pub struct CloudkitSharing<R: Runtime> {
    app: AppHandle<R>,
    config: Config,
    subscribers: Subscribers,
}
impl<R: Runtime> CloudkitSharing<R> {
    async fn request<T: DeserializeOwned>(
        &self,
        command: &str,
        payload: impl Serialize,
    ) -> Result<T> {
        let value = serde_json::to_value(payload).map_err(Error::bridge)?;
        self.check_container(&value)?;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        {
            serde_json::from_value(native::request(command, value).await?).map_err(Error::bridge)
        }
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        {
            let _ = command;
            Err(Error::new(
                "unsupportedPlatform",
                "CloudKit requires iOS, iPadOS, or macOS",
            ))
        }
    }
    fn check_container(&self, value: &serde_json::Value) -> Result<()> {
        if let Some(id) = value.get("containerId").and_then(|v| v.as_str()) {
            if !self.config.containers.iter().any(|allowed| allowed == id) {
                return Err(Error::new(
                    "containerNotAllowed",
                    "Container is not configured by the host",
                ));
            }
        }
        Ok(())
    }
    pub async fn capabilities(&self) -> Result<Capabilities> {
        Ok(Capabilities {
            supported: cfg!(any(target_os = "macos", target_os = "ios")),
            platform: std::env::consts::OS.into(),
            hierarchy_sharing: cfg!(any(target_os = "macos", target_os = "ios")),
            zone_sharing: cfg!(any(target_os = "macos", target_os = "ios")),
            native_sharing_ui: cfg!(any(target_os = "macos", target_os = "ios")),
        })
    }
    pub async fn pending_invitations(&self) -> Result<Vec<Invitation>> {
        self.request("pending_invitations", serde_json::json!({}))
            .await
    }
    /// Subscribe through an IPC channel; sensitive payloads are never broadcast globally.
    pub fn subscribe_events(&self, channel: Channel<CloudKitEvent>) -> Result<String> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let id = NEXT
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            .to_string();
        let mut listeners = self.subscribers.lock().map_err(Error::bridge)?;
        if listeners.len() >= 256 {
            return Err(Error::new(
                "tooManyListeners",
                "Unsubscribe unused event listeners",
            ));
        }
        listeners.push((id.clone(), channel));
        Ok(id)
    }
    pub fn unsubscribe_events(&self, subscription_id: String) -> Result<()> {
        self.subscribers
            .lock()
            .map_err(Error::bridge)?
            .retain(|(id, _)| id != &subscription_id);
        Ok(())
    }
    pub async fn present_sharing_ui(&self, payload: PresentSharingUiRequest) -> Result<()> {
        let mut value = serde_json::to_value(&payload).map_err(Error::bridge)?;
        self.check_container(&value)?;
        let window = match &payload.window_label {
            Some(label) => Some(self.app.get_webview_window(label).ok_or_else(|| {
                Error::new("windowNotFound", "Requested webview window does not exist")
            })?),
            None => self.app.webview_windows().into_values().next(),
        };
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        let _presentation = if let Some(window) = &window {
            let (tx, rx) = tokio::sync::oneshot::channel();
            #[cfg(target_os = "macos")]
            {
                let window = window.clone();
                self.app
                    .run_on_main_thread(move || {
                        let result =
                            window
                                .ns_window()
                                .map_err(Error::bridge)
                                .and_then(|pointer| {
                                    // SAFETY: the native window is borrowed on the main thread and retained synchronously.
                                    unsafe { native::Presentation::register(pointer) }
                                });
                        let _ = tx.send(result);
                    })
                    .map_err(Error::bridge)?;
            }
            #[cfg(target_os = "ios")]
            window
                .with_webview(move |webview| {
                    // SAFETY: with_webview lends a live WKWebView on the main thread.
                    let _ = tx.send(unsafe { native::Presentation::register(webview.inner()) });
                })
                .map_err(Error::bridge)?;
            let handle = rx.await.map_err(Error::bridge)??;
            value["nativePresentation"] = serde_json::Value::String(handle.id().to_string());
            Some(handle)
        } else {
            None
        };
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        let _ = (&mut value, window);
        self.request("present_sharing_ui", value).await
    }
}
macro_rules! methods {
    ($($name:ident($input:ty) -> $output:ty;)*) => { $(
        impl<R: Runtime> CloudkitSharing<R> {
            pub async fn $name(&self, payload: $input) -> Result<$output> {
                self.request(stringify!($name), payload).await
            }
        }
    )* };
}
methods! {
    account_status(ContainerRequest) -> AccountStatus;
    list_zones(DatabaseRequest) -> Vec<ZoneId>;
    create_zone(ZoneRequest) -> ZoneId;
    delete_zone(ZoneRequest) -> ();
    fetch_records(FetchRecordsRequest) -> Vec<Record>;
    modify_records(ModifyRecordsRequest) -> ModifyRecordsResponse;
    query_records(QueryRequest) -> QueryResponse;
    database_changes(DatabaseChangesRequest) -> DatabaseChangesResponse;
    zone_changes(ZoneChangesRequest) -> ZoneChangesResponse;
    create_share(CreateShareRequest) -> Share;
    fetch_share(FetchShareRequest) -> Share;
    update_share(UpdateShareRequest) -> Share;
    set_participant_permission(SetParticipantPermissionRequest) -> Share;
    add_participant(AddParticipantRequest) -> Share;
    remove_participant(ParticipantRequest) -> Share;
    stop_sharing(ShareRequest) -> ();
    leave_share(ShareRequest) -> ();
    fetch_invitation(FetchInvitationRequest) -> Invitation;
    dismiss_invitation(InvitationRequest) -> ();
    accept_invitation(InvitationRequest) -> Share;
}

pub trait CloudkitSharingExt<R: Runtime> {
    fn cloudkit_sharing(&self) -> &CloudkitSharing<R>;
}
impl<R: Runtime, T: Manager<R>> CloudkitSharingExt<R> for T {
    fn cloudkit_sharing(&self) -> &CloudkitSharing<R> {
        self.state::<CloudkitSharing<R>>().inner()
    }
}

#[derive(Default)]
pub struct Builder {
    config: Option<Config>,
}
impl Builder {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn config(mut self, config: Config) -> Self {
        self.config = Some(config);
        self
    }
    pub fn build<R: Runtime>(self) -> TauriPlugin<R, Config> {
        TauriBuilder::<R, Config>::new("cloudkit-sharing")
            .invoke_handler(tauri::generate_handler![
                commands::capabilities,
                commands::account_status,
                commands::list_zones,
                commands::create_zone,
                commands::delete_zone,
                commands::fetch_records,
                commands::modify_records,
                commands::query_records,
                commands::database_changes,
                commands::zone_changes,
                commands::create_share,
                commands::fetch_share,
                commands::update_share,
                commands::set_participant_permission,
                commands::add_participant,
                commands::remove_participant,
                commands::stop_sharing,
                commands::leave_share,
                commands::fetch_invitation,
                commands::pending_invitations,
                commands::dismiss_invitation,
                commands::accept_invitation,
                commands::present_sharing_ui,
                commands::subscribe_events,
                commands::unsubscribe_events,
            ])
            .setup(move |app, api| {
                let config = self
                    .config
                    .unwrap_or_else(|| api.config().clone())
                    .validate()?;
                let subscribers: Subscribers = Arc::default();
                #[cfg(target_os = "ios")]
                {
                    tauri::ios_plugin_binding!(init_plugin_cloudkit_sharing);
                    let _ = api.register_ios_plugin(init_plugin_cloudkit_sharing)?;
                }
                #[cfg(any(target_os = "macos", target_os = "ios"))]
                {
                    let listeners = subscribers.clone();
                    native::initialize(
                        &config,
                        Box::new(move |event| {
                            // Copy listeners before invoking callbacks: Rust consumers may unsubscribe in their callback.
                            let snapshot = listeners.lock().map(|v| v.clone()).unwrap_or_default();
                            let mut failed = Vec::new();
                            for (id, channel) in snapshot {
                                if channel.send(event.clone()).is_err() {
                                    failed.push(id);
                                }
                            }
                            if let Ok(mut listeners) = listeners.lock() {
                                listeners.retain(|(id, _)| !failed.contains(id));
                            }
                        }),
                    )?;
                }
                app.manage(CloudkitSharing {
                    app: app.clone(),
                    config,
                    subscribers,
                });
                Ok(())
            })
            .build()
    }
}
pub fn init<R: Runtime>() -> TauriPlugin<R, Config> {
    Builder::new().build()
}

/// Explicit code generation entrypoint. Normal builds never rewrite source files.
pub fn export_typescript<R: Runtime>(
    path: impl AsRef<std::path::Path>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    bindings_for_export().export(specta_typescript::Typescript::default(), path)?;
    Ok(())
}
fn bindings_for_export() -> tauri_specta::Builder<tauri::test::MockRuntime> {
    tauri_specta::Builder::<tauri::test::MockRuntime>::new()
        .plugin_name("cloudkit-sharing")
        .commands(tauri_specta::collect_commands![
            commands::capabilities::<tauri::test::MockRuntime>,
            commands::account_status::<tauri::test::MockRuntime>,
            commands::list_zones::<tauri::test::MockRuntime>,
            commands::create_zone::<tauri::test::MockRuntime>,
            commands::delete_zone::<tauri::test::MockRuntime>,
            commands::fetch_records::<tauri::test::MockRuntime>,
            commands::modify_records::<tauri::test::MockRuntime>,
            commands::query_records::<tauri::test::MockRuntime>,
            commands::database_changes::<tauri::test::MockRuntime>,
            commands::zone_changes::<tauri::test::MockRuntime>,
            commands::create_share::<tauri::test::MockRuntime>,
            commands::fetch_share::<tauri::test::MockRuntime>,
            commands::update_share::<tauri::test::MockRuntime>,
            commands::set_participant_permission::<tauri::test::MockRuntime>,
            commands::add_participant::<tauri::test::MockRuntime>,
            commands::remove_participant::<tauri::test::MockRuntime>,
            commands::stop_sharing::<tauri::test::MockRuntime>,
            commands::leave_share::<tauri::test::MockRuntime>,
            commands::fetch_invitation::<tauri::test::MockRuntime>,
            commands::pending_invitations::<tauri::test::MockRuntime>,
            commands::dismiss_invitation::<tauri::test::MockRuntime>,
            commands::accept_invitation::<tauri::test::MockRuntime>,
            commands::present_sharing_ui::<tauri::test::MockRuntime>,
            commands::subscribe_events::<tauri::test::MockRuntime>,
            commands::unsubscribe_events::<tauri::test::MockRuntime>,
        ])
        .typ::<CloudKitEvent>()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_empty_and_invalid_containers() {
        assert!(Config::default().validate().is_err());
        assert!(Config {
            containers: vec!["not.icloud".into()],
            asset_directories: vec![]
        }
        .validate()
        .is_err());
    }
    #[test]
    fn integer_and_record_metadata_survive_json() {
        let field = FieldValue::Int64("9223372036854775807".into());
        let value = serde_json::to_value(field).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"type":"int64","value":"9223372036854775807"})
        );
        let _: FieldValue = serde_json::from_value(value).unwrap();
    }
    #[test]
    fn partial_errors_remain_structured() {
        let err: Error = serde_json::from_value(serde_json::json!({"code":"partialFailure","message":"Batch failed", "partialErrors":[{"itemId":"note-2","error":{"code":"permissionFailure","message":"Read only"}}]})).unwrap();
        assert_eq!(err.partial_errors[0].error.code, "permissionFailure");
    }
    #[test]
    #[ignore = "explicit source generation"]
    fn export_bindings() {
        export_typescript::<tauri::test::MockRuntime>("guest-js/bindings.ts").unwrap();
    }
}
