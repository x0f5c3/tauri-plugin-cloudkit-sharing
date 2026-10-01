import CloudKit
import Foundation

#if os(iOS)
  import UIKit
  import WebKit
#elseif os(macOS)
  import AppKit
#endif

public final class CloudKitSharing {
  public static let shared = CloudKitSharing()
  private var presentations: [UUID: AnyObject] = [:]
  private init() {}

  public func installEarly() { SharingLifecycle.installEarly() }
  public func install() {
    InvitationInbox.shared.load()
    SharingLifecycle.install()
  }
  public func receive(_ metadata: CKShare.Metadata) {
    do {
      let isNew = try InvitationInbox.shared.insert(metadata)
      if isNew
        && (try? CloudKitCore.shared.container(["containerId": metadata.containerIdentifier]))
          != nil
      {
        event(
          "invitationReceived", container: metadata.containerIdentifier,
          invitation: encodeInvitation(metadata))
      }
    } catch { event("error", container: metadata.containerIdentifier, error: error) }
  }
  func event(
    _ kind: String, container: String, invitation: [String: Any]? = nil, share: CKShare? = nil,
    error: Error? = nil
  ) {
    var value: [String: Any] = ["kind": kind, "containerId": container]
    if let invitation { value["invitation"] = invitation }
    if let share { value["share"] = encodeShare(share) }
    if let error { value["error"] = nativeError(error) }
    CloudKitCore.shared.emit?(value)
  }
  public func execute(_ command: String, _ payload: [String: Any]) async throws -> Any {
    if command == "pending_invitations" {
      return try InvitationInbox.shared.all().filter { allowed($0) }.map(encodeInvitation)
    }
    if command == "dismiss_invitation" || command == "accept_invitation" {
      guard let id = payload["invitationId"] as? String,
        let metadata = try InvitationInbox.shared.get(id), allowed(metadata)
      else {
        throw NativeError(
          code: "invitationNotFound", message: "No pending invitation in an allowed container.")
      }
      if command == "dismiss_invitation" {
        try InvitationInbox.shared.remove(id)
        return NSNull()
      }
      let container = try CloudKitCore.shared.container([
        "containerId": metadata.containerIdentifier
      ])
      let results = try await container.accept([metadata])
      guard let result = results[metadata] else {
        throw NativeError(
          code: "missingResult", message: "CloudKit did not return acceptance result.")
      }
      let share = try result.get()
      try InvitationInbox.shared.remove(id)
      event("shareAccepted", container: metadata.containerIdentifier, share: share)
      return encodeShare(share)
    }
    let container = try CloudKitCore.shared.container(payload)
    let containerId = container.containerIdentifier ?? ""
    if command == "fetch_invitation" {
      guard let string = payload["url"] as? String, let url = URL(string: string),
        url.scheme == "https", let host = url.host,
        host == "icloud.com" || host.hasSuffix(".icloud.com")
      else {
        throw NativeError(
          code: "invalidArgument", message: "An HTTPS iCloud share URL is required.")
      }
      let results = try await container.shareMetadatas(for: [url])
      guard let result = results[url] else {
        throw NativeError(code: "missingResult", message: "CloudKit returned no share metadata.")
      }
      let metadata = try result.get()
      guard metadata.containerIdentifier == containerId else {
        throw NativeError(
          code: "containerMismatch", message: "Invitation belongs to another container.")
      }
      try InvitationInbox.shared.insert(metadata)
      event("invitationReceived", container: containerId, invitation: encodeInvitation(metadata))
      return encodeInvitation(metadata)
    }
    if command == "create_share" {
      guard let target = payload["target"] as? [String: Any] else {
        throw NativeError(code: "invalidArgument", message: "Missing share target.")
      }
      let share: CKShare
      var records: [CKRecord] = []
      switch target["type"] as? String {
      case "record":
        guard let value = target["record"] as? [String: Any] else {
          throw NativeError(code: "invalidArgument", message: "Missing root record.")
        }
        let root = try CloudKitCodec.decodeRecord(value)
        guard root.share == nil else {
          throw NativeError(
            code: "alreadyShared", message: "The root record already belongs to a share.")
        }
        try requireCustomZone(root.recordID.zoneID)
        share = CKShare(rootRecord: root)
        records.append(root)
      case "zone":
        guard let value = target["zoneId"] as? [String: Any] else {
          throw NativeError(code: "invalidArgument", message: "Missing zone ID.")
        }
        let zoneId = try CloudKitCodec.zoneID(value)
        try requireCustomZone(zoneId)
        share = CKShare(recordZoneID: zoneId)
      default: throw NativeError(code: "invalidArgument", message: "Unknown share target.")
      }
      try updateMetadata(share, payload)
      records.append(share)
      return encodeShare(
        try await saveShare(share, records: records, database: container.privateCloudDatabase))
    }
    guard let value = payload["shareId"] as? [String: Any] else {
      throw NativeError(code: "invalidArgument", message: "Missing share ID.")
    }
    let id = try CloudKitCodec.recordID(value)
    let database: CKDatabase
    if command == "fetch_share" || command == "present_sharing_ui" {
      database = try CloudKitCore.shared.database(payload)
    } else {
      database =
        command == "leave_share" ? container.sharedCloudDatabase : container.privateCloudDatabase
    }
    guard let share = try await database.record(for: id) as? CKShare else {
      throw NativeError(code: "invalidArgument", message: "Record is not a share.")
    }
    switch command {
    case "fetch_share": return encodeShare(share)
    case "present_sharing_ui":
      try await MainActor.run { try present(share, container: container, payload: payload) }
      return NSNull()
    case "stop_sharing", "leave_share":
      let isOwner = share.currentUserParticipant?.role == .owner
      guard command == "stop_sharing" ? isOwner : !isOwner else {
        throw NativeError(
          code: "permissionDenied", message: "Owners stop sharing; participants leave shares.")
      }
      _ = try await database.deleteRecord(withID: id)
      event("sharingStopped", container: containerId, share: share)
      return NSNull()
    case "update_share", "set_participant_permission", "remove_participant", "add_participant":
      guard share.currentUserParticipant?.role == .owner else {
        throw NativeError(
          code: "permissionDenied", message: "Only the owner may modify this share.")
      }
      if command != "update_share" && share.publicPermission != .none {
        throw NativeError(
          code: "invalidArgument",
          message: "Individual participants can only be managed on a private share.")
      }
      if command == "update_share" {
        try updateMetadata(share, payload)
      } else if command == "add_participant" {
        guard let lookup = payload["lookup"] as? [String: Any],
          let value = lookup["value"] as? String, !value.isEmpty
        else { throw NativeError(code: "invalidArgument", message: "Missing participant lookup.") }
        let info: CKUserIdentity.LookupInfo
        switch lookup["type"] as? String {
        case "email": info = .init(emailAddress: value)
        case "phoneNumber": info = .init(phoneNumber: value)
        case "userRecordId": info = .init(userRecordID: CKRecord.ID(recordName: value))
        default:
          throw NativeError(code: "invalidArgument", message: "Unknown participant lookup type.")
        }
        let participant = try await fetchParticipant(info, container: container)
        guard participant.role == .privateUser,
          participant.__participantID != share.owner.__participantID
        else {
          throw NativeError(
            code: "invalidArgument",
            message: "Only private users other than the owner may be added.")
        }
        participant.permission = try permission(payload["permission"], allowNone: false)
        share.addParticipant(participant)
      } else {
        guard let participantId = payload["participantId"] as? String,
          let participant = share.participants.first(where: { $0.__participantID == participantId }
          ), participant.role == .privateUser
        else {
          throw NativeError(
            code: "invalidArgument", message: "Participant is missing or is not a private user.")
        }
        if command == "remove_participant" {
          share.removeParticipant(participant)
        } else {
          participant.permission = try permission(payload["permission"], allowNone: false)
        }
      }
      return encodeShare(try await saveShare(share, records: [share], database: database))
    default:
      throw NativeError(code: "unknownCommand", message: "Unknown sharing command: \(command)")
    }
  }
  private func allowed(_ metadata: CKShare.Metadata) -> Bool {
    (try? CloudKitCore.shared.container(["containerId": metadata.containerIdentifier])) != nil
  }
  private func requireCustomZone(_ zone: CKRecordZone.ID) throws {
    guard zone.zoneName != CKRecordZone.default().zoneID.zoneName else {
      throw NativeError(code: "invalidArgument", message: "Sharing requires a custom record zone.")
    }
  }
  private func permission(_ value: Any?, allowNone: Bool = true) throws
    -> CKShare.ParticipantPermission
  {
    switch value as? String {
    case "none" where allowNone: return .none
    case "readOnly": return .readOnly
    case "readWrite": return .readWrite
    default: throw NativeError(code: "invalidArgument", message: "Invalid share permission.")
    }
  }
  private func updateMetadata(_ share: CKShare, _ payload: [String: Any]) throws {
    share[CKShare.SystemFieldKey.title] = payload["title"] as? String as CKRecordValue?
    share[CKShare.SystemFieldKey.shareType] = payload["shareType"] as? String as CKRecordValue?
    if let value = payload["thumbnail"] as? String {
      guard let data = Data(base64Encoded: value) else {
        throw NativeError(code: "invalidArgument", message: "Invalid thumbnail base64.")
      }
      share[CKShare.SystemFieldKey.thumbnailImageData] = data as CKRecordValue
    } else {
      share[CKShare.SystemFieldKey.thumbnailImageData] = nil
    }
    share.publicPermission = try permission(payload["publicPermission"])
  }
  private func fetchParticipant(_ info: CKUserIdentity.LookupInfo, container: CKContainer)
    async throws -> CKShare.Participant
  {
    try await withCheckedThrowingContinuation { continuation in
      let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [info])
      // CloudKit serializes both operation callbacks on its private queue.
      var participantResult: Result<CKShare.Participant, Error>?
      operation.perShareParticipantResultBlock = { _, result in participantResult = result }
      operation.fetchShareParticipantsResultBlock = { result in
        do {
          try result.get()
          guard let participantResult else {
            throw NativeError(code: "missingResult", message: "CloudKit returned no participant.")
          }
          continuation.resume(returning: try participantResult.get())
        } catch { continuation.resume(throwing: error) }
      }
      operation.qualityOfService = .userInitiated
      container.add(operation)
    }
  }
  private func saveShare(_ share: CKShare, records: [CKRecord], database: CKDatabase) async throws
    -> CKShare
  {
    let result = try await database.modifyRecords(
      saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    for value in result.saveResults.values { _ = try value.get() }
    guard let result = result.saveResults[share.recordID], let saved = try result.get() as? CKShare
    else {
      throw NativeError(code: "missingResult", message: "CloudKit did not return saved share.")
    }
    return saved
  }
  func encodeShare(_ share: CKShare) -> [String: Any] {
    var output: [String: Any] = [
      "recordId": CloudKitCodec.encodeRecordID(share.recordID),
      "publicPermission": permissionString(share.publicPermission),
      "participants": share.participants.map(encodeParticipant),
    ]
    output["url"] = share.url?.absoluteString
    output["title"] = share[CKShare.SystemFieldKey.title] as? String
    output["shareType"] = share[CKShare.SystemFieldKey.shareType] as? String
    output["currentUserParticipant"] = share.currentUserParticipant.map(encodeParticipant)
    return output
  }
  private func permissionString(_ value: CKShare.ParticipantPermission) -> String {
    switch value {
    case .none: return "none"
    case .readOnly: return "readOnly"
    case .readWrite: return "readWrite"
    default: return "unknown"
    }
  }
  private func encodeParticipant(_ value: CKShare.Participant) -> [String: Any] {
    let role: String
    switch value.role {
    case .owner: role = "owner"
    case .privateUser: role = "privateUser"
    case .publicUser: role = "publicUser"
    default: role = "unknown"
    }
    let status: String
    switch value.acceptanceStatus {
    case .pending: status = "pending"
    case .accepted: status = "accepted"
    case .removed: status = "removed"
    default: status = "unknown"
    }
    var result: [String: Any] = [
      "participantId": value.__participantID, "role": role,
      "permission": permissionString(value.permission), "acceptanceStatus": status,
    ]
    if let name = value.userIdentity.nameComponents {
      result["displayName"] = PersonNameComponentsFormatter.localizedString(
        from: name, style: .default)
    }
    return result
  }
  func encodeInvitation(_ metadata: CKShare.Metadata) -> [String: Any] {
    var result: [String: Any] = [
      "id": InvitationInbox.identifier(metadata), "containerId": metadata.containerIdentifier,
      "share": encodeShare(metadata.share),
    ]
    result["url"] = metadata.share.url?.absoluteString
    result["rootRecordId"] = metadata.hierarchicalRootRecordID.map(CloudKitCodec.encodeRecordID)
    return result
  }
  @MainActor private func present(_ share: CKShare, container: CKContainer, payload: [String: Any])
    throws
  {
    guard presentations.isEmpty else {
      throw NativeError(code: "sharingUiBusy", message: "A sharing controller is already open.")
    }
    guard let raw = payload["nativePresentation"] as? String, let presentationToken = UInt64(raw),
      let nativeObject = NativePresentationRegistry.resolve(presentationToken)
    else {
      throw NativeError(
        code: "windowNotFound",
        message: "Native presentation window has expired or was not registered.")
    }
    #if os(macOS)
      let resolved = nativeObject as? NSWindow
    #elseif os(iOS)
      let resolved = (nativeObject as? WKWebView)?.window ?? nativeObject as? UIWindow
    #endif
    guard resolved != nil else {
      throw NativeError(
        code: "windowNotFound", message: "Native presentation window is unavailable.")
    }
    let token = UUID()
    let anchor = payload["anchor"] as? [String: Double]
    #if os(iOS)
      guard
        let window = resolved
          ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({
            $0.windows
          }).first(where: { $0.isKeyWindow }), var presenter = window.rootViewController
      else { throw NativeError(code: "windowNotFound", message: "No active application window.") }
      while let next = presenter.presentedViewController { presenter = next }
      let delegate = IOSSharingDelegate(
        owner: self, container: container.containerIdentifier ?? "", token: token)
      let controller = ClosingCloudSharingController(share: share, container: container)
      controller.onClose = { [weak self] in
        self?.close(token, container: container.containerIdentifier ?? "")
      }
      controller.delegate = delegate
      controller.presentationController?.delegate = delegate
      if let popover = controller.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect =
          anchor.map {
            CGRect(
              x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: max(1, $0["width"] ?? 1),
              height: max(1, $0["height"] ?? 1))
          }
          ?? CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      }
      presentations[token] = delegate
      presenter.present(controller, animated: true)
      controller.presentationController?.delegate = delegate
    #elseif os(macOS)
      guard let window = resolved ?? NSApp.keyWindow ?? NSApp.mainWindow,
        let service = NSSharingService(named: .cloudSharing)
      else {
        throw NativeError(
          code: "windowNotFound", message: "No active application window or cloud sharing service.")
      }
      let provider = NSItemProvider()
      provider.registerCloudKitShare(share, container: container)
      let delegate = MacSharingDelegate(
        owner: self, container: container.containerIdentifier ?? "", token: token, window: window,
        anchor: anchor, service: service)
      service.delegate = delegate
      presentations[token] = delegate
      guard service.canPerform(withItems: [provider]) else {
        presentations[token] = nil
        throw NativeError(
          code: "sharingUiUnavailable", message: "Cloud sharing UI cannot present this share.")
      }
      service.perform(withItems: [provider])
    #endif
  }
  fileprivate func close(_ token: UUID, container: String, error: Error? = nil) {
    guard presentations[token] != nil else { return }
    event("sharingUiClosed", container: container, error: error)
    presentations[token] = nil
  }
}
#if os(iOS)
  private final class ClosingCloudSharingController: UICloudSharingController {
    var onClose: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)
      if presentingViewController == nil || isBeingDismissed { onClose?() }
    }
  }
  private final class IOSSharingDelegate: NSObject, UICloudSharingControllerDelegate,
    UIAdaptivePresentationControllerDelegate
  {
    let owner: CloudKitSharing
    let container: String
    let token: UUID
    init(owner: CloudKitSharing, container: String, token: UUID) {
      self.owner = owner
      self.container = container
      self.token = token
    }
    func itemTitle(for csc: UICloudSharingController) -> String? {
      csc.share?[CKShare.SystemFieldKey.title] as? String ?? "Shared content"
    }
    func cloudSharingController(
      _ csc: UICloudSharingController, failedToSaveShareWithError error: Error
    ) { owner.event("error", container: container, error: error) }
    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
      owner.event("sharingUiSaved", container: container, share: csc.share)
    }
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
      owner.event("sharingStopped", container: container, share: csc.share)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      owner.close(token, container: container)
    }
  }
