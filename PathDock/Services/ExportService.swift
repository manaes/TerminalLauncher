//
//  ExportService.swift
//  PathDock
//
//  현재 데이터를 단일 `.pathdock` 파일로 패키징한다.
//  - 별도 비밀번호로 PBKDF2 → AES-GCM 암호화
//  - 파일 포맷: [magic 8B "PDOCKv1\0"] [version 2B LE = 1] [salt 16B] [nonce 12B] [ciphertext NB] [tag 16B]
//

import Foundation

/// Export 단계 오류
enum ExportError: LocalizedError {
    case ioFailure(String)
    case attachmentReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .ioFailure(let msg): return "Export 실패: \(msg)"
        case .attachmentReadFailed(let msg): return "첨부 읽기 실패: \(msg)"
        }
    }
}

/// `.pathdock` 파일 magic
/// 8 bytes: "PDOCKv1" + 0x00
let pathdockMagic: [UInt8] = [0x50, 0x44, 0x4F, 0x43, 0x4B, 0x76, 0x31, 0x00]

/// Manifest 내부 평문 — entries + 첨부 byte 를 모두 담는다.
struct ExportManifest: Codable {
    /// Manifest 스키마 버전
    let version: Int
    let entries: [PathEntry]
    let attachments: [ExportAttachment]

    struct ExportAttachment: Codable {
        let id: UUID
        let originalName: String
        let sizeBytes: Int64
        /// 원본 평문 바이트 (Codable Data → base64 자동)
        let data: Data
    }
}

enum ExportService {

    /// entries 스냅샷 + attachmentStore 로 Manifest 를 구성해 JSON 평문 바이트로 반환한다.
    /// `attachmentStore.read` 는 nonisolated 이고 entries 는 값 스냅샷이므로 백그라운드에서 호출 가능하다.
    /// (AttachmentStore 는 @MainActor 클래스라 암묵적으로 Sendable — 백그라운드 Task 로 안전하게 넘길 수 있다.)
    nonisolated static func buildManifest(entries: [PathEntry], attachmentStore: AttachmentStore) throws -> Data {
        var exportAtts: [ExportManifest.ExportAttachment] = []
        for entry in entries {
            for att in entry.attachments {
                do {
                    let data = try attachmentStore.read(id: att.id)
                    exportAtts.append(ExportManifest.ExportAttachment(
                        id: att.id,
                        originalName: att.originalName,
                        sizeBytes: att.sizeBytes,
                        data: data
                    ))
                } catch {
                    throw ExportError.attachmentReadFailed(String(describing: error))
                }
            }
        }
        let manifest = ExportManifest(version: 1, entries: entries, attachments: exportAtts)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// store 의 현재 데이터로 Manifest 평문 바이트를 구성한다. (entries 스냅샷을 메인에서 떠서 위임)
    @MainActor
    static func buildManifestPlaintext(store: EntryStore) throws -> Data {
        try buildManifest(entries: store.entries, attachmentStore: store.attachmentStore)
    }

    /// Manifest 평문을 비밀번호로 봉인해 `.pathdock` 바이트로 만든다.
    /// KDF(무거움)·암호화만 수행하므로 store 에 손대지 않으며 백그라운드에서 호출해도 된다.
    static func sealManifest(plaintext: Data, password: String) throws -> Data {
        // KDF → derived key
        let salt = CryptoService.randomBytes(16)
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: CryptoService.defaultKDFIterations)

        // AES-GCM 한 번 암호화
        let parts = try CryptoService.encryptGCMSplit(plaintext: plaintext, key: key)

        // 최종 파일 바이트 작성
        var out = Data()
        out.append(contentsOf: pathdockMagic)
        // version: u16 LE = 1
        out.append(0x01)
        out.append(0x00)
        out.append(salt)
        out.append(parts.nonce)
        out.append(parts.ciphertext)
        out.append(parts.tag)
        return out
    }

    /// store 의 데이터를 비밀번호로 암호화한 `.pathdock` 바이트로 반환한다.
    /// (iCloud 백업 등 파일이 아닌 대상에 쓸 때 사용)
    @MainActor
    static func exportData(store: EntryStore, password: String) throws -> Data {
        let plaintext = try buildManifestPlaintext(store: store)
        return try sealManifest(plaintext: plaintext, password: password)
    }

    /// Export 수행 — 현재 store 의 데이터를 사용자 입력 비밀번호로 암호화하여 outURL 에 쓴다.
    @MainActor
    static func export(store: EntryStore, password: String, to outURL: URL) throws {
        let out = try exportData(store: store, password: password)
        do {
            try out.write(to: outURL, options: [.atomic])
        } catch {
            throw ExportError.ioFailure(String(describing: error))
        }
    }
}
