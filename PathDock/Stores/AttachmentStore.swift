//
//  AttachmentStore.swift
//  PathDock
//
//  첨부 파일의 디스크 IO 와 모드별 (평문/암호화) 분기.
//  저장 위치: ~/Library/Application Support/PathDock/attachments/<uuid>
//   - plain: 원본 byte 그대로
//   - encrypted: nonce(12) || ciphertext || tag(16)
//

import Foundation

/// 첨부 처리 중 발생할 수 있는 오류
enum AttachmentError: LocalizedError {
    /// 파일이 10MB 상한을 초과함
    case tooLarge(actual: Int64, limit: Int64)
    /// 디스크 IO 실패
    case ioFailure(String)
    /// 파일을 읽거나 디스크에 쓸 수 없음
    case notFound(id: UUID)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let actual, let limit):
            let actualMB = Double(actual) / (1024 * 1024)
            let limitMB = Double(limit) / (1024 * 1024)
            return String(format: "파일 크기가 너무 큽니다. (%.1f MB / 상한 %.0f MB)", actualMB, limitMB)
        case .ioFailure(let msg):
            return "첨부 파일 처리 중 오류가 발생했습니다.\n\(msg)"
        case .notFound(let id):
            return "첨부 파일을 찾을 수 없습니다. (id=\(id.uuidString))"
        }
    }
}

/// 첨부 파일 IO 담당. 모드(plain/encrypted)는 SecurityStore 에서 주입받은 정보를 기반으로 분기한다.
@MainActor
final class AttachmentStore {

    /// 단일 첨부 파일 크기 상한 (10MB)
    static let maxBytes: Int64 = 10 * 1024 * 1024

    /// 데이터 루트 (Application Support/PathDock)
    let rootDir: URL
    /// attachments/ 디렉토리
    let attachmentsDir: URL
    /// decrypted/ 디렉토리 (실행 시 평문 풀기용)
    let decryptedDir: URL

    /// 현재 모드 (false = plain, true = encrypted)
    let encrypted: Bool

    /// 암호화 모드일 때 사용하는 마스터키. plain 모드면 nil.
    private let key: LockedData?

    init(rootDir: URL, encrypted: Bool, key: LockedData?) {
        self.rootDir = rootDir
        self.attachmentsDir = rootDir.appendingPathComponent("attachments", isDirectory: true)
        self.decryptedDir = rootDir.appendingPathComponent("decrypted", isDirectory: true)
        self.encrypted = encrypted
        self.key = key

        // 디렉토리 보장
        let fm = FileManager.default
        for url in [attachmentsDir, decryptedDir] {
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - 쓰기

    /// 원본 평문 byte 를 받아 디스크에 저장.
    /// - parameter id: 디스크 파일명으로 사용할 UUID
    /// - parameter plaintext: 원본 바이트
    /// - throws: 10MB 초과 시 `AttachmentError.tooLarge`, 또는 IO/암호화 오류
    func write(id: UUID, plaintext: Data) throws {
        let size = Int64(plaintext.count)
        guard size <= Self.maxBytes else {
            throw AttachmentError.tooLarge(actual: size, limit: Self.maxBytes)
        }
        let url = attachmentsDir.appendingPathComponent(id.uuidString)
        do {
            if encrypted {
                guard let key = key else {
                    throw AttachmentError.ioFailure("암호화 모드인데 마스터키가 비어있습니다.")
                }
                let payload = try CryptoService.encryptGCM(plaintext: plaintext, key: key)
                try payload.write(to: url, options: [.atomic])
            } else {
                try plaintext.write(to: url, options: [.atomic])
            }
        } catch let err as AttachmentError {
            throw err
        } catch {
            throw AttachmentError.ioFailure(String(describing: error))
        }
    }

    // MARK: - 읽기

    /// 디스크에서 평문 byte 를 읽어 반환.
    /// `nonisolated`: 불변 `let`(attachmentsDir/encrypted/key)만 읽고 순수 복호화를 수행하므로
    /// 메인 액터 밖(백그라운드)에서 호출해도 안전하다. (백업 시 첨부 복호화로 UI 가 멈추지 않게 하기 위함)
    nonisolated func read(id: UUID) throws -> Data {
        let url = attachmentsDir.appendingPathComponent(id.uuidString)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentError.notFound(id: id)
        }
        do {
            let raw = try Data(contentsOf: url)
            if encrypted {
                guard let key = key else {
                    throw AttachmentError.ioFailure("암호화 모드인데 마스터키가 비어있습니다.")
                }
                return try CryptoService.decryptGCM(payload: raw, key: key)
            } else {
                return raw
            }
        } catch let err as AttachmentError {
            throw err
        } catch {
            throw AttachmentError.ioFailure(String(describing: error))
        }
    }

    // MARK: - 삭제

    /// 디스크에서 첨부 파일 제거. 존재하지 않아도 throw 하지 않음.
    func remove(id: UUID) {
        let url = attachmentsDir.appendingPathComponent(id.uuidString)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - decrypted/ 정리

    /// 앱 시작 시 1회: decrypted/ 통째 삭제 후 재생성.
    func cleanupDecrypted() {
        let fm = FileManager.default
        try? fm.removeItem(at: decryptedDir)
        try? fm.createDirectory(at: decryptedDir, withIntermediateDirectories: true)
    }
}
