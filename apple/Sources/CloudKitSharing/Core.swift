import CloudKit
import Foundation

public final class CloudKitCore {
    public static let shared = CloudKitCore()
    private let lock = NSLock()
    private var containers: Set<String> = []
    private var directories: [String] = []
    private var emitter: (([String: Any]) -> Void)?
    private var accountObserver: NSObjectProtocol?
    public var assetDirectories: [String] { lock.lock(); defer { lock.unlock() }; return directories }
    public var emit: (([String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return emitter }
        set { lock.lock(); defer { lock.unlock() }; emitter = newValue }
    }
    public func configure(_ config: [String: Any]) throws {
        guard let ids = config["containers"] as? [String], !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else {
            throw NativeError(code: "invalidConfiguration", message: "At least one iCloud container is required")
        }
        let paths = config["assetDirectories"] as? [String] ?? []
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw NativeError(code: "invalidConfiguration", message: "Asset directories must be absolute") }
        lock.lock()
        containers = Set(ids)
        directories = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in self?.emit?(["kind": "accountChanged"]) }
        }
        lock.unlock()
        DispatchQueue.main.async { CloudKitSharing.shared.install() }
    }
    public func container(_ payload: [String: Any]) throws -> CKContainer {
        let id = try requiredString(payload, "containerId")
        lock.lock(); let allowed = containers.contains(id); lock.unlock()
        guard allowed else { throw NativeError(code: "containerNotAllowed", message: "Container is not configured: \(id)") }
        return CKContainer(identifier: id)
    }
    public func database(_ payload: [String: Any]) throws -> CKDatabase {
        let container = try self.container(payload)
        switch try requiredString(payload, "database") {
        case "private": return container.privateCloudDatabase
        case "shared": return container.sharedCloudDatabase
        default: throw NativeError(code: "invalidArgument", message: "Database must be private or shared")
        }
    }
    public func execute(_ command: String, _ payload: [String: Any]) async throws -> Any {
        switch command {
        case "capabilities":
            #if os(macOS)
            let platform = "macos"
            #else
            let platform = "ios"
            #endif
            return ["supported": true, "platform": platform, "hierarchySharing": true, "zoneSharing": true, "nativeSharingUi": true] as [String: Any]
        case "account_status":
            let status = try await container(payload).accountStatus()
            let name: String
            switch status {
            case .available: name = "available"
            case .noAccount: name = "noAccount"
            case .restricted: name = "restricted"
            case .couldNotDetermine: name = "couldNotDetermine"
            case .temporarilyUnavailable: name = "temporarilyUnavailable"
            @unknown default: name = "couldNotDetermine"
            }
            return ["status": name]
        case "list_zones", "create_zone", "delete_zone", "fetch_records", "modify_records", "query_records", "database_changes", "zone_changes":
            return try await executeData(command, payload)
        default: return try await CloudKitSharing.shared.execute(command, payload)
        }
    }
}
