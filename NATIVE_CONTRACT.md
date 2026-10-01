# Internal native transport contract

Rust is the public contract source. Native transport uses camelCase JSON dictionaries.
Every command takes `payload`; native replies are `{ "ok": <value> }` or
`{ "error": <PluginError> }`. No native exception may cross FFI.

## Shared Swift interfaces

`CloudKitCore.shared`: singleton, configured with `configure(_ config: [String: Any]) throws`.
Config: `{containers: [String], assetDirectories: [String]}`. Containers must be nonempty;
every command carrying `containerId` is checked. Asset directories are canonical absolute
paths supplied by Rust, never webview arguments. Assets must remain beneath these paths.

`func execute(_ command: String, _ payload: [String: Any]) async throws -> Any` handles
account/data commands and forwards share commands to `CloudKitSharing.shared.execute`.
`func container(_ payload: [String: Any]) throws -> CKContainer` and
`func database(_ payload: [String: Any]) throws -> CKDatabase` validate configuration.
`CloudKitCodec` has static `zoneID(_ value: [String:Any]) throws -> CKRecordZone.ID`,
`recordID(_ value: [String:Any]) throws -> CKRecord.ID`,
`encodeZoneID(_ id: CKRecordZone.ID) -> [String:Any]`,
`encodeRecordID(_ id: CKRecord.ID) -> [String:Any]`,
`encodeRecord(_ record: CKRecord) throws -> [String:Any]`,
`decodeRecord(_ value: [String:Any]) throws -> CKRecord`.
Codec asset access is checked against `CloudKitCore.shared.assetDirectories`.
`NativeError(code: String, message: String)` is Error; `nativeError(_ error: Error) -> [String:Any]`
produces PluginError. `CloudKitCore.shared.emit: (([String:Any]) -> Void)?` delivers events.

`CloudKitSharing.shared` implements `execute`, plus `install()` for lifecycle hooks;
core configure calls install on main queue. Sharing UI and lifecycle code live in
`apple/Sources/CloudKitSharing/Sharing.swift` and `Lifecycle.swift`.
Core/data/codec/errors live in other files in that directory. Shared Swift package:
`apple/Package.swift`, target/module `CloudKitSharing`, macOS 12 / iOS 15.

## Types

ZoneId `{zoneName, ownerName}` (use CKCurrentUserDefaultName for own zones).
RecordId `{recordName, zoneId: ZoneId}`. DatabaseScope is `private|shared`.
Record `{recordId, recordType, fields: {[key]: FieldValue}, parent: RecordId|null,
systemFields: base64|null}`. FieldValue is tagged `{type, value}`:
`string` string, `int64` decimal string, `double` number, `bytes` base64,
`date` seconds since epoch number, `location` `{latitude,longitude}`,
`reference` `{recordId, action: "none"|"deleteSelf"}`, `asset` absolute path,
`list` FieldValue[]. Use `null` fields to remove keys on save.
PluginError `{code, message, nativeCode?: number|null, retryAfterSeconds?: number|null,
partialErrors?: [{itemId:string,error:PluginError}], serverRecord?:Record|null,
clientRecord?:Record|null, ancestorRecord?:Record|null}`.
Share `{recordId, url:string|null, title:string|null, shareType:string|null,
publicPermission:"none"|"readOnly"|"readWrite", participants:Participant[],
currentUserParticipant:Participant|null}`. Participant `{participantId:string,
role:"owner"|"privateUser"|"publicUser"|"unknown", permission:"none"|"readOnly"|"readWrite"|"unknown",
acceptanceStatus:"pending"|"accepted"|"removed"|"unknown", displayName:string|null}`.
Invitation `{id:string, containerId:string, url:string|null, share:Share,
rootRecordId:RecordId|null}`.
Event `{kind:"accountChanged"|"invitationReceived"|"shareAccepted"|"sharingUiClosed"|"sharingUiSaved"|"sharingStopped"|"error",
containerId:string|null, invitation:Invitation|null, share:Share|null, error:PluginError|null}`.
Missing optional output fields deserialize as None; TS generated models use null.