#elseif os(macOS)
  private final class MacSharingDelegate: NSObject, NSCloudSharingServiceDelegate {
    let owner: CloudKitSharing
    let container: String
    let token: UUID
    weak var window: NSWindow?
    let anchor: [String: Double]?
    let service: NSSharingService
    init(
      owner: CloudKitSharing, container: String, token: UUID, window: NSWindow,
      anchor: [String: Double]?, service: NSSharingService
    ) {
      self.owner = owner
      self.container = container
      self.token = token
      self.window = window
      self.anchor = anchor
      self.service = service
    }
    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
      owner.event("sharingUiSaved", container: container, share: share)
    }
    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
      owner.event("sharingStopped", container: container, share: share)
    }
    func sharingService(
      _ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?
    ) { owner.close(token, container: container, error: error) }
    func sharingService(
      _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
      sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? { window }
    func anchoringView(
      for sharingService: NSSharingService,
      showRelativeTo positioningRect: UnsafeMutablePointer<NSRect>,
      preferredEdge: UnsafeMutablePointer<NSRectEdge>
    ) -> NSView? {
      guard let view = window?.contentView else { return nil }
      positioningRect.pointee =
        anchor.map {
          NSRect(
            x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: max(1, $0["width"] ?? 1),
            height: max(1, $0["height"] ?? 1))
        } ?? NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
      preferredEdge.pointee = .minY
      return view
    }
  }
#endif
