//
//  EntryStore.swift
//  PathDock
//
//  PathEntry 목록의 CRUD 와 영속화를 담당한다.
//  - plain 모드: ~/Library/Application Support/PathDock/entries.json (v1 호환 단순 JSON 배열)
//  - encrypted 모드: ~/Library/Application Support/PathDock/entries.enc (AES-GCM, 매 저장마다 nonce 갱신)
//

import Foundation
import SwiftUI

/// encrypted 모드 디스크 포맷 (JSON wrapper)
private struct EncryptedEnvelope: Codable {
    var version: Int
    var nonce: Data
    var tag: Data
    var ciphertext: Data
}

@MainActor
final class EntryStore: ObservableObject {
    /// 현재 표시 중인 항목 목록 (sortIndex 오름차순)
    @Published private(set) var entries: [PathEntry] = []

    /// 데이터 루트 (Application Support/PathDock)
    let rootDir: URL
    /// plain 모드 entries 경로
    let plainURL: URL
    /// encrypted 모드 entries 경로
    let encryptedURL: URL

    /// 현재 모드. true = encrypted, false = plain
    let encrypted: Bool

    /// 암호화 모드일 때 사용하는 마스터키 (plain 이면 nil)
    private let key: LockedData?

    /// 첨부 IO 위임체
    let attachmentStore: AttachmentStore

    private var saveTask: Task<Void, Never>?

    /// SecurityStore 가 결정한 모드와 키를 주입받아 초기화한다.
    init(rootDir: URL, encrypted: Bool, key: LockedData?) {
        self.rootDir = rootDir
        self.plainURL = rootDir.appendingPathComponent("entries.json")
        self.encryptedURL = rootDir.appendingPathComponent("entries.enc")
        self.encrypted = encrypted
        self.key = key
        self.attachmentStore = AttachmentStore(rootDir: rootDir, encrypted: encrypted, key: key)
        load()
    }

    // MARK: - Persistence

    /// 디스크에서 항목을 읽어 entries 에 반영
    func load() {
        let url = encrypted ? encryptedURL : plainURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.entries = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try Data(contentsOf: url)
            let plaintext: Data
            if encrypted {
                // envelope 디코드 후 GCM 복호화
                let env = try decoder.decode(EncryptedEnvelope.self, from: raw)
                guard let key = key else {
                    NSLog("[PathDock] entries.enc 로드 실패: 키 없음")
                    self.entries = []
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
            let decoded = try decoder.decode([PathEntry].self, from: plaintext)
            self.entries = decoded.sorted { $0.sortIndex < $1.sortIndex }
        } catch {
            NSLog("[PathDock] entries 로드 실패: %@", String(describing: error))
            self.entries = []
        }
    }

    /// 디스크에 즉시 저장
    func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(entries)
            if encrypted {
                guard let key = key else {
                    NSLog("[PathDock] entries.enc 저장 실패: 키 없음")
                    return
                }
                let parts = try CryptoService.encryptGCMSplit(plaintext: plaintext, key: key)
                let env = EncryptedEnvelope(
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
            NSLog("[PathDock] entries 저장 실패: %@", String(describing: error))
        }
    }

    /// 300ms 디바운스 저장 (빠른 편집 시 race 방지)
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.saveNow()
            }
        }
    }

    // MARK: - CRUD

    func add(_ entry: PathEntry) {
        var newEntry = entry
        newEntry.sortIndex = entries.count
        newEntry.updatedAt = Date()
        entries.append(newEntry)
        scheduleSave()
    }

    func update(_ entry: PathEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entry
        updated.updatedAt = Date()
        // sortIndex 는 기존 값을 유지
        updated.sortIndex = entries[idx].sortIndex
        entries[idx] = updated
        scheduleSave()
    }

    func delete(id: UUID) {
        // 항목 삭제 시 그 항목의 첨부도 모두 디스크에서 폐기
        if let entry = entries.first(where: { $0.id == id }) {
            for att in entry.attachments {
                attachmentStore.remove(id: att.id)
            }
        }
        entries.removeAll { $0.id == id }
        reindex()
        scheduleSave()
    }

    func delete(ids: Set<UUID>) {
        for id in ids {
            if let entry = entries.first(where: { $0.id == id }) {
                for att in entry.attachments {
                    attachmentStore.remove(id: att.id)
                }
            }
        }
        entries.removeAll { ids.contains($0.id) }
        reindex()
        scheduleSave()
    }

    /// 항목 복제 — 원본 바로 아래에 삽입한다. (첨부는 메타만 복사 X — 새 ID 가 필요해 별도 작업.
    /// 단순화를 위해 첨부 자체는 복사하지 않고 메타 배열만 비운다.)
    func duplicate(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let src = entries[idx]
        let copy = PathEntry(
            id: UUID(),
            name: src.name + " 복사본",
            path: src.path,
            commands: src.commands,
            sortIndex: idx + 1,
            note: src.note,
            createdAt: Date(),
            updatedAt: Date(),
            attachments: [] // 첨부는 복제하지 않음
        )
        entries.insert(copy, at: idx + 1)
        reindex()
        scheduleSave()
    }

    /// SwiftUI List 의 .onMove 와 직접 연결
    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        reindex()
        scheduleSave()
    }

    /// 한 칸 위로 이동
    func moveUp(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        entries.swapAt(idx, idx - 1)
        reindex()
        scheduleSave()
    }

    /// 한 칸 아래로 이동
    func moveDown(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), idx < entries.count - 1 else { return }
        entries.swapAt(idx, idx + 1)
        reindex()
        scheduleSave()
    }

    /// sortIndex 를 0..n-1 로 재할당
    private func reindex() {
        for i in entries.indices {
            entries[i].sortIndex = i
        }
    }

    // MARK: - Attachment CRUD 헬퍼

    /// 평문 byte 를 첨부로 저장하고 entry 메타에 push.
    /// - returns: 새로 생성된 Attachment (id 는 디스크 파일명과 일치)
    @discardableResult
    func addAttachment(to entryId: UUID, payload: Data, originalName: String, sizeBytes: Int64) throws -> Attachment {
        let att = Attachment(originalName: originalName, sizeBytes: sizeBytes)
        try attachmentStore.write(id: att.id, plaintext: payload)
        if let idx = entries.firstIndex(where: { $0.id == entryId }) {
            entries[idx].attachments.append(att)
            entries[idx].updatedAt = Date()
            scheduleSave()
        }
        return att
    }

    /// 첨부 제거: 디스크 파일 + 메타 + 명령어 본문의 토큰 자동 제거
    func removeAttachment(entryId: UUID, attId: UUID) {
        attachmentStore.remove(id: attId)
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].attachments.removeAll { $0.id == attId }
        // 본문 토큰 제거
        let token = "{{att:\(attId.uuidString)}}"
        entries[idx].commands = entries[idx].commands.map { line in
            line.replacingOccurrences(of: token, with: "")
        }
        entries[idx].updatedAt = Date()
        scheduleSave()
    }
}
