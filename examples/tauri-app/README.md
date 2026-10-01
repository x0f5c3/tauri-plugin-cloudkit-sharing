# CloudKit Shared Notes example

This example exercises the plugin’s private/shared database, custom zones,
record reads and writes, hierarchy and zone sharing, participant management,
native sharing UI, and invitation inbox. Replace the illustrative container in
`src-tauri/tauri.conf.json` and `Entitlements.plist` with a container owned by
your Apple developer account before building.

The page does not create records or shares automatically. Use the controls to
perform those operations after signing into iCloud. Test invitation acceptance
with two signed installations using different iCloud accounts in the same
CloudKit environment.

## Recommended IDE Setup

[VS Code](https://code.visualstudio.com/) + [Svelte](https://marketplace.visualstudio.com/items?itemName=svelte.svelte-vscode) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer).
