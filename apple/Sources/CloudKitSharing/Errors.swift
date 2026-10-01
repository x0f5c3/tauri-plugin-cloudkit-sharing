import CloudKit
import Foundation

public struct NativeError: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public func nativeError(_ error: Error) -> [String: Any] {
    if let error = error as? NativeError { return ["code": error.code, "message": error.message] }
    let ns = error as NSError
    var result: [String: Any] = ["code": ns.domain == CKErrorDomain ? "cloudKit" : "native", "message": ns.localizedDescription, "nativeCode": ns.code]
    if let delay = ns.userInfo[CKErrorRetryAfterKey] as? NSNumber { result["retryAfterSeconds"] = delay }
    if let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
        result["partialErrors"] = partial.map { key, value in
            let name: String
            if let id = key as? CKRecord.ID { name = "\(id.zoneID.ownerName)/\(id.zoneID.zoneName)/\(id.recordName)" }
            else if let id = key as? CKRecordZone.ID { name = "\(id.ownerName)/\(id.zoneName)" }
            else { name = String(describing: key) }
            return ["itemId": name, "error": nativeError(value)] as [String: Any]
        }
    }
    for (key, output) in [(CKRecordChangedErrorServerRecordKey, "serverRecord"), (CKRecordChangedErrorClientRecordKey, "clientRecord"), (CKRecordChangedErrorAncestorRecordKey, "ancestorRecord")] {
        if let record = ns.userInfo[key] as? CKRecord { result[output] = try? CloudKitCodec.encodeRecord(record) }
    }
    return result
}

func requiredString(_ value: [String: Any], _ key: String) throws -> String {
    guard let string = value[key] as? String, !string.isEmpty else { throw NativeError(code: "invalidArgument", message: "Missing or empty \(key)") }
    return string
}

func requiredObject(_ value: [String: Any], _ key: String) throws -> [String: Any] {
    guard let object = value[key] as? [String: Any] else { throw NativeError(code: "invalidArgument", message: "Missing object \(key)") }
    return object
}
