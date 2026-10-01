//! Lossless, portable CloudKit contracts. All opaque tokens belong to their originating container.
use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::BTreeMap;

macro_rules! model {
    ($name:ident { $($field:ident: $ty:ty),* $(,)? }) => {
        #[derive(Debug, Clone, Serialize, Deserialize, Type)]
        #[serde(rename_all = "camelCase")]
        pub struct $name { $(pub $field: $ty),* }
    };
}
macro_rules! string_enum {
    ($name:ident { $($variant:ident),* $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
        #[serde(rename_all = "camelCase")]
        pub enum $name { $($variant),* }
    };
}
string_enum!(DatabaseScope { Private, Shared });
string_enum!(Permission {
    None,
    ReadOnly,
    ReadWrite
});
string_enum!(ParticipantPermission {
    None,
    ReadOnly,
    ReadWrite,
    Unknown
});
string_enum!(WritePermission {
    ReadOnly,
    ReadWrite
});
string_enum!(ParticipantRole {
    Owner,
    PrivateUser,
    PublicUser,
    Unknown
});
string_enum!(AcceptanceStatus {
    Pending,
    Accepted,
    Removed,
    Unknown
});
string_enum!(AccountState {
    Available,
    NoAccount,
    Restricted,
    CouldNotDetermine,
    TemporarilyUnavailable
});
string_enum!(SavePolicy {
    IfServerRecordUnchanged,
    ChangedKeys,
    AllKeys
});
string_enum!(ReferenceAction { None, DeleteSelf });
string_enum!(Comparator {
    Equal,
    NotEqual,
    LessThan,
    LessThanOrEqual,
    GreaterThan,
    GreaterThanOrEqual,
    In,
    Contains
});
string_enum!(EventKind {
    AccountChanged,
    InvitationReceived,
    ShareAccepted,
    SharingUiClosed,
    SharingUiSaved,
    SharingStopped,
    Error
});
model!(ZoneId {
    zone_name: String,
    owner_name: String
});
impl ZoneId {
    /// A zone belonging to the signed-in user.
    pub fn owned(zone_name: impl Into<String>) -> Self {
        Self {
            zone_name: zone_name.into(),
            owner_name: "__defaultOwner__".into(),
        }
    }
}
model!(RecordId {
    record_name: String,
    zone_id: ZoneId
});
model!(Location {
    latitude: f64,
    longitude: f64
});
model!(Reference {
    record_id: RecordId,
    action: ReferenceAction
});
/// Integers are decimal strings; bytes are base64; dates are epoch seconds.
/// Asset paths must fall within directories configured by the Rust host.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum FieldValue {
    String(String),
    Int64(String),
    Double(f64),
    Bytes(String),
    Date(f64),
    Location(Location),
    Reference(Reference),
    Asset(String),
    List(Vec<FieldValue>),
}
model!(Record { record_id: RecordId, record_type: String, fields: BTreeMap<String, Option<FieldValue>>, parent: Option<RecordId>, system_fields: Option<String> });
model!(Participant { participant_id: String, role: ParticipantRole, permission: ParticipantPermission, acceptance_status: AcceptanceStatus, display_name: Option<String> });
model!(Share { record_id: RecordId, url: Option<String>, title: Option<String>, share_type: Option<String>, public_permission: Permission, participants: Vec<Participant>, current_user_participant: Option<Participant> });
model!(Invitation { id: String, container_id: String, url: Option<String>, share: Share, root_record_id: Option<RecordId> });
model!(Capabilities {
    supported: bool,
    platform: String,
    hierarchy_sharing: bool,
    zone_sharing: bool,
    native_sharing_ui: bool
});
model!(AccountStatus {
    status: AccountState
});
model!(ContainerRequest {
    container_id: String
});
model!(DatabaseRequest {
    container_id: String,
    database: DatabaseScope
});
model!(ZoneRequest {
    container_id: String,
    database: DatabaseScope,
    zone_id: ZoneId
});
model!(FetchRecordsRequest { container_id: String, database: DatabaseScope, record_ids: Vec<RecordId> });
model!(ModifyRecordsRequest { container_id: String, database: DatabaseScope, records: Vec<Record>, delete_ids: Vec<RecordId>, save_policy: SavePolicy, atomic: bool });
model!(ModifyRecordsResponse { saved: Vec<Record>, deleted: Vec<RecordId> });
model!(QueryFilter {
    field: String,
    comparator: Comparator,
    value: FieldValue
});
model!(QuerySort {
    field: String,
    ascending: bool
});
model!(QueryRequest { container_id: String, database: DatabaseScope, zone_id: Option<ZoneId>, record_type: String, filters: Vec<QueryFilter>, sort: Vec<QuerySort>, limit: u32, cursor: Option<String> });
model!(QueryResponse { records: Vec<Record>, cursor: Option<String> });
model!(DatabaseChangesRequest { container_id: String, database: DatabaseScope, token: Option<String>, limit: u32 });
model!(DatabaseChangesResponse { changed: Vec<ZoneId>, deleted: Vec<ZoneId>, purged: Vec<ZoneId>, token: Option<String>, more_coming: bool });
model!(ZoneChangesRequest { container_id: String, database: DatabaseScope, zone_id: ZoneId, token: Option<String>, limit: u32 });
model!(DeletedRecord {
    record_id: RecordId,
    record_type: String
});
model!(ZoneChangesResponse { records: Vec<Record>, deleted: Vec<DeletedRecord>, token: Option<String>, more_coming: bool });
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ShareTarget {
    Record {
        record: Record,
    },
    Zone {
        #[serde(rename = "zoneId")]
        zone_id: ZoneId,
    },
}
model!(CreateShareRequest { container_id: String, target: ShareTarget, title: Option<String>, share_type: Option<String>, thumbnail: Option<String>, public_permission: Permission });
model!(FetchShareRequest {
    container_id: String,
    database: DatabaseScope,
    share_id: RecordId
});
model!(ShareRequest {
    container_id: String,
    share_id: RecordId
});
model!(UpdateShareRequest { container_id: String, share_id: RecordId, title: Option<String>, share_type: Option<String>, thumbnail: Option<String>, public_permission: Permission });
model!(ParticipantRequest {
    container_id: String,
    share_id: RecordId,
    participant_id: String
});
model!(SetParticipantPermissionRequest {
    container_id: String,
    share_id: RecordId,
    participant_id: String,
    permission: WritePermission
});
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum ParticipantLookup {
    Email(String),
    PhoneNumber(String),
    UserRecordId(String),
}
model!(AddParticipantRequest {
    container_id: String,
    share_id: RecordId,
    lookup: ParticipantLookup,
    permission: WritePermission
});
model!(FetchInvitationRequest {
    container_id: String,
    url: String
});
model!(InvitationRequest {
    invitation_id: String
});
model!(Anchor {
    x: f64,
    y: f64,
    width: f64,
    height: f64
});
model!(PresentSharingUiRequest { container_id: String, database: DatabaseScope, share_id: RecordId, window_label: Option<String>, anchor: Option<Anchor> });
model!(CloudKitEvent { kind: EventKind, container_id: Option<String>, invitation: Option<Invitation>, share: Option<Share>, error: Option<crate::Error> });
