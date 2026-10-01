# tauri-plugin-cloudkit-sharing

Native CloudKit sharing and shared-record access for Tauri 2 on iOS, iPadOS,
and macOS. The plugin provides one Rust/TypeScript API for CloudKit records,
custom zones, hierarchy and whole-zone shares, participant permissions, native
sharing UI, invitations, and paginated change tokens.

## Requirements

- Tauri 2 and an Apple host signed with the iCloud/CloudKit capability.
- iOS/iPadOS 15 or later and macOS 12 or later.
- A developer-owned iCloud container configured in the host app. The example
  uses `iCloud.com.example.cloudkitsharing` as a placeholder and cannot work
  until it is replaced.
- `CKSharingSupported = YES` in the host `Info.plist` so share URLs can launch
  the app and reach its scene/application delegate.

Add the plugin and configure it in `tauri.conf.json`:

```json
{
  "plugins": {
    "cloudkit-sharing": {
      "containers": ["iCloud.example.notes"],
      "assetDirectories": []
    }
  }
}
```

```rust
tauri::Builder::default()
  .plugin(tauri_plugin_cloudkit_sharing::init())
  .run(tauri::generate_context!())?;
```

The plugin validates containers and asset roots at startup. Asset paths passed
in record fields must remain below a configured root; downloaded CloudKit
assets are copied into its `cloudkit-downloads` child directory for the host
to clean up.

## Typed API

Rust models are the source of truth. Run `cargo test --lib export_bindings
-- --ignored` when commands or models change; it regenerates
`guest-js/bindings.ts`. The JavaScript package exports those generated
commands and `unwrap`/`onCloudKitEvent` helpers:

```ts
import { commands, onCloudKitEvent, unwrap } from "tauri-plugin-cloudkit-sharing-api";

const stop = await onCloudKitEvent(event => console.log(event.kind));
const status = unwrap(await commands.accountStatus({ containerId: "iCloud.example.notes" }));
await stop();
```

Command failures retain CloudKit error codes, retry delays, partial item
failures, and server/client/ancestor conflict records. `int64` fields are
decimal strings, and change/query cursors are opaque tokens bound to their
container, database, and zone.

The default permission set exposes only capability and iCloud account checks.
Grant data, invitation, sharing UI, and event commands explicitly in a Tauri
capability file. The generated permission reference under `permissions/` lists
every command.

## Example and validation

`examples/tauri-app` is a shared-notes demonstration covering private/shared
databases, zones, record queries and edits, both sharing models, participant
management, native UI, and pending invitation acceptance. Replace its example
container and entitlements before building.

Local verification consists of Rust unit tests, Swift package tests, and
generated TypeScript type-checking. A real sharing acceptance test still needs
two signed Apple installations using two iCloud accounts and the same
CloudKit environment; simulator/build success does not prove that live
CloudKit operation. Follow [VALIDATION.md](VALIDATION.md) for the complete
device, invitation, failure, and release checklist.
