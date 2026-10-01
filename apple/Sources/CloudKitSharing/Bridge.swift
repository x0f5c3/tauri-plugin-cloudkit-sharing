import Foundation
import CloudKitSharingBootstrap

public typealias CloudKitResponseCallback = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void
public typealias CloudKitEventCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

@_cdecl("cloudkit_sharing_install_early")
public func cloudkitSharingInstallEarly() { CloudKitSharing.shared.installEarly() }

private func jsonString(_ value: Any) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch {
        return "{\"error\":{\"code\":\"serializationError\",\"message\":\"Native response could not be serialized\"}}"
    }
}
private func parse(_ input: UnsafePointer<CChar>?) throws -> [String: Any] {
    guard let input, let data = String(cString: input).data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NativeError(code: "invalidArgument", message: "Expected a JSON object")
    }
    return value
}

// Rust copies and frees this result before returning from setup.
@_cdecl("cloudkit_sharing_initialize")
public func cloudkitSharingInitialize(_ config: UnsafePointer<CChar>?, _ event: CloudKitEventCallback?) -> UnsafeMutablePointer<CChar>? {
    cloudkit_sharing_bootstrap_anchor()
    do {
        CloudKitCore.shared.emit = { value in jsonString(value).withCString { event?($0) } }
        try CloudKitCore.shared.configure(parse(config))
        return strdup(jsonString(["ok": NSNull()]))
    } catch { return strdup(jsonString(["error": nativeError(error)])) }
}

@_cdecl("cloudkit_sharing_execute")
public func cloudkitSharingExecute(_ id: UInt64, _ command: UnsafePointer<CChar>?, _ payload: UnsafePointer<CChar>?, _ callback: CloudKitResponseCallback?) {
    // Copy borrowed Rust buffers before scheduling asynchronous work.
    do {
        guard let command else { throw NativeError(code: "invalidArgument", message: "Command is missing") }
        let name = String(cString: command)
        let value = try parse(payload)
        Task {
            let reply: [String: Any]
            do { reply = ["ok": try await CloudKitCore.shared.execute(name, value)] }
            catch { reply = ["error": nativeError(error)] }
            jsonString(reply).withCString { callback?(id, $0) }
        }
    } catch { jsonString(["error": nativeError(error)]).withCString { callback?(id, $0) } }
}

@_cdecl("cloudkit_sharing_free")
public func cloudkitSharingFree(_ value: UnsafeMutablePointer<CChar>?) { free(value) }

// The Rust host registers borrowed native views/windows on the main thread.
// Tokens keep Objective-C objects alive across CloudKit awaits, and never expose
// raw pointers to the frontend. Expired requests resolve to no object safely.
enum NativePresentationRegistry {
    private static let lock = NSLock()
    private static var next: UInt64 = 1
    private static var objects: [UInt64: AnyObject] = [:]
    static func register(_ object: AnyObject) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let id = next; next &+= 1; objects[id] = object; return id
    }
    static func resolve(_ token: UInt64) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }; return objects[token]
    }
    static func remove(_ token: UInt64) {
        DispatchQueue.main.async { lock.lock(); objects[token] = nil; lock.unlock() }
    }
}
@_cdecl("cloudkit_sharing_register_presentation")
public func cloudkitSharingRegisterPresentation(_ pointer: UnsafeMutableRawPointer?) -> UInt64 {
    guard Thread.isMainThread, let pointer else { return 0 }
    return NativePresentationRegistry.register(Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue())
}
@_cdecl("cloudkit_sharing_release_presentation")
public func cloudkitSharingReleasePresentation(_ token: UInt64) { NativePresentationRegistry.remove(token) }
