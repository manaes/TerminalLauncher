//
//  CloudBackupService.swift
//  PathDock
//
//  전용 iCloud ubiquity 컨테이너(iCloud.com.wannypark.pathdock)의 Documents 폴더에
//  단일 백업 파일(PathDock-backup.pathdock)을 읽고 쓰는 저수준 서비스.
//
//  - 백업 파일 자체는 ExportService 가 만든 `.pathdock` 포맷(AES-GCM + PBKDF2)이다.
//    즉 iCloud 에는 "암호화된 바이트"만 올라가며, iCloud 계정이 털려도 백업 비밀번호 없이는 열 수 없다.
//  - `FileManager.url(forUbiquityContainerIdentifier:)` 는 느릴 수 있어 메인 스레드에서 호출하면 안 된다.
//    따라서 이 서비스의 모든 함수는 백그라운드(Task.detached 등)에서 호출하는 것을 전제로 한다.
//  - 디스크 IO 는 NSFileCoordinator 로 조율해 iContainer 동기화와의 충돌을 피한다.
//

import Foundation

/// iCloud 백업 단계에서 발생할 수 있는 오류
enum CloudBackupError: LocalizedError {
    /// iCloud(컨테이너)에 접근할 수 없음 — 로그인 안 됨 / iCloud Drive 꺼짐 / 엔타이틀먼트 미설정
    case unavailable
    /// 백업 파일이 아직 없음
    case noBackupFound
    /// 파일 조율/IO 실패
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud 를 사용할 수 없습니다.\n시스템 설정에서 iCloud Drive 로그인을 확인하거나, 앱의 iCloud 권한(capability)이 설정되었는지 확인하세요."
        case .noBackupFound:
            return "iCloud 에 백업 파일이 없습니다."
        case .ioFailure(let msg):
            return "iCloud 파일 처리 중 오류가 발생했습니다.\n\(msg)"
        }
    }
}

/// iCloud ubiquity 컨테이너 백업 IO.
enum CloudBackupService {

    /// ubiquity 컨테이너 식별자. 엔타이틀먼트/Info.plist 의 값과 일치해야 한다.
    static let containerId = "iCloud.com.wannypark.pathdock"
    /// 백업 파일 이름 (단일 캐노니컬 백업 — 매 백업 시 덮어쓴다)
    static let backupFileName = "PathDock-backup.pathdock"

    /// ubiquity 컨테이너의 Documents URL (경로 계산만 — 디렉토리를 만들지 않는다).
    /// iCloud 미사용/미로그인/미설정 시 nil.
    /// - warning: 느릴 수 있으므로 메인 스레드에서 호출하지 말 것.
    static func documentsURL() -> URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerId) else {
            return nil
        }
        return base.appendingPathComponent("Documents", isDirectory: true)
    }

    /// 백업 파일의 URL. iCloud 불가 시 nil.
    static func backupFileURL() -> URL? {
        documentsURL()?.appendingPathComponent(backupFileName)
    }

    /// iCloud 사용 가능 여부 (컨테이너 접근 가능?). 부작용 없는 순수 확인.
    static func isAvailable() -> Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerId) != nil
    }

    /// 백업 데이터(`.pathdock` 바이트)를 iCloud 에 기록한다. (NSFileCoordinator 로 조율)
    static func writeBackup(data: Data) throws {
        guard let docs = documentsURL() else { throw CloudBackupError.unavailable }
        // 쓰기 직전에만 Documents 디렉토리를 보장한다 (가용성 확인 경로엔 부작용을 두지 않음).
        if !FileManager.default.fileExists(atPath: docs.path) {
            do {
                try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            } catch {
                throw CloudBackupError.ioFailure("iCloud Documents 생성 실패: \(String(describing: error))")
            }
        }
        let url = docs.appendingPathComponent(backupFileName)
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let e = writeError ?? coordError {
            throw CloudBackupError.ioFailure(String(describing: e))
        }
    }

    /// iCloud 에서 백업 데이터를 읽는다.
    /// 아직 로컬로 다운로드되지 않은 placeholder 면 다운로드를 트리거하고 잠시 대기한다(최대 ~15초).
    static func readBackup() throws -> Data {
        guard let url = backupFileURL() else { throw CloudBackupError.unavailable }
        let fm = FileManager.default

        // 다운로드 안 된 상태면 트리거 후 폴링
        if !fm.fileExists(atPath: url.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            var waited = 0.0
            let limit = 15.0
            while !fm.fileExists(atPath: url.path) && waited < limit {
                Thread.sleep(forTimeInterval: 0.3)
                waited += 0.3
            }
            guard fm.fileExists(atPath: url.path) else {
                throw CloudBackupError.noBackupFound
            }
        }

        var coordError: NSError?
        var readData: Data?
        var readErr: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                readData = try Data(contentsOf: readURL)
            } catch {
                readErr = error
            }
        }
        if let e = readErr ?? coordError {
            throw CloudBackupError.ioFailure(String(describing: e))
        }
        guard let d = readData else { throw CloudBackupError.noBackupFound }
        return d
    }

    /// 백업 파일 메타데이터. 다운로드 전 placeholder 도 가능한 한 조회한다.
    /// - returns: (존재 여부, 수정 시각, 바이트 크기)
    static func backupInfo() -> (exists: Bool, modifiedAt: Date?, sizeBytes: Int?) {
        guard let url = backupFileURL() else { return (false, nil, nil) }
        let fm = FileManager.default

        // 1) 다운로드된 실제 파일이 있으면 그 속성 사용
        if fm.fileExists(atPath: url.path),
           let attrs = try? fm.attributesOfItem(atPath: url.path) {
            return (true, attrs[.modificationDate] as? Date, (attrs[.size] as? NSNumber)?.intValue)
        }

        // 2) placeholder(.<name>.icloud) 만 있는 경우 — 메타는 URLResourceValues 로 조회 시도
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        if let vals = try? url.resourceValues(forKeys: keys),
           vals.ubiquitousItemDownloadingStatus != nil || vals.fileSize != nil {
            return (true, vals.contentModificationDate, vals.fileSize)
        }

        // 3) placeholder 파일명 직접 확인
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(backupFileName).icloud")
        if fm.fileExists(atPath: placeholder.path),
           let attrs = try? fm.attributesOfItem(atPath: placeholder.path) {
            return (true, attrs[.modificationDate] as? Date, nil)
        }

        return (false, nil, nil)
    }

    /// iCloud 백업 파일을 삭제한다. (백업 해제 시 선택적으로 사용)
    static func deleteBackup() throws {
        guard let url = backupFileURL() else { throw CloudBackupError.unavailable }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        var coordError: NSError?
        var rmError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { rmURL in
            do {
                try fm.removeItem(at: rmURL)
            } catch {
                rmError = error
            }
        }
        if let e = rmError ?? coordError {
            throw CloudBackupError.ioFailure(String(describing: e))
        }
    }
}
