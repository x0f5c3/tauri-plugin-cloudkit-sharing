import CloudKit
import Foundation

extension CloudKitCore {
    func executeData(_ command: String, _ payload: [String: Any]) async throws -> Any {
        let database = try self.database(payload)
        switch command {
        case "list_zones": return try await database.allRecordZones().map { CloudKitCodec.encodeZoneID($0.zoneID) }
        case "create_zone":
            guard payload["database"] as? String == "private" else { throw NativeError(code: "invalidArgument", message: "Zones can only be created in the private database") }
            let zone = CKRecordZone(zoneID: try CloudKitCodec.zoneID(requiredObject(payload, "zoneId")))
            return CloudKitCodec.encodeZoneID(try await database.save(zone).zoneID)
        case "delete_zone":
            _ = try await database.deleteRecordZone(withID: CloudKitCodec.zoneID(requiredObject(payload, "zoneId")))
            return NSNull()
        case "fetch_records":
            let ids = try objects(payload, "recordIds").map(CloudKitCodec.recordID)
            if ids.isEmpty { return [[String: Any]]() }
            let results = try await database.records(for: ids)
            try rejectPartial(results)
            return try ids.map { id in
                guard let result = results[id] else { throw NativeError(code: "invalidResponse", message: "Missing fetched record") }
                return try CloudKitCodec.encodeRecord(result.get())
            }
        case "modify_records":
            let records = try objects(payload, "records").map(CloudKitCodec.decodeRecord)
            let ids = try objects(payload, "deleteIds").map(CloudKitCodec.recordID)
            let policy: CKModifyRecordsOperation.RecordSavePolicy
            switch try requiredString(payload, "savePolicy") {
            case "ifServerRecordUnchanged": policy = .ifServerRecordUnchanged
            case "changedKeys": policy = .changedKeys
            case "allKeys": policy = .allKeys
            default: throw NativeError(code: "invalidArgument", message: "Unknown save policy")
            }
            guard let atomic = payload["atomic"] as? Bool else { throw NativeError(code: "invalidArgument", message: "atomic is required") }
            if records.isEmpty && ids.isEmpty { return ["saved": [], "deleted": []] as [String: Any] }
            let result = try await database.modifyRecords(saving: records, deleting: ids, savePolicy: policy, atomically: atomic)
            var errors = failures(result.saveResults)
            errors.merge(failures(result.deleteResults)) { first, _ in first }
            if !errors.isEmpty { throw partialError(errors) }
            return ["saved": try records.map { record -> [String: Any] in
                guard let saved = result.saveResults[record.recordID] else { throw NativeError(code: "invalidResponse", message: "Missing saved record") }
                return try CloudKitCodec.encodeRecord(saved.get())
            }, "deleted": ids.map(CloudKitCodec.encodeRecordID)]
        case "query_records": return try await query(database, payload)
        case "database_changes": return try await databaseChanges(database, payload)
        case "zone_changes": return try await zoneChanges(database, payload)
        default: throw NativeError(code: "unknownCommand", message: command)
        }
    }

