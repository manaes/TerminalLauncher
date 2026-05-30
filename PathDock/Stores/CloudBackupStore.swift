//
//  CloudBackupStore.swift
//  PathDock
//
//  iCloud 백업/복원을 조율하는 코디네이터.
//  - 백업 비밀번호는 SecurityStore 를 통해 Keychain 에 보관 → 원탭 백업/복원.
//  - 백업 파일은 ExportService 의 `.pathdock` 포맷(AES-GCM)이며 iCloud 에는 암호화된 바이트만 올라간다.
//  - 무거운 작업(KDF/암호화/iCloud IO)은 백그라운드에서 수행하고, manifest 구성과 store 반영만 메인 액터에서 한다.
//  - EntryStore 변경을 관찰해 디바운스(5초) 자동 백업을 수행한다 (prefs 로 on/off).
//

import Foundation
import Combine

@MainActor
final class CloudBackupStore: ObservableObject {

    /// iCloud(컨테이너) 접근 가능 여부
    @Published private(set) var available: Bool = false
    /// 백업/복원 진행 중 여부
    @Published private(set) var isBusy: Bool = false
    /// 마지막 백업 시각 (iCloud 파일 수정 시각 기준)
    @Published private(set) var lastBackupAt: Date?
    /// 마지막 동작 결과/오류 메시지
    @Published private(set) var statusMessage: String?

    private let store: EntryStore
    private let security: SecurityStore
    private let prefs: PreferencesStore

    /// 변경 관찰 구독
    private var cancellable: AnyCancellable?
    /// 자동 백업 디바운스 Task
    private var autoBackupTask: Task<Void, Never>?
    /// 자동 백업 디바운스 간격
    private let autoBackupDebounce: UInt64 = 5_000_000_000  // 5초
    /// 백업 진행 중 자동 백업 요청이 들어오면 보류했다가 완료 후 1회 재시도 (마지막 변경 유실 방지)
    private var pendingAutoBackup = false
    /// 복원 적용 중 자동 백업 억제 (방금 복원한 데이터를 곧바로 재업로드하지 않도록)
    private var suppressAutoBackup = false

    init(store: EntryStore, security: SecurityStore, prefs: PreferencesStore) {
        self.store = store
        self.security = security
        self.prefs = prefs
        refreshAvailability()
        observeChangesForAutoBackup()
    }

    // MARK: - 가용성

    /// iCloud 접근 가능 여부와 마지막 백업 시각을 백그라운드에서 갱신한다.
    func refreshAvailability() {
        Task { [weak self] in
            let info = await Task.detached(priority: .utility) {
                (available: CloudBackupService.isAvailable(), backup: CloudBackupService.backupInfo())
            }.value
            guard let self = self else { return }
            self.available = info.available
            // 백업이 없거나 iCloud 가 불가하면 stale 한 날짜를 남기지 않는다.
            self.lastBackupAt = info.backup.exists ? info.backup.modifiedAt : nil
        }
    }

    // MARK: - 설정 (백업 비밀번호)

    /// 백업 비밀번호를 Keychain 에 저장하고 iCloud 백업을 활성화한 뒤 즉시 1회 백업한다.
    func enableBackup(password: String) {
        security.storeBackupPassword(password)
        prefs.prefs.icloudBackupEnabled = true
        backupNow()
    }

    /// iCloud 백업을 해제한다. (백업 비밀번호 제거 + 토글 off. iCloud 의 백업 파일은 남겨둔다)
    func disableBackup() {
        security.deleteBackupPassword()
        prefs.prefs.icloudBackupEnabled = false
        autoBackupTask?.cancel()
        pendingAutoBackup = false
        lastBackupAt = nil
        statusMessage = "iCloud 백업을 해제했습니다."
    }

    // MARK: - 백업

