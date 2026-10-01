import CloudKit
import Foundation
import XCTest
@testable import CloudKitSharing

final class CodecTests: XCTestCase {
    private let zone: [String: Any] = ["zoneName": "Notes", "ownerName": CKCurrentUserDefaultName]

    func testLosslessInt64AndBinary() throws {
        for value in ["9223372036854775807", "-9223372036854775808", "9007199254740993"] {
            let encoded = try CloudKitCodec.encodeField(CloudKitCodec.decodeField(["type": "int64", "value": value]))
            XCTAssertEqual(encoded["type"] as? String, "int64")
            XCTAssertEqual(encoded["value"] as? String, value)
        }
        let encoded = try CloudKitCodec.encodeField(CloudKitCodec.decodeField(["type": "bytes", "value": "AP8QgA=="]))
        XCTAssertEqual(encoded["value"] as? String, "AP8QgA==")
        XCTAssertThrowsError(try CloudKitCodec.decodeField(["type": "int64", "value": "9223372036854775808"]))
    }

    func testSystemFieldsPreserveIdentityAndRejectMismatch() throws {
        let record = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: "one", zoneID: try CloudKitCodec.zoneID(zone)))
        record["counter"] = NSNumber(value: Int64.max)
        let encoded = try CloudKitCodec.encodeRecord(record)
        let restored = try CloudKitCodec.decodeRecord(encoded)
        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored["counter"] as? NSNumber, NSNumber(value: Int64.max))
        var mismatch = encoded
        mismatch["recordType"] = "Other"
        XCTAssertThrowsError(try CloudKitCodec.decodeRecord(mismatch))
        mismatch = encoded
        mismatch["recordId"] = ["recordName": "other", "zoneId": zone]
        XCTAssertThrowsError(try CloudKitCodec.decodeRecord(mismatch))
    }

    func testNullDeletesFieldAndParent() throws {
        let record: [String: Any] = ["recordType": "Note", "recordId": ["recordName": "one", "zoneId": zone], "fields": ["removed": NSNull()], "parent": NSNull()]
        let decoded = try CloudKitCodec.decodeRecord(record)
        XCTAssertNil(decoded["removed"])
        XCTAssertNil(decoded.parent)
        XCTAssertTrue(decoded.changedKeys().contains("removed"))
    }

    func testReferenceAndHomogeneousLists() throws {
        let reference: [String: Any] = ["type": "reference", "value": ["recordId": ["recordName": "parent", "zoneId": zone], "action": "deleteSelf"]]
        let decoded = try XCTUnwrap(CloudKitCodec.decodeField(reference) as? CKRecord.Reference)
        XCTAssertEqual(decoded.action, .deleteSelf)
        XCTAssertEqual(decoded.recordID.recordName, "parent")
        let list = try CloudKitCodec.decodeField(["type": "list", "value": [["type": "int64", "value": "1"], ["type": "int64", "value": "2"]]])
        XCTAssertEqual((try CloudKitCodec.encodeField(list)["value"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try CloudKitCodec.decodeField(["type": "list", "value": [["type": "int64", "value": "1"], ["type": "string", "value": "2"]]]))
        XCTAssertThrowsError(try CloudKitCodec.decodeField(["type": "location", "value": ["latitude": 91, "longitude": 0]]))
        XCTAssertThrowsError(try CloudKitCodec.decodeField(["type": "double", "value": Double.infinity]))
    }

    func testTokenContextRejectsCrossDatabaseAndMalformedArchives() throws {
        let privatePayload: [String: Any] = ["containerId": "iCloud.test", "database": "private", "zoneId": zone]
        var sharedPayload = privatePayload
        sharedPayload["database"] = "shared"
        let privateContext = try CloudKitToken.context(privatePayload, kind: "zone")
        let sharedContext = try CloudKitToken.context(sharedPayload, kind: "zone")
        XCTAssertNotEqual(privateContext, sharedContext)
        let envelope = try CloudKitToken.encode("wrongClass" as NSString, context: privateContext)
        XCTAssertThrowsError(try CloudKitToken.decode(CKServerChangeToken.self, value: envelope, context: sharedContext))
        XCTAssertThrowsError(try CloudKitToken.decode(CKServerChangeToken.self, value: "not base64", context: privateContext))
        XCTAssertNil(try CloudKitToken.decode(CKServerChangeToken.self, value: NSNull(), context: privateContext))
    }

    func testAssetScopeRejectsSiblingAndSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data([1, 2, 3]).write(to: outside)
        let inside = allowed.appendingPathComponent("inside")
        try Data([4]).write(to: inside)
        let link = allowed.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try CloudKitCore.shared.configure(["containers": ["iCloud.test"], "assetDirectories": [allowed.path]])
        XCTAssertEqual(try CloudKitCodec.assetURL(inside.path), inside.resolvingSymlinksInPath())
        XCTAssertThrowsError(try CloudKitCodec.assetURL(outside.path))
        XCTAssertThrowsError(try CloudKitCodec.assetURL(link.path))
        XCTAssertThrowsError(try CloudKitCodec.assetURL("relative.txt"))
        XCTAssertThrowsError(try CloudKitCore.shared.container(["containerId": "iCloud.not-configured"]))
    }

    func testErrorsPreservePartialFailuresAndRetryDelay() throws {
        let id = CKRecord.ID(recordName: "failed", zoneID: try CloudKitCodec.zoneID(zone))
        let item = NSError(domain: CKErrorDomain, code: CKError.requestRateLimited.rawValue, userInfo: [CKErrorRetryAfterKey: 12.5])
        let error = NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue, userInfo: [CKPartialErrorsByItemIDKey: [id: item]])
        let encoded = nativeError(error)
        let partial = try XCTUnwrap(encoded["partialErrors"] as? [[String: Any]])
        XCTAssertEqual(partial.count, 1)
        XCTAssertTrue((partial[0]["itemId"] as? String)?.hasSuffix("/failed") == true)
        let child = try XCTUnwrap(partial[0]["error"] as? [String: Any])
        XCTAssertEqual(child["nativeCode"] as? Int, CKError.requestRateLimited.rawValue)
        XCTAssertEqual(child["retryAfterSeconds"] as? Double, 12.5)
    }
}
