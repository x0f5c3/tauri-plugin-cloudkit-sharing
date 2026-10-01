const COMMANDS: &[&str] = &[
    "account_status",
    "list_zones",
    "create_zone",
    "delete_zone",
    "fetch_records",
    "modify_records",
    "query_records",
    "database_changes",
    "zone_changes",
    "create_share",
    "fetch_share",
    "update_share",
    "set_participant_permission",
    "add_participant",
    "remove_participant",
    "stop_sharing",
    "leave_share",
    "fetch_invitation",
    "dismiss_invitation",
    "accept_invitation",
    "capabilities",
    "pending_invitations",
    "present_sharing_ui",
    "subscribe_events",
    "unsubscribe_events",
];
fn main() {
    tauri_plugin::Builder::new(COMMANDS).ios_path("ios").build();
    println!("cargo:rerun-if-changed=apple/Sources");
    println!("cargo:rerun-if-changed=apple/Package.swift");
    #[cfg(target_os = "macos")]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        swift_rs::SwiftLinker::new("12.0")
            .with_package("CloudKitSharing", "apple")
            .link();
        for framework in ["CloudKit", "AppKit", "Foundation", "CoreLocation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}
