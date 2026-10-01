# iOS adapter

The iOS/iPadOS package links the shared `CloudKitSharing` Swift core and the
Tauri `Plugin` adapter. It targets iOS 15+, including iPad popover anchoring.

The host application must provide the iCloud/CloudKit entitlement for each
configured container and set `CKSharingSupported` to `true` in its Info.plist.
The plugin forwards application and scene share-acceptance callbacks while
preserving the host delegate implementation. A share is queued in the secure
pending-invitation inbox until the Rust/TypeScript API explicitly accepts or
dismisses it.

The package is copied into a generated Tauri iOS project by `build.rs`; it is
not a standalone CloudKit client and requires a signed Tauri host app for live
CloudKit validation.
