//
//  ImportService.swift
//  PathDock
//
//  `.pathdock` 파일을 복호화하여 현재 마스터키로 재암호화하고, 병합(merge) 또는 덮어쓰기(replace)로 반영한다.
//  새 UUID 재할당, 명령 본문의 첨부 토큰 / SSH 키파일 참조도 새 uuid 로 치환한다.
//  - 복호화/디코드(KDF 포함)는 `decodeManifest` (백그라운드에서 호출 가능, nonisolated)
//  - store 반영은 `apply(_:into:mode:)` (@MainActor)
//

import Foundation

/// 복원/Import 반영 방식.
enum ImportMode {
    /// 기존 항목을 유지하고 새 항목을 이어붙인다.
    case merge
    /// 기존 항목/첨부를 모두 폐기하고 백업 내용으로 교체한다.
    case replace
}

enum ImportError: LocalizedError {
    case ioFailure(String)
    case invalidMagic
    case unsupportedVersion(Int)
    case truncated
    case decryptionFailed
    case manifestDecodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .ioFailure(let msg): return "Import 실패: \(msg)"
        case .invalidMagic: return "올바른 .pathdock 파일이 아닙니다."
        case .unsupportedVersion(let v): return "지원하지 않는 파일 버전입니다. (\(v))"
        case .truncated: return "파일이 손상되었습니다. (길이 부족)"
        case .decryptionFailed: return "복호화에 실패했습니다. 비밀번호를 확인하세요."
        case .manifestDecodeFailed(let msg): return "Manifest 디코드 실패: \(msg)"
        }
    }
}

enum ImportService {

    /// `.pathdock` 파일(바이트)을 비밀번호로 복호화해 Manifest 로 디코드한다.
    /// KDF·복호화를 포함하므로 무거우며, store 에 손대지 않으므로 백그라운드에서 호출해도 된다.
    static func decodeManifest(fileData data: Data, password: String) throws -> ExportManifest {
        // 1) magic + version + salt + nonce 분리
        let headerLen = 8 + 2 + 16 + 12 // = 38
        guard data.count >= headerLen + 16 else {
            throw ImportError.truncated
        }
        let magic = data.prefix(8)
        guard Array(magic) == pathdockMagic else {
            throw ImportError.invalidMagic
        }
        let versionBytes = data[8..<10]
        let version = Int(versionBytes[8]) | (Int(versionBytes[9]) << 8)
        guard version == 1 else {
            throw ImportError.unsupportedVersion(version)
        }
        let salt = Data(data[10..<26])
        let nonce = Data(data[26..<38])
        let ctAndTag = data.suffix(from: 38)
        guard ctAndTag.count >= 16 else { throw ImportError.truncated }
        let ct = Data(ctAndTag.dropLast(16))
        let tag = Data(ctAndTag.suffix(16))

        // 2) KDF → derived key
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: CryptoService.defaultKDFIterations)

        // 3) AES-GCM 복호화
        let plaintext: Data
        do {
            plaintext = try CryptoService.decryptGCMSplit(nonce: nonce, ciphertext: ct, tag: tag, key: key)
        } catch {
            throw ImportError.decryptionFailed
        }

        // 4) Manifest 디코드
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ExportManifest.self, from: plaintext)
        } catch {
            throw ImportError.manifestDecodeFailed(String(describing: error))
        }
    }

    /// 디코드된 Manifest 를 store 에 반영한다.
    /// - mode == .replace 면 기존 항목/첨부를 먼저 모두 폐기한다.
    /// - 모든 첨부는 새 UUID 로 현재 마스터키로 재암호화되며, 명령 토큰과 SSH 키파일 참조(keyAttachmentId)도 remap 된다.
    /// - 항목의 kind 와 원격 필드(host/port/username/auth/password/sshExtraOptions)를 온전히 보존한다.
    @MainActor
    static func apply(_ manifest: ExportManifest, into store: EntryStore, mode: ImportMode) {
        if mode == .replace {
            store.removeAllEntriesAndAttachments()
        }

        // 1) 첨부 id 재할당 매핑
        var idMap: [UUID: UUID] = [:]
        var dataById: [UUID: ExportManifest.ExportAttachment] = [:]
        for att in manifest.attachments {
            idMap[att.id] = UUID()
            dataById[att.id] = att
        }

        // 2) 현재 마스터키로 재암호화하여 attachmentStore 에 기록
        //    한 건 실패하면 idMap 에서 제거해 downstream(메타/토큰/keyAttachmentId) remap 에서 제외한다.
        //    (EntryStore.duplicate 와 동일한 안전 처리 — dangling 참조 방지)
        //    ※ idMap 을 순회 중 변경하면 안 되므로 키 스냅샷으로 순회한다.
        for oldId in Array(idMap.keys) {
            guard let newId = idMap[oldId], let att = dataById[oldId] else { continue }
            do {
                try store.attachmentStore.write(id: newId, plaintext: att.data)
            } catch {
                // 실패한 첨부는 새 id 매핑을 폐기 → keyAttachmentId 는 nil 로, 메타/토큰 remap 에서 제외됨.
                NSLog("[PathDock] import attachment 저장 실패 old=%@ err=%@", oldId.uuidString, String(describing: error))
                idMap[oldId] = nil
            }
        }

        // 3) entries 를 새 id 로 재구성 (kind/원격 필드 보존, 토큰·키파일 참조 remap), store.add 로 append
        for srcEntry in manifest.entries {
            // 첨부 메타 새 id 로 재배열
            var newAtts: [Attachment] = []
            for oldAtt in srcEntry.attachments {
                guard let newId = idMap[oldAtt.id] else { continue }
                newAtts.append(Attachment(
                    id: newId,
                    originalName: oldAtt.originalName,
                    sizeBytes: oldAtt.sizeBytes,
                    addedAt: oldAtt.addedAt
                ))
            }
            // 명령어 본문의 토큰 치환
            let newCommands = srcEntry.commands.map { line -> String in
                var replaced = line
                for (oldId, newId) in idMap {
                    let oldToken = "{{att:\(oldId.uuidString)}}"
                    let newToken = "{{att:\(newId.uuidString)}}"
                    replaced = replaced.replacingOccurrences(of: oldToken, with: newToken)
                }
                return replaced
            }

            let newEntry = PathEntry(
                id: UUID(),
                kind: srcEntry.kind,
                name: srcEntry.name,
                path: srcEntry.path,
                commands: newCommands,
                sortIndex: 0, // store.add 가 재할당
                note: srcEntry.note,
                createdAt: srcEntry.createdAt,
                updatedAt: Date(),
                attachments: newAtts,
                host: srcEntry.host,
                port: srcEntry.port,
                username: srcEntry.username,
                auth: srcEntry.auth,
                password: srcEntry.password,
                keyAttachmentId: srcEntry.keyAttachmentId.flatMap { idMap[$0] },
                sshExtraOptions: srcEntry.sshExtraOptions
            )
            store.add(newEntry)
        }
    }

    /// `.pathdock` 파일을 비밀번호로 복호화하고 store 에 병합한다. (설정 화면의 파일 Import 진입점)
    @MainActor
    static func importFile(at url: URL, password: String, into store: EntryStore) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.ioFailure(String(describing: error))
        }
        let manifest = try decodeManifest(fileData: data, password: password)
        apply(manifest, into: store, mode: .merge)
    }
}
