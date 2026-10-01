# Real-project validation

The automated checks prove that the Rust, Swift, TypeScript, package, and example layers fit together. They do not prove that Apple accepts the app’s entitlements or that CloudKit sharing works between real iCloud accounts. Use this checklist before shipping an application that depends on the plugin.

## 1. Configure an Apple-owned test environment

Create a development CloudKit container owned by the same Apple Developer Team as the app. Use a real bundle identifier for every target, enable iCloud/CloudKit for the app ID, and add the container to the app’s entitlements. Keep the example placeholder `iCloud.com.example.cloudkitsharing` out of a real build. Enable `CKSharingSupported` in `Info.plist` and set the minimum OS versions supported by the project (the example uses iOS 15 and macOS 12).

Use a physical iPhone or iPad and a signed macOS build. A simulator build is useful for compile checks, but it is not sufficient evidence for account state, share URLs, native share UI, background invitation delivery, or production entitlements.

## 2. Run local gates before opening Xcode

From the plugin root:

```sh
cargo fmt --all -- --check
cargo check --all-targets
cargo clippy --all-targets -- -D warnings
cargo test --lib
swift test --package-path apple
npm run typecheck
npm test
cargo check --manifest-path examples/tauri-app/src-tauri/Cargo.toml
cd examples/tauri-app && npm run build
```

Regenerate the checked-in TypeScript contract when Rust commands or models change:

```sh
cargo test --lib export_bindings -- --ignored
npm run build
```

## 3. Verify the signed app configuration

Archive or run the app with the same entitlements used for distribution. Inspect the signed product and confirm that the iCloud container, CloudKit services, application identifier, and associated domains (if used by the app’s universal-link flow) are present:

```sh
codesign -d --entitlements :- path/to/Signed.app
```

Confirm that the container identifier in the signed entitlements matches the value passed to `configure`. Verify that the app can report account status and capabilities before testing records.

## 4. One-account functional smoke test

On a signed device logged into iCloud, run this sequence and retain the returned IDs and event log as evidence:

1. Configure the plugin and subscribe to events before performing CloudKit work.
2. Read `account_status` and `capabilities`; record the result.
3. Create a custom private database zone and save a record with a stable record name.
4. Fetch the record, query it, update it using its returned `system_fields`, then delete it.
5. Create a record share and a zone share; fetch each share and update its title/metadata.
6. Present and dismiss the native sharing UI, both with an explicit window label and with the default window selection.
7. Exercise database, zone, and record change subscriptions and verify that the event payload identifies the database, zone, and record involved.

Repeat the sequence after a cold launch and after temporarily disabling network access. Confirm that errors preserve the CloudKit error code, retryability, partial errors, and conflict record data where Apple provides them.

## 5. Two-account sharing test

Use two Apple IDs that can access the development container. The owner should create a share and send its URL through the product’s normal invitation path.

1. Open the URL while the participant app is running and verify `invitationReceived`.
2. Repeat with the participant app terminated; verify the cold-launch callback and `pending_invitations`.
3. Fetch and accept the invitation, then list shared database zones and fetch/query a shared record.
4. Verify read-only and read-write participant permissions with separate shares.
5. Update a shared record from both accounts and verify conflict handling and change events.
6. Remove the participant from the owner account; verify access loss on the participant.
7. Test participant `leave_share`, owner `stop_sharing`, invitation dismissal, and repeated delivery of the same invitation.

Record pass/fail results with device OS, app build, container environment, account roles, and timestamps. Do not call the plugin production-ready until this matrix passes on every platform the app claims to support.

## 6. Failure and release checks

Exercise no iCloud account, restricted account, wrong container, offline mode, invalid cursors/tokens, duplicate subscriptions, malformed record IDs, large asset uploads, symlinked asset paths, batch partial failures, concurrent writers, and relaunch during an invitation or share presentation. Confirm that no secret or raw CloudKit token is written to logs.

Before release, repeat the smoke and two-account tests against the production container with the distribution-signed app. Confirm CloudKit schema deployment, migration/rollback procedures, privacy disclosures, TestFlight installation, and a clean uninstall/reinstall. Keep the development and production container identifiers separate.

The plugin is locally validated when the commands above pass. Live CloudKit acceptance remains an application-owner responsibility because it requires the developer team, signed Apple products, containers, devices, and multiple iCloud accounts.
