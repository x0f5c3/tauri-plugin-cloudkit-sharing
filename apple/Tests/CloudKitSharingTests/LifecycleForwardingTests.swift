import XCTest
@testable import CloudKitSharing

private class DelegateHost: NSObject {
    var assignmentCount = 0
    var assigned: AnyObject?
    @objc dynamic var delegate: AnyObject? {
        get { assigned }
        set { assignmentCount += 1; assigned = newValue }
    }
}
private final class InheritedDelegateHost: DelegateHost {}

final class LifecycleForwardingTests: XCTestCase {
    func testDelegateSetterPreservesAssignmentAndInstallsBeforeHostSeesDelegate() {
        let host = InheritedDelegateHost()
        let first = NSObject()
        let second = NSObject()
        var observed: [AnyObject] = []
        var countsAtHook: [Int] = []
        SharingLifecycle.interceptSetter(InheritedDelegateHost.self) { delegate in
            observed.append(delegate)
            countsAtHook.append(host.assignmentCount)
        }
        host.delegate = first
        host.delegate = second
        host.delegate = nil
        XCTAssertEqual(host.assignmentCount, 3)
        XCTAssertNil(host.delegate)
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(observed[0] === first)
        XCTAssertTrue(observed[1] === second)
        XCTAssertEqual(countsAtHook, [0, 1])
        // Swizzling a subclass must leave the superclass implementation intact.
        let other = DelegateHost()
        other.delegate = first
        XCTAssertEqual(other.assignmentCount, 1)
        XCTAssertTrue(other.delegate === first)
        XCTAssertEqual(observed.count, 2)
    }
}
