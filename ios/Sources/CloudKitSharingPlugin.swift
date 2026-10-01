import Tauri
import CloudKitSharing

// Commands use the shared asynchronous C ABI on both Apple platforms. This
// adapter registers the package with Tauri and installs lifecycle forwarding.
final class CloudKitSharingPlugin: Plugin {
    override init() {
        super.init()
        CloudKitSharing.shared.install()
    }
}
@_cdecl("init_plugin_cloudkit_sharing")
func initPlugin() -> Plugin { CloudKitSharingPlugin() }
