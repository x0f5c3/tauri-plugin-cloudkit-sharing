import CloudKit
import CoreLocation
import Foundation

public enum CloudKitCodec {
    public static func zoneID(_ value: [String: Any]) throws -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: try requiredString(value, "zoneName"), ownerName: try requiredString(value, "ownerName"))
    }
    public static func recordID(_ value: [String: Any]) throws -> CKRecord.ID {
        CKRecord.ID(recordName: try requiredString(value, "recordName"), zoneID: try zoneID(requiredObject(value, "zoneId")))
    }
    public static func encodeZoneID(_ id: CKRecordZone.ID) -> [String: Any] { ["zoneName": id.zoneName, "ownerName": id.ownerName] }
    public static func encodeRecordID(_ id: CKRecord.ID) -> [String: Any] { ["recordName": id.recordName, "zoneId": encodeZoneID(id.zoneID)] }

    public static func encodeRecord(_ record: CKRecord) throws -> [String: Any] {
        var fields: [String: Any] = [:]
        for key in record.allKeys() {
            if let value = record[key] { fields[key] = try encodeField(value) }
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return ["recordId": encodeRecordID(record.recordID), "recordType": record.recordType,
                "fields": fields, "parent": record.parent.map { encodeRecordID($0.recordID) } as Any? ?? NSNull(),
                "systemFields": archiver.encodedData.base64EncodedString()]
    }

    public static func decodeRecord(_ value: [String: Any]) throws -> CKRecord {
        let id = try recordID(requiredObject(value, "recordId"))
        let type = try requiredString(value, "recordType")
        try identifier(type, kind: "record type")
        let record: CKRecord
        if let encoded = value["systemFields"] as? String {
            guard let data = Data(base64Encoded: encoded) else { throw invalid("Invalid system fields base64") }
            let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            defer { decoder.finishDecoding() }
            guard let restored = CKRecord(coder: decoder), restored.recordID == id, restored.recordType == type else {
                throw invalid("System fields do not match record identity/type")
            }
            if let error = decoder.error { throw error }
            record = restored
        } else { record = CKRecord(recordType: type, recordID: id) }
        for (key, field) in try requiredObject(value, "fields") {
            try identifier(key, kind: "field name")
            if field is NSNull { record[key] = nil }
            else {
                guard let object = field as? [String: Any] else { throw invalid("Invalid field \(key)") }
                record[key] = try decodeField(object)
            }
        }
        if let parent = value["parent"] as? [String: Any] {
            record.parent = CKRecord.Reference(recordID: try recordID(parent), action: .none)
        } else if value["parent"] is NSNull { record.parent = nil }
        return record
    }

    public static func decodeField(_ field: [String: Any]) throws -> CKRecordValue {
        let type = try requiredString(field, "type")
        let value = field["value"]
        switch type {
        case "string": guard let value = value as? String else { throw invalid("Expected string") }; return value as NSString
        case "int64": guard let text = value as? String, let number = Int64(text) else { throw invalid("Invalid int64 decimal string") }; return NSNumber(value: number)
        case "double": guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw invalid("Expected finite double") }; return NSNumber(value: number.doubleValue)
        case "bytes": guard let text = value as? String, let data = Data(base64Encoded: text) else { throw invalid("Invalid bytes base64") }; return data as NSData
        case "date": guard let number = value as? NSNumber, number.doubleValue.isFinite else { throw invalid("Expected finite timestamp") }; return NSDate(timeIntervalSince1970: number.doubleValue)
        case "location":
            guard let object = value as? [String: Any], let latitude = object["latitude"] as? Double, let longitude = object["longitude"] as? Double,
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw invalid("Invalid location") }
            return CLLocation(latitude: latitude, longitude: longitude)
        case "reference":
            guard let object = value as? [String: Any] else { throw invalid("Invalid reference") }
            let action = try requiredString(object, "action")
            guard action == "none" || action == "deleteSelf" else { throw invalid("Invalid reference action") }
            return CKRecord.Reference(recordID: try recordID(requiredObject(object, "recordId")), action: action == "none" ? .none : .deleteSelf)
        case "asset":
            guard let path = value as? String else { throw invalid("Expected asset path") }
            return CKAsset(fileURL: try assetURL(path))
        case "list":
            guard let list = value as? [[String: Any]] else { throw invalid("Expected field list") }
            let types = Set(list.compactMap { $0["type"] as? String })
            guard types.count <= 1, !types.contains("list") else { throw invalid("CloudKit lists must have one scalar type") }
            return try list.map { try decodeField($0) } as NSArray
        default: throw invalid("Unknown field type: \(type)")
        }
    }

    public static func encodeField(_ value: CKRecordValue) throws -> [String: Any] {
        if let string = value as? String { return ["type": "string", "value": string] }
        if let number = value as? NSNumber {
            let kind = String(cString: number.objCType)
            return kind == "d" || kind == "f" ? ["type": "double", "value": number.doubleValue] : ["type": "int64", "value": number.stringValue]
        }
        if let data = value as? Data { return ["type": "bytes", "value": data.base64EncodedString()] }
        if let date = value as? Date { return ["type": "date", "value": date.timeIntervalSince1970] }
        if let location = value as? CLLocation { return ["type": "location", "value": ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude]] }
        if let reference = value as? CKRecord.Reference { return ["type": "reference", "value": ["recordId": encodeRecordID(reference.recordID), "action": reference.action == .deleteSelf ? "deleteSelf" : "none"]] }
        if let asset = value as? CKAsset {
            guard let source = asset.fileURL else { throw invalid("CloudKit asset has no local file") }
            if let allowed = try? assetURL(source.path) { return ["type": "asset", "value": allowed.path] }
            guard let directory = CloudKitCore.shared.assetDirectories.first else { throw NativeError(code: "assetScope", message: "Configure an asset directory before downloading assets") }
            let outputDirectory = URL(fileURLWithPath: directory).appendingPathComponent("cloudkit-downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = outputDirectory.appendingPathComponent(UUID().uuidString)
            _ = try assetURL(destination.path, requireExisting: false)
            try FileManager.default.copyItem(at: source, to: destination)
            return ["type": "asset", "value": destination.path]
        }
        if let list = value as? [CKRecordValue] { return ["type": "list", "value": try list.map(encodeField)] }
        throw invalid("Unsupported CloudKit field value")
    }

    static func assetURL(_ path: String, requireExisting: Bool = true) throws -> URL {
        guard path.hasPrefix("/") else { throw NativeError(code: "assetScope", message: "Asset paths must be absolute") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let allowed = CloudKitCore.shared.assetDirectories.contains { directory in url.path.hasPrefix(directory == "/" ? "/" : directory + "/") }
        guard allowed else { throw NativeError(code: "assetScope", message: "Asset path is outside configured directories") }
        if requireExisting {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard properties.isRegularFile == true else { throw invalid("Asset must be an existing regular file") }
        }
        return url
    }
    static func identifier(_ text: String, kind: String) throws {
        guard text.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw invalid("Invalid \(kind): expected a letter followed by letters, numbers or underscores") }
    }
    private static func invalid(_ message: String) -> NativeError { NativeError(code: "invalidArgument", message: message) }
}

