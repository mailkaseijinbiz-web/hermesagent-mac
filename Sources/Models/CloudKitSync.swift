import Foundation
import CloudKit

/// Minimal CloudKit access. Stage 0 only proves the signing/entitlement chain works
/// (write one record, read it back, delete it). Later stages back the real cross-device
/// sync of employees/teams/tasks and a one-way message mirror.
///
/// Uses the **public** database: its storage counts against the developer's (large, free)
/// CloudKit quota rather than the signed-in user's personal iCloud storage. We switched
/// here because the user's personal iCloud is full and private-DB writes were rejected
/// with `quotaExceeded`. Writing still requires an authenticated iCloud account. Records
/// are tagged with a workspace key (Stage 1) so devices share one logical dataset.
///
/// Container is named neutrally (`iCloud.com.custom.hermes`, not tied to the Mac bundle id)
/// so the iOS app (`com.custom.hermesagent`) can declare the same container later.
enum CloudKitSync {
    static let containerID = "iCloud.com.custom.hermes"

    static var container: CKContainer { CKContainer(identifier: containerID) }
    static var publicDB: CKDatabase { container.publicCloudDatabase }

    enum SyncError: LocalizedError {
        case accountUnavailable(CKAccountStatus)

        var errorDescription: String? {
            switch self {
            case .accountUnavailable(let s):
                switch s {
                case .noAccount:
                    return "この Mac が iCloud にサインインしていません（システム設定 > Apple ID > iCloud）。"
                case .restricted:
                    return "iCloud がプロファイル/ペアレンタルコントロールで制限されています。"
                case .couldNotDetermine:
                    return "iCloud アカウント状態を判定できませんでした。"
                case .temporarilyUnavailable:
                    return "iCloud が一時的に利用できません。少し待って再試行してください。"
                case .available:
                    return "iCloud は利用可能です。"
                @unknown default:
                    return "iCloud アカウントが利用できません。"
                }
            }
        }
    }

    // MARK: - Stage 1: roster sync (employees / teams / tasks)

    /// Shared (cross-device) employee fields only. Device-local fields (avatar,
    /// workspacePath, sessionId) deliberately stay off the cloud.
    struct EmployeeShared: Codable, Sendable {
        var id: String
        var name: String
        var role: String          // EmployeeRole.rawValue
        var provider: String
        var model: String
        var mode: String          // AgentMode.rawValue
        var personaOverride: String?
        var teamId: String?
        var createdAt: Double
        var updatedAt: Double
    }

    /// The whole workspace roster, stored as one CKRecord (`Roster`) per workspace.
    /// `tombstones` maps a deleted id → deletion time, so deletes propagate too.
    struct RosterPayload: Codable, Sendable {
        var employees: [EmployeeShared] = []
        var teams: [Team] = []
        var tasks: [WorkTask] = []
        var tombstones: [String: Double] = [:]
    }

