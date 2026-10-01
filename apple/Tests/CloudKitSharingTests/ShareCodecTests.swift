import XCTest
import CloudKit
@testable import CloudKitSharing

final class ShareCodecTests: XCTestCase {
    func testZoneShareRetainsCloudKitIdentifiersAndMetadata() throws {
        let zone = CKRecordZone.ID(zoneName: "notes", ownerName: CKCurrentUserDefaultName)
        let share = CKShare(recordZoneID: zone)
        share[CKShare.SystemFieldKey.title] = "Team notes" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "example.notes" as CKRecordValue
        share.publicPermission = .readOnly
        let value = CloudKitSharing.shared.encodeShare(share)
        XCTAssertEqual(value["title"] as? String, "Team notes")
        XCTAssertEqual(value["shareType"] as? String, "example.notes")
        XCTAssertEqual(value["publicPermission"] as? String, "readOnly")
        let recordId = try XCTUnwrap(value["recordId"] as? [String: Any])
        let zoneId = try XCTUnwrap(recordId["zoneId"] as? [String: Any])
        XCTAssertEqual(zoneId["zoneName"] as? String, "notes")
        XCTAssertEqual(zoneId["ownerName"] as? String, CKCurrentUserDefaultName)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
    }
    func testHierarchyShareHasItsOwnIdInRootZone() throws {
        let zone = CKRecordZone.ID(zoneName: "project", ownerName: CKCurrentUserDefaultName)
        let root = CKRecord(recordType: "Note", recordID: .init(recordName: "root", zoneID: zone))
        let share = CKShare(rootRecord: root)
        let value = CloudKitSharing.shared.encodeShare(share)
        let id = try XCTUnwrap(value["recordId"] as? [String: Any])
        XCTAssertNotEqual(id["recordName"] as? String, "root")
        XCTAssertEqual(value["publicPermission"] as? String, "none")
        XCTAssertNil(value["url"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
    }
}