    /// 지금 즉시 백업한다. (수동 버튼 / 자동 백업 공통 경로)
    func backupNow() {
        guard prefs.prefs.icloudBackupEnabled, let pw = security.loadBackupPassword() else {
            statusMessage = "iCloud 백업이 설정되어 있지 않습니다."
            return
        }
        // 이미 진행 중이면 보류 플래그만 세우고 완료 후 재시도하게 한다.
        guard !isBusy else { pendingAutoBackup = true; return }
        isBusy = true
        statusMessage = nil

        // 첨부 복호화/인코딩까지 백그라운드에서 수행하기 위해 entries 스냅샷과 attachmentStore 를 메인에서 캡처.
        let entries = store.entries
        let attachmentStore = store.attachmentStore

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // manifest 구성(첨부 복호화 포함) + 봉인(KDF/암호화) + iCloud 기록 — 전부 백그라운드
                try await Task.detached(priority: .utility) {
                    let plaintext = try ExportService.buildManifest(entries: entries, attachmentStore: attachmentStore)
                    let sealed = try ExportService.sealManifest(plaintext: plaintext, password: pw)
                    try CloudBackupService.writeBackup(data: sealed)
                }.value
                let info = await Task.detached(priority: .utility) { CloudBackupService.backupInfo() }.value
                self.lastBackupAt = info.modifiedAt ?? Date()
                self.statusMessage = "iCloud 백업 완료"
            } catch {
                self.statusMessage = "백업 실패: \(error.localizedDescription)"
            }
            self.isBusy = false
            // 백업 중 들어온 자동 백업 요청이 있으면 1회 재시도 (마지막 변경 유실 방지)
            if self.pendingAutoBackup {
                self.pendingAutoBackup = false
                self.requestAutoBackup()
            }
        }
    }

    /// 자동 백업 요청 — 진행 중이면 보류 플래그만, 아니면 즉시 백업. (억제 중에는 무시)
    private func requestAutoBackup() {
        guard prefs.prefs.icloudBackupEnabled, prefs.prefs.icloudAutoBackup, !suppressAutoBackup else { return }
        if isBusy {
            pendingAutoBackup = true
            return
        }
        backupNow()
    }

    // MARK: - 복원

    /// iCloud 의 백업을 읽어 store 에 반영한다.
    /// - parameter mode: 덮어쓰기(.replace) 또는 병합(.merge)
    func restore(mode: ImportMode) {
        guard prefs.prefs.icloudBackupEnabled, let pw = security.loadBackupPassword() else {
            statusMessage = "iCloud 백업이 설정되어 있지 않습니다."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // 1) iCloud 읽기 + 복호화/디코드 — 백그라운드
                let manifest = try await Task.detached(priority: .userInitiated) { () throws -> ExportManifest in
                    let data = try CloudBackupService.readBackup()
                    return try ImportService.decodeManifest(fileData: data, password: pw)
                }.value
                // 2) store 반영 — 메인 액터. 적용 중 발생하는 entries 변경이 자동 백업을 유발하지 않도록 억제
                //    (방금 복원한 데이터를 곧바로 다시 업로드하는 피드백 루프 방지).
                self.suppressAutoBackup = true
                ImportService.apply(manifest, into: self.store, mode: mode)
                self.suppressAutoBackup = false
                self.statusMessage = mode == .replace ? "복원 완료 (덮어쓰기)" : "복원 완료 (병합)"
            } catch {
                self.statusMessage = "복원 실패: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    // MARK: - 자동 백업

    /// EntryStore 의 변경을 관찰해 디바운스 자동 백업을 예약한다.
    private func observeChangesForAutoBackup() {
        cancellable = store.$entries
            .dropFirst()  // 구독 시점의 초기값은 무시
            .sink { [weak self] _ in
                self?.scheduleAutoBackup()
            }
    }

    /// 변경 후 일정 시간 뒤 자동 백업. 연속 변경은 마지막 1회로 합쳐진다.
    private func scheduleAutoBackup() {
        guard prefs.prefs.icloudBackupEnabled, prefs.prefs.icloudAutoBackup, !suppressAutoBackup else { return }
        autoBackupTask?.cancel()
        autoBackupTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: self.autoBackupDebounce)
            if Task.isCancelled { return }
            self.requestAutoBackup()
        }
    }
}