// Secure archives include an explicit context, so tokens cannot cross containers,
// databases or zones. CloudKit validates server token authenticity.
enum CloudKitToken {
    static func context(_ payload: [String: Any], kind: String) throws -> String {
        var context: [String: Any] = ["kind": kind, "containerId": try requiredString(payload, "containerId"), "database": try requiredString(payload, "database")]
        if let zone = payload["zoneId"] as? [String: Any] { context["zoneId"] = CloudKitCodec.encodeZoneID(try CloudKitCodec.zoneID(zone)) }
        return String(data: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func encode(_ object: NSSecureCoding?, context: String) throws -> Any {
        guard let object else { return NSNull() }
        let archive = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
        return try JSONSerialization.data(withJSONObject: ["context": context, "archive": archive.base64EncodedString()], options: [.sortedKeys]).base64EncodedString()
    }
    static func decode<T: NSObject & NSSecureCoding>(_ type: T.Type, value: Any?, context: String) throws -> T? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, let envelope = Data(base64Encoded: text),
              let object = try JSONSerialization.jsonObject(with: envelope) as? [String: String], object["context"] == context,
              let encoded = object["archive"], let data = Data(base64Encoded: encoded),
              let result = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data) else {
            throw NativeError(code: "invalidToken", message: "Invalid token or token belongs to another container/database/zone")
        }
        return result
    }
}
