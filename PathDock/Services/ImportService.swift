//
//  ImportService.swift
//  PathDock
//
//  `.pathdock` 파일을 복호화하여 현재 마스터키로 재암호화/병합한다.
//  병합 only — 새 UUID 재할당, sortIndex 이어붙임, 명령 본문의 첨부 토큰도 새 uuid 로 치환.
//

import Foundation

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

    /// `.pathdock` 파일을 비밀번호로 복호화하고 store 에 병합한다.
    @MainActor
    static func importFile(at url: URL, password: String, into store: EntryStore) throws {
        // 1) 파일 로드
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.ioFailure(String(describing: error))
        }

        // 2) magic + version + salt + nonce 분리
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

        // 3) KDF → derived key
        let key = try CryptoService.deriveKey(password: password, salt: salt, iterations: SecurityStore.kdfIterations)

        // 4) AES-GCM 복호화
        let plaintext: Data
        do {
            plaintext = try CryptoService.decryptGCMSplit(nonce: nonce, ciphertext: ct, tag: tag, key: key)
        } catch {
            throw ImportError.decryptionFailed
        }

        // 5) Manifest 디코드
        let manifest: ExportManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ExportManifest.self, from: plaintext)
        } catch {
            throw ImportError.manifestDecodeFailed(String(describing: error))
        }

        // 6) 첨부 id 재할당 매핑
        var idMap: [UUID: UUID] = [:]
        var dataById: [UUID: ExportManifest.ExportAttachment] = [:]
        for att in manifest.attachments {
            idMap[att.id] = UUID()
            dataById[att.id] = att
        }

        // 7) 현재 마스터키로 재암호화하여 attachmentStore 에 기록
        for (oldId, newId) in idMap {
            guard let att = dataById[oldId] else { continue }
            do {
                try store.attachmentStore.write(id: newId, plaintext: att.data)
            } catch {
                // 한 건 실패해도 나머지 import 는 진행. 사용자 정보 손실은 NSLog 로 남김.
                NSLog("[PathDock] import attachment 저장 실패 old=%@ err=%@", oldId.uuidString, String(describing: error))
            }
        }

        // 8) entries 를 새 id 로 재구성하면서 명령어 토큰도 치환, 그리고 store.add 로 append
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
                name: srcEntry.name,
                path: srcEntry.path,
                commands: newCommands,
                sortIndex: 0, // store.add 가 재할당
                note: srcEntry.note,
                createdAt: srcEntry.createdAt,
                updatedAt: Date(),
                attachments: newAtts
            )
            store.add(newEntry)
        }
    }
}