## Commands

- capabilities `{}` -> `{supported:bool, platform:string, hierarchySharing:bool, zoneSharing:bool, nativeSharingUi:bool}`
- account_status `{containerId}` -> `{status:"available"|"noAccount"|"restricted"|"couldNotDetermine"|"temporarilyUnavailable"}`
- list_zones `{containerId,database}` -> ZoneId[]
- create_zone / delete_zone `{containerId,database,zoneId}` -> ZoneId / null
- fetch_records `{containerId,database,recordIds:RecordId[]}` -> Record[] (partial failure rejects structured error)
- modify_records `{containerId,database,records:Record[],deleteIds:RecordId[],savePolicy:"ifServerRecordUnchanged"|"changedKeys"|"allKeys",atomic:bool}` -> `{saved:Record[],deleted:RecordId[]}`
- query_records `{containerId,database,zoneId:ZoneId|null,recordType:string,filters:[{field:string,comparator:"equal"|"notEqual"|"lessThan"|"lessThanOrEqual"|"greaterThan"|"greaterThanOrEqual"|"in"|"contains",value:FieldValue}],sort:[{field:string,ascending:bool}],limit:number,cursor:string|null}` -> `{records:Record[],cursor:string|null}`. Cursors securely archived and bound to container/database/query zone; validate limits 1..200.
- database_changes `{containerId,database,token:string|null,limit:number}` -> `{changed:ZoneId[],deleted:ZoneId[],purged:ZoneId[],token:string|null,moreComing:bool}`
- zone_changes `{containerId,database,zoneId,token:string|null,limit:number}` -> `{records:Record[],deleted:[{recordId,recordType}],token:string|null,moreComing:bool}`
- create_share `{containerId,target:{type:"record",record:Record}|{type:"zone",zoneId:ZoneId},title:string|null,shareType:string|null,thumbnail:base64|null,publicPermission:"none"|"readOnly"|"readWrite"}` -> Share. Root and share saved atomically with unchanged policy.
- fetch_share `{containerId,database,shareId:RecordId}` -> Share
- update_share `{containerId,shareId,title:string|null,shareType:string|null,thumbnail:base64|null,publicPermission:"none"|"readOnly"|"readWrite"}` -> Share. Fetch latest, update fields, optimistic save; null clears metadata.
- set_participant_permission `{containerId,shareId,participantId,permission:"readOnly"|"readWrite"}` -> Share
- remove_participant `{containerId,shareId,participantId}` -> Share
- add_participant `{containerId,shareId,lookup:{type:"email"|"phoneNumber"|"userRecordId",value:string},permission:"readOnly"|"readWrite"}` -> Share
- stop_sharing `{containerId,shareId}` -> null (owner, private database)
- leave_share `{containerId,shareId}` -> null (participant, shared database)
- fetch_invitation `{containerId,url}` -> Invitation (add to pending inbox)
- pending_invitations `{}` -> Invitation[]
- dismiss_invitation `{invitationId}` -> null
- accept_invitation `{invitationId}` -> Share (remove pending only after success, emit shareAccepted)
- present_sharing_ui `{containerId,database,shareId,windowLabel:string|null,anchor:{x:number,y:number,width:number,height:number}|null}` -> null once presented. Emit subsequent delegate events.

Pending metadata secure-archived to Application Support with protection; deduplicate by
container + share ID, keep until explicit dismissal/acceptance. Only configured containers
are visible or accepted. Recover pre-configuration callbacks after configuration.

## FFI / iOS adapter ownership (parent implementation)

Parent owns `Bridge.swift`, `ios/`, Rust, TS, manifests/build config and example.
macOS C exports take command JSON bytes and request id; callbacks copy response synchronously.
Parent routes core emit to Tauri `cloudkit-sharing://event`. iOS adapter forwards execute.
