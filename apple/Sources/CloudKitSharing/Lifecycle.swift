import Foundation
import CloudKit
import CryptoKit
import ObjectiveC.runtime
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Secure archives preserve Apple's opaque invitation metadata across cold launches.
final class InvitationInbox {
    static let shared = InvitationInbox()
    private let lock = NSRecursiveLock()
    private var loaded = false
    private var entries: [String: CKShare.Metadata] = [:]
    private var loadError: Error?
    static func identifier(_ metadata: CKShare.Metadata) -> String {
        let id = metadata.share.recordID
        let parts = [metadata.containerIdentifier, id.zoneID.ownerName, id.zoneID.zoneName, id.recordName]
        // A JSON tuple prevents ambiguous concatenations of caller-controlled names.
        let data = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func archiveURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "tauri", isDirectory: true).appendingPathComponent("cloudkit-sharing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder.appendingPathComponent("invitations.archive")
    }
    func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }; loaded = true
        do {
            let url = try archiveURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            let values = unarchiver.decodeObject(of: [NSArray.self, CKShare.Metadata.self], forKey: NSKeyedArchiveRootObjectKey) as? [CKShare.Metadata] ?? []
            for value in values { entries[Self.identifier(value)] = value }
        } catch { loadError = error }
    }
    func all() throws -> [CKShare.Metadata] { load(); lock.lock(); defer { lock.unlock() }; if let loadError { throw loadError }; return entries.sorted { $0.key < $1.key }.map { $0.value } }
    func get(_ id: String) throws -> CKShare.Metadata? { load(); lock.lock(); defer { lock.unlock() }; if let loadError { throw loadError }; return entries[id] }
    @discardableResult func insert(_ metadata: CKShare.Metadata) throws -> Bool {
        load(); lock.lock(); defer { lock.unlock() }
        if let loadError { throw loadError }
        let id = Self.identifier(metadata); let previous = entries[id]; entries[id] = metadata
        do { try persist() } catch { entries[id] = previous; throw error }
        return previous == nil
    }
    func remove(_ id: String) throws {
        load(); lock.lock(); defer { lock.unlock() }
        if let loadError { throw loadError }
        let previous = entries.removeValue(forKey: id)
        do { try persist() } catch { entries[id] = previous; throw error }
    }
    private func persist() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: Array(entries.values), requiringSecureCoding: true)
        let url = try archiveURL()
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resource = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
}

/// Wrap methods on concrete delegate classes without replacing host delegates.
/// Existing implementations are invoked using their original IMP exactly once.
enum SharingLifecycle {
    private static var earlyInstalled = false
    private static var hooked: Set<String> = []
    /// Safe during Objective-C +load: no app singleton access or disk I/O.
    static func installEarly() {
        guard !earlyInstalled else { return }; earlyInstalled = true
        #if os(iOS)
        interceptSetter(UIApplication.self) { object in hookApplicationDelegate(object) }
        interceptSetter(UIScene.self) { object in hookSceneDelegate(object) }
        #elseif os(macOS)
        interceptSetter(NSApplication.self) { object in hookApplicationDelegate(object) }
        #endif
    }
    static func install() {
        if !Thread.isMainThread { DispatchQueue.main.async { install() }; return }
        installEarly()
        #if os(iOS)
        if let delegate = UIApplication.shared.delegate { hookApplicationDelegate(delegate) }
        for scene in UIApplication.shared.connectedScenes { if let delegate = scene.delegate { hookSceneDelegate(delegate) } }
        #elseif os(macOS)
        if let delegate = NSApp.delegate { hookApplicationDelegate(delegate) }
        #endif
    }
    static func interceptSetter(_ cls: AnyClass, callback: @escaping (AnyObject) -> Void) {
        let selector = NSSelectorFromString("setDelegate:")
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, delegate in
            if let delegate { callback(delegate) }
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(original, to: Function.self)(receiver, selector, delegate)
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
    private static func hookApplicationDelegate(_ delegate: AnyObject) {
        let selector = NSSelectorFromString("application:userDidAcceptCloudKitShareWithMetadata:")
        hookMetadata(delegate, selector: selector)
    }
    private static func hookMetadata(_ delegate: AnyObject, selector: Selector) {
        guard let cls = object_getClass(delegate) else { return }
        let key = NSStringFromClass(cls) + NSStringFromSelector(selector)
        guard hooked.insert(key).inserted else { return }
        let original = class_getInstanceMethod(cls, selector).map(method_getImplementation)
        let block: @convention(block) (AnyObject, AnyObject, CKShare.Metadata) -> Void = { receiver, sender, metadata in
            CloudKitSharing.shared.receive(metadata)
            if let original {
                typealias Function = @convention(c) (AnyObject, Selector, AnyObject, CKShare.Metadata) -> Void
                unsafeBitCast(original, to: Function.self)(receiver, selector, sender, metadata)
            }
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "v@:@@")
    }
    #if os(iOS)
    private static func hookSceneDelegate(_ delegate: AnyObject) {
        hookMetadata(delegate, selector: NSSelectorFromString("windowScene:userDidAcceptCloudKitShareWithMetadata:"))
        guard let cls = object_getClass(delegate) else { return }
        let selector = NSSelectorFromString("scene:willConnectToSession:options:")
        let key = NSStringFromClass(cls) + NSStringFromSelector(selector)
        guard hooked.insert(key).inserted else { return }
        let original = class_getInstanceMethod(cls, selector).map(method_getImplementation)
        let block: @convention(block) (AnyObject, UIScene, UISceneSession, UIScene.ConnectionOptions) -> Void = { receiver, scene, session, options in
            if let metadata = options.cloudKitShareMetadata { CloudKitSharing.shared.receive(metadata) }
            if let original {
                typealias Function = @convention(c) (AnyObject, Selector, UIScene, UISceneSession, UIScene.ConnectionOptions) -> Void
                unsafeBitCast(original, to: Function.self)(receiver, selector, scene, session, options)
            }
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "v@:@@@")
    }
    #endif
}