    private func query(_ database: CKDatabase, _ payload: [String: Any]) async throws -> Any {
        let limit = try resultLimit(payload)
        let context = try CloudKitToken.context(payload, kind: "query")
        let cursor = try CloudKitToken.decode(CKQueryOperation.Cursor.self, value: payload["cursor"], context: context)
        let result: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        if let cursor { result = try await database.records(continuingMatchFrom: cursor, resultsLimit: limit) }
        else {
            let predicates = try objects(payload, "filters").map { filter -> NSPredicate in
                let field = try requiredString(filter, "field")
                try CloudKitCodec.identifier(field, kind: "query field")
                let value = try CloudKitCodec.decodeField(requiredObject(filter, "value"))
                let comparator = try requiredString(filter, "comparator")
                let op: String
                switch comparator {
                case "equal": op = "=="
                case "notEqual": op = "!="
                case "lessThan": op = "<"
                case "lessThanOrEqual": op = "<="
                case "greaterThan": op = ">"
                case "greaterThanOrEqual": op = ">="
                case "in": op = "IN"
                case "contains": op = "CONTAINS"
                default: throw NativeError(code: "invalidArgument", message: "Invalid query comparator")
                }
                return NSPredicate(format: "%K \(op) %@", argumentArray: [field, value])
            }
            let type = try requiredString(payload, "recordType")
            try CloudKitCodec.identifier(type, kind: "record type")
            let query = CKQuery(recordType: type, predicate: predicates.isEmpty ? NSPredicate(value: true) : NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
            query.sortDescriptors = try objects(payload, "sort").map { sort in
                guard let ascending = sort["ascending"] as? Bool else { throw NativeError(code: "invalidArgument", message: "Sort direction is required") }
                let field = try requiredString(sort, "field")
                try CloudKitCodec.identifier(field, kind: "sort field")
                return NSSortDescriptor(key: field, ascending: ascending)
            }
            let zone = try (payload["zoneId"] as? [String: Any]).map(CloudKitCodec.zoneID)
            result = try await database.records(matching: query, inZoneWith: zone, resultsLimit: limit)
        }
        var errors: [CKRecord.ID: Error] = [:]
        for (id, record) in result.matchResults { if case .failure(let error) = record { errors[id] = error } }
        if !errors.isEmpty { throw partialError(errors) }
        return ["records": try result.matchResults.map { try CloudKitCodec.encodeRecord($0.1.get()) }, "cursor": try CloudKitToken.encode(result.queryCursor, context: context)]
    }

    private func databaseChanges(_ database: CKDatabase, _ payload: [String: Any]) async throws -> Any {
        let context = try CloudKitToken.context(payload, kind: "database")
        let token = try CloudKitToken.decode(CKServerChangeToken.self, value: payload["token"], context: context)
        let operation = CKFetchDatabaseChangesOperation(previousServerChangeToken: token)
        operation.resultsLimit = try resultLimit(payload)
        operation.fetchAllChanges = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            var changed: [[String: Any]] = [], deleted: [[String: Any]] = [], purged: [[String: Any]] = []
            operation.recordZoneWithIDChangedBlock = { changed.append(CloudKitCodec.encodeZoneID($0)) }
            operation.recordZoneWithIDWasDeletedBlock = { deleted.append(CloudKitCodec.encodeZoneID($0)) }
            operation.recordZoneWithIDWasPurgedBlock = { purged.append(CloudKitCodec.encodeZoneID($0)) }
            operation.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { purged.append(CloudKitCodec.encodeZoneID($0)) }
            operation.fetchDatabaseChangesResultBlock = { result in
                do {
                    let result = try result.get()
                    continuation.resume(returning: ["changed": changed, "deleted": deleted, "purged": purged, "token": try CloudKitToken.encode(result.serverChangeToken, context: context), "moreComing": result.moreComing])
                } catch { continuation.resume(throwing: error) }
            }
            database.add(operation)
        }
    }

    private func zoneChanges(_ database: CKDatabase, _ payload: [String: Any]) async throws -> Any {
        let zoneID = try CloudKitCodec.zoneID(requiredObject(payload, "zoneId"))
        let context = try CloudKitToken.context(payload, kind: "zone")
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = try CloudKitToken.decode(CKServerChangeToken.self, value: payload["token"], context: context)
        configuration.resultsLimit = try resultLimit(payload)
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            var records: [CKRecord] = [], deleted: [[String: Any]] = []
            var errors: [CKRecord.ID: Error] = [:]
            var zoneError: Error?
            var token: CKServerChangeToken?
            var moreComing = false
            operation.recordWasChangedBlock = { id, result in
                switch result { case .success(let record): records.append(record); case .failure(let error): errors[id] = error }
            }
            operation.recordWithIDWasDeletedBlock = { id, type in deleted.append(["recordId": CloudKitCodec.encodeRecordID(id), "recordType": type]) }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let result): token = result.serverChangeToken; moreComing = result.moreComing
                case .failure(let error): zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                do {
                    try result.get()
                    if let zoneError { throw zoneError }
                    if !errors.isEmpty { throw partialError(errors) }
                    continuation.resume(returning: ["records": try records.map(CloudKitCodec.encodeRecord), "deleted": deleted, "token": try CloudKitToken.encode(token, context: context), "moreComing": moreComing])
                } catch { continuation.resume(throwing: error) }
            }
            database.add(operation)
        }
    }
}

private func objects(_ payload: [String: Any], _ key: String) throws -> [[String: Any]] {
    guard let values = payload[key] as? [[String: Any]] else { throw NativeError(code: "invalidArgument", message: "Expected array \(key)") }
    return values
}
private func resultLimit(_ payload: [String: Any]) throws -> Int {
    guard let limit = payload["limit"] as? Int, (1...200).contains(limit) else { throw NativeError(code: "invalidArgument", message: "limit must be between 1 and 200") }
    return limit
}
private func failures<T>(_ results: [CKRecord.ID: Result<T, Error>]) -> [CKRecord.ID: Error] {
    results.reduce(into: [:]) { errors, item in if case .failure(let error) = item.value { errors[item.key] = error } }
}
private func rejectPartial<T>(_ results: [CKRecord.ID: Result<T, Error>]) throws {
    let errors = failures(results)
    if !errors.isEmpty { throw partialError(errors) }
}
private func partialError(_ errors: [CKRecord.ID: Error]) -> NSError {
    NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue, userInfo: [NSLocalizedDescriptionKey: "Some CloudKit items failed", CKPartialErrorsByItemIDKey: errors])
}