    private static func rosterRecordID(_ workspace: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "roster::\(workspace)")
    }

    /// Fetch the workspace roster by known recordID (no CKQuery → no schema index needed).
    /// Returns nil when no record exists yet.
    static func fetchRoster(workspace: String) async throws -> RosterPayload? {
        let status = try await container.accountStatus()
        guard status == .available else { throw SyncError.accountUnavailable(status) }
        do {
            let rec = try await publicDB.record(for: rosterRecordID(workspace))
            guard let data = rec["payload"] as? Data else { return RosterPayload() }
            return try JSONDecoder().decode(RosterPayload.self, from: data)
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        }
    }

    /// Overwrite the workspace roster record (last-write-wins at the record level;
    /// item-level LWW is resolved by the caller before pushing).
    static func pushRoster(_ payload: RosterPayload, workspace: String) async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw SyncError.accountUnavailable(status) }
        let rec = CKRecord(recordType: "Roster", recordID: rosterRecordID(workspace))
        rec["payload"] = (try JSONEncoder().encode(payload)) as NSData
        rec["updatedAt"] = Date() as CKRecordValue
        _ = try await publicDB.modifyRecords(saving: [rec], deleting: [],
                                             savePolicy: .allKeys, atomically: true)
    }

    // MARK: - Stage 2: one-way message mirror (state.db is CLI-owned / read-only)

    /// Session metadata (no message bodies) — small, lives in one index record per workspace.
    struct SessionMeta: Codable, Sendable {
        var id: String
        var title: String
        var preview: String
        var source: String
        var archived: Bool
        var messageCount: Int
        var lastMessageId: Int64
        var updatedAt: Double
    }

    /// One visible message (mirrored, read-only on other devices).
    struct MessageDTO: Codable, Sendable {
        var id: Int64
        var role: String
        var content: String
        var timestamp: Double
        var tokenCount: Int
    }

    /// Overwrite the per-workspace session index (metadata for every mirrored session).
    static func pushSessionIndex(ws: String, sessions: [SessionMeta]) async throws {
        let rec = CKRecord(recordType: "SessionIndex",
                           recordID: CKRecord.ID(recordName: "sessions::\(ws)"))
        rec["payload"] = (try JSONEncoder().encode(sessions)) as NSData
        rec["updatedAt"] = Date() as CKRecordValue
        _ = try await publicDB.modifyRecords(saving: [rec], deleting: [],
                                             savePolicy: .allKeys, atomically: true)
    }

    /// Read back the session index (for verification / a future cloud-history viewer).
    static func fetchSessionIndex(ws: String) async throws -> [SessionMeta] {
        do {
            let rec = try await publicDB.record(for: CKRecord.ID(recordName: "sessions::\(ws)"))
            guard let d = rec["payload"] as? Data else { return [] }
            return try JSONDecoder().decode([SessionMeta].self, from: d)
        } catch let e as CKError where e.code == .unknownItem {
            return []
        }
    }

    /// Overwrite one session's mirrored messages.
    static func pushSessionLog(ws: String, sessionId: String, messages: [MessageDTO]) async throws {
        let rec = CKRecord(recordType: "SessionLog",
                           recordID: CKRecord.ID(recordName: "session::\(ws)::\(sessionId)"))
        rec["messages"] = (try JSONEncoder().encode(messages)) as NSData
        rec["updatedAt"] = Date() as CKRecordValue
        _ = try await publicDB.modifyRecords(saving: [rec], deleting: [],
                                             savePolicy: .allKeys, atomically: true)
    }

    /// Read back one session's mirrored messages (for a future cloud-history viewer).
    static func fetchSessionLog(ws: String, sessionId: String) async throws -> [MessageDTO] {
        do {
            let rec = try await publicDB.record(for: CKRecord.ID(recordName: "session::\(ws)::\(sessionId)"))
            guard let d = rec["messages"] as? Data else { return [] }
            return try JSONDecoder().decode([MessageDTO].self, from: d)
        } catch let e as CKError where e.code == .unknownItem {
            return []
        }
    }

    /// Write one probe record to the private DB, read it back, then delete it.
    /// Returns a human-readable status string; throws on any failure.
    static func smokeTest() async throws -> String {
        let status = try await container.accountStatus()
        guard status == .available else { throw SyncError.accountUnavailable(status) }

        let id = CKRecord.ID(recordName: "probe-\(UUID().uuidString)")
        let record = CKRecord(recordType: "SyncProbe", recordID: id)
        record["note"] = "stage0 smoke test" as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue

        let saved = try await publicDB.save(record)
        let fetched = try await publicDB.record(for: saved.recordID)
        _ = try? await publicDB.deleteRecord(withID: saved.recordID)   // keep the DB clean

        let note = (fetched["note"] as? String) ?? "?"
        let user = try? await container.userRecordID()
        let who = user.map { " / user \($0.recordName.prefix(8))…" } ?? ""
        return "OK ✓ 書込→読戻し成功（public DB / note=\"\(note)\"\(who)）"
    }
}
