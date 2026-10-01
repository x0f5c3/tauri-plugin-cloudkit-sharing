use crate::{CloudkitSharingExt, *};
use tauri::{ipc::Channel, AppHandle, Runtime};

#[tauri::command]
#[specta::specta]
pub(crate) async fn account_status<R: Runtime>(
    app: AppHandle<R>,
    payload: ContainerRequest,
) -> Result<AccountStatus> {
    app.cloudkit_sharing().account_status(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn list_zones<R: Runtime>(
    app: AppHandle<R>,
    payload: DatabaseRequest,
) -> Result<Vec<ZoneId>> {
    app.cloudkit_sharing().list_zones(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn create_zone<R: Runtime>(
    app: AppHandle<R>,
    payload: ZoneRequest,
) -> Result<ZoneId> {
    app.cloudkit_sharing().create_zone(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn delete_zone<R: Runtime>(app: AppHandle<R>, payload: ZoneRequest) -> Result<()> {
    app.cloudkit_sharing().delete_zone(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn fetch_records<R: Runtime>(
    app: AppHandle<R>,
    payload: FetchRecordsRequest,
) -> Result<Vec<Record>> {
    app.cloudkit_sharing().fetch_records(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn modify_records<R: Runtime>(
    app: AppHandle<R>,
    payload: ModifyRecordsRequest,
) -> Result<ModifyRecordsResponse> {
    app.cloudkit_sharing().modify_records(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn query_records<R: Runtime>(
    app: AppHandle<R>,
    payload: QueryRequest,
) -> Result<QueryResponse> {
    app.cloudkit_sharing().query_records(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn database_changes<R: Runtime>(
    app: AppHandle<R>,
    payload: DatabaseChangesRequest,
) -> Result<DatabaseChangesResponse> {
    app.cloudkit_sharing().database_changes(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn zone_changes<R: Runtime>(
    app: AppHandle<R>,
    payload: ZoneChangesRequest,
) -> Result<ZoneChangesResponse> {
    app.cloudkit_sharing().zone_changes(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn create_share<R: Runtime>(
    app: AppHandle<R>,
    payload: CreateShareRequest,
) -> Result<Share> {
    app.cloudkit_sharing().create_share(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn fetch_share<R: Runtime>(
    app: AppHandle<R>,
    payload: FetchShareRequest,
) -> Result<Share> {
    app.cloudkit_sharing().fetch_share(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn update_share<R: Runtime>(
    app: AppHandle<R>,
    payload: UpdateShareRequest,
) -> Result<Share> {
    app.cloudkit_sharing().update_share(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn set_participant_permission<R: Runtime>(
    app: AppHandle<R>,
    payload: SetParticipantPermissionRequest,
) -> Result<Share> {
    app.cloudkit_sharing()
        .set_participant_permission(payload)
        .await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn add_participant<R: Runtime>(
    app: AppHandle<R>,
    payload: AddParticipantRequest,
) -> Result<Share> {
    app.cloudkit_sharing().add_participant(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn remove_participant<R: Runtime>(
    app: AppHandle<R>,
    payload: ParticipantRequest,
) -> Result<Share> {
    app.cloudkit_sharing().remove_participant(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn stop_sharing<R: Runtime>(
    app: AppHandle<R>,
    payload: ShareRequest,
) -> Result<()> {
    app.cloudkit_sharing().stop_sharing(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn leave_share<R: Runtime>(
    app: AppHandle<R>,
    payload: ShareRequest,
) -> Result<()> {
    app.cloudkit_sharing().leave_share(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn fetch_invitation<R: Runtime>(
    app: AppHandle<R>,
    payload: FetchInvitationRequest,
) -> Result<Invitation> {
    app.cloudkit_sharing().fetch_invitation(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn dismiss_invitation<R: Runtime>(
    app: AppHandle<R>,
    payload: InvitationRequest,
) -> Result<()> {
    app.cloudkit_sharing().dismiss_invitation(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn accept_invitation<R: Runtime>(
    app: AppHandle<R>,
    payload: InvitationRequest,
) -> Result<Share> {
    app.cloudkit_sharing().accept_invitation(payload).await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn capabilities<R: Runtime>(app: AppHandle<R>) -> Result<Capabilities> {
    app.cloudkit_sharing().capabilities().await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn pending_invitations<R: Runtime>(app: AppHandle<R>) -> Result<Vec<Invitation>> {
    app.cloudkit_sharing().pending_invitations().await
}

#[tauri::command]
#[specta::specta]
pub(crate) async fn present_sharing_ui<R: Runtime>(
    app: AppHandle<R>,
    payload: PresentSharingUiRequest,
) -> Result<()> {
    app.cloudkit_sharing().present_sharing_ui(payload).await
}
#[tauri::command]
#[specta::specta]
pub(crate) fn subscribe_events<R: Runtime>(
    app: AppHandle<R>,
    channel: Channel<CloudKitEvent>,
) -> Result<String> {
    app.cloudkit_sharing().subscribe_events(channel)
}
#[tauri::command]
#[specta::specta]
pub(crate) fn unsubscribe_events<R: Runtime>(
    app: AppHandle<R>,
    subscription_id: String,
) -> Result<()> {
    app.cloudkit_sharing().unsubscribe_events(subscription_id)
}
