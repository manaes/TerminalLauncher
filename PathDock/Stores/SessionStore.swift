//
//  SessionStore.swift
//  PathDock
//
//  PathEntry.id ↔ ITermSession 매핑의 영속화.
//  - plain 모드: sessions.json
//  - encrypted 모드: sessions.enc (마스터키로 AES-GCM, 매 저장마다 nonce 갱신)
//
//  매 set/clear 마다 즉시 save (변경 빈도 낮음, 디바운스 불필요).
//

import Foundation
import SwiftUI

/// encrypted 모드 디스크 포맷 (EntryStore 와 동일 envelope)
private struct EncryptedSessionEnvelope: Codable {
    var version: Int
    var nonce: Data
    var tag: Data
    var ciphertext: Data
}

@MainActor
final class SessionStore: ObservableObject {
    /// entryId → 세션 매핑. published 로 UI 갱신을 지원한다.
    @Published private(set) var sessions: [UUID: ITermSession] = [:]

    /// 데이터 루트
    let rootDir: URL
    let plainURL: URL
    let encryptedURL: URL

    /// 현재 모드
    let encrypted: Bool
    /// 암호화 모드일 때 사용할 마스터키
    private let key: LockedData?

    init(rootDir: URL, encrypted: Bool, key: LockedData?) {
        self.rootDir = rootDir
        self.plainURL = rootDir.appendingPathComponent("sessions.json")
        self.encryptedURL = rootDir.appendingPathComponent("sessions.enc")
        self.encrypted = encrypted
        self.key = key
        load()
    }

    // MARK: - Persistence

    /// 디스크에서 매핑 로드. 파일 없거나 디코드 실패면 빈 dictionary.
    func load() {
        let url = encrypted ? encryptedURL : plainURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.sessions = [:]
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try Data(contentsOf: url)
            let plaintext: Data
            if encrypted {
                let env = try decoder.decode(EncryptedSessionEnvelope.self, from: raw)
                guard let key = key else {
                    NSLog("[PathDock] sessions.enc 로드 실패: 키 없음")
                    self.sessions = [:]
                    return
                }
                plaintext = try CryptoService.decryptGCMSplit(
                    nonce: env.nonce,
                    ciphertext: env.ciphertext,
                    tag: env.tag,
                    key: key
                )
            } else {
                plaintext = raw
            }
            let decoded = try decoder.decode([UUID: ITermSession].self, from: plaintext)
            self.sessions = decoded
        } catch {
            NSLog("[PathDock] sessions 로드 실패: %@", String(describing: error))
            self.sessions = [:]
        }
    }

    /// 디스크에 즉시 저장. 디바운스 없음.
    private func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(sessions)
            if encrypted {
                guard let key = key else {
                    NSLog("[PathDock] sessions.enc 저장 실패: 키 없음")
                    return
                }
                let parts = try CryptoService.encryptGCMSplit(plaintext: plaintext, key: key)
                let env = EncryptedSessionEnvelope(
                    version: 1,
                    nonce: parts.nonce,
                    tag: parts.tag,
                    ciphertext: parts.ciphertext
                )
                let envEncoder = JSONEncoder()
                envEncoder.outputFormatting = [.sortedKeys]
                let body = try envEncoder.encode(env)
                try body.write(to: encryptedURL, options: [.atomic])
            } else {
                try plaintext.write(to: plainURL, options: [.atomic])
            }
        } catch {
            NSLog("[PathDock] sessions 저장 실패: %@", String(describing: error))
        }
    }

    // MARK: - 헬퍼

    /// 매핑 추가/갱신
    func set(entryId: UUID, session: ITermSession) {
        sessions[entryId] = session
        saveNow()
    }

    /// 단일 매핑 폐기
    func clear(entryId: UUID) {
        if sessions.removeValue(forKey: entryId) != nil {
            saveNow()
        }
    }

    /// 전체 매핑 폐기 (백엔드 변경 등)
    func clearAll() {
        guard !sessions.isEmpty else { return }
        sessions.removeAll()
        saveNow()
    }
}
