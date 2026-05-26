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

    /// Export 수행 — 현재 store 의 데이터를 사용자 입력 비밀번호로 암호화하여 outURL 에 쓴다.
    @MainActor
    static func export(store: EntryStore, password: String, to outURL: URL) throws {
        // 1) Manifest 구성 — 첨부는 attachmentStore 로 평문 읽기
        var exportAtts: [ExportManifest.ExportAttachment] = []
        for entry in store.entries {
            for att in entry.attachments {
                do {
                    let data = try store.attachmentStore.read(id: att.id)
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
        let manifest = ExportManifest(version: 1, entries: store.entries, attachments: exportAtts)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(manifest)

        // 2) KDF → derived key
        let salt = CryptoService.randomBytes(16)
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: SecurityStore.kdfIterations)

        // 3) AES-GCM 한 번 암호화
        let parts = try CryptoService.encryptGCMSplit(plaintext: plaintext, key: key)

        // 4) 최종 파일 작성
        var out = Data()
        out.append(contentsOf: pathdockMagic)
        // version: u16 LE = 1
        out.append(0x01)
        out.append(0x00)
        out.append(salt)
        out.append(parts.nonce)
        out.append(parts.ciphertext)
        out.append(parts.tag)

        do {
            try out.write(to: outURL, options: [.atomic])
        } catch {
            throw ExportError.ioFailure(String(describing: error))
        }
    }
}
