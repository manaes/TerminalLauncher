//
//  SettingsView.swift
//  PathDock
//
//  설정 메뉴 — 보안 상태 표시, 비밀번호 초기화, Export/Import.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var security: SecurityStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var preferencesStore: PreferencesStore
    @EnvironmentObject private var cloudBackup: CloudBackupStore

    /// 전체 초기화 확인 다이얼로그 표시 여부
    @State private var showResetConfirm = false
    /// Export 비밀번호 시트 표시 여부
    @State private var showExportPasswordSheet = false
    /// Import 비밀번호 시트 표시 여부 (선택된 파일과 함께 보관)
    @State private var pendingImportURL: URL?
    /// 결과 알림 (성공/실패)
    @State private var resultMessage: String?
    /// iTerm2 미설치 알럿 표시 여부
    @State private var showITermMissingAlert = false
    /// iCloud 백업 비밀번호 설정 시트 표시 여부
    @State private var showBackupPasswordSheet = false
    /// iCloud 복원 모드 선택 다이얼로그 표시 여부
    @State private var showRestoreDialog = false

    var body: some View {
        Form {
            Section("보안") {
                HStack {
                    Text("현재 모드")
                    Spacer()
                    Text(modeText)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Text("비밀번호 초기화…")
                }
                .help("모든 데이터를 삭제하고 첫 실행 화면으로 돌아갑니다.")
            }

            Section("터미널") {
                // 사용자 백엔드 선택. iTerm2 변경 시 설치 검증 + 매핑 폐기.
                Picker("백엔드", selection: backendBinding) {
                    ForEach(TerminalBackend.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                if preferencesStore.prefs.terminalBackend == .iterm2 && !LauncherUtil.isITermInstalled() {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("iTerm2 가 설치되어 있지 않습니다.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("설치하기") {
                            if let url = URL(string: "https://iterm2.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            // iTerm2 백엔드 전용 옵션 섹션
            if preferencesStore.prefs.terminalBackend == .iterm2 {
                Section("iTerm2") {
                    Toggle("SSH 패스워드 자동 입력", isOn: $preferencesStore.prefs.itermAutoTypePassword)
                    if preferencesStore.prefs.itermAutoTypePassword {
                        Stepper(
                            value: $preferencesStore.prefs.itermAutoTypeDelaySeconds,
                            in: 0.5...10.0,
                            step: 0.5
                        ) {
                            HStack {
                                Text("프롬프트 대기 시간")
                                Spacer()
                                Text(String(format: "%.1f초", preferencesStore.prefs.itermAutoTypeDelaySeconds))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("ssh 프롬프트가 늦게 뜨거나 호스트 키 확인(yes/no)이 먼저 나오면 값을 늘리세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("데이터") {
                Button("Export…") {
                    showExportPasswordSheet = true
                }
                Button("Import…") {
                    runImportPicker()
                }
            }

            Section("iCloud 백업") {
                if !cloudBackup.available {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.slash")
                            .foregroundStyle(.secondary)
                        Text("iCloud 를 사용할 수 없습니다. iCloud Drive 로그인 / 앱 iCloud 권한을 확인하세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("다시 확인") { cloudBackup.refreshAvailability() }
                            .buttonStyle(.link)
                    }
                } else if !preferencesStore.prefs.icloudBackupEnabled {
                    Text("백업 비밀번호를 설정하면 iCloud 에 암호화된 백업을 올리고 원탭으로 복원할 수 있습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("iCloud 백업 설정…") { showBackupPasswordSheet = true }
                } else {
                    HStack {
                        Text("마지막 백업")
                        Spacer()
                        Text(lastBackupText)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("변경 시 자동 백업", isOn: $preferencesStore.prefs.icloudAutoBackup)
                    Button {
                        cloudBackup.backupNow()
                    } label: {
                        HStack {
                            Text("지금 백업")
                            if cloudBackup.isBusy {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(cloudBackup.isBusy)
                    Button("iCloud 에서 복원…") { showRestoreDialog = true }
                        .disabled(cloudBackup.isBusy)
                    Button("백업 해제", role: .destructive) { cloudBackup.disableBackup() }
                        .disabled(cloudBackup.isBusy)
                }
                if let msg = cloudBackup.statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("정보") {
                HStack {
                    Text("등록된 항목")
                    Spacer()
                    Text("\(store.entries.count)개").foregroundStyle(.secondary)
                }
                HStack {
                    Text("첨부 파일")
                    Spacer()
                    Text("\(totalAttachmentCount)개").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { cloudBackup.refreshAvailability() }
        .sheet(isPresented: $showBackupPasswordSheet) {
            CloudBackupPasswordSheet { password in
                cloudBackup.enableBackup(password: password)
            }
        }
        .confirmationDialog(
            "iCloud 에서 복원",
            isPresented: $showRestoreDialog,
            titleVisibility: .visible
        ) {
            Button("덮어쓰기 (현재 목록 교체)", role: .destructive) {
                cloudBackup.restore(mode: .replace)
            }
            Button("병합 (기존에 추가)") {
                cloudBackup.restore(mode: .merge)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("백업 내용을 어떻게 반영할까요?\n· 덮어쓰기: 현재 모든 항목을 폐기하고 백업으로 교체\n· 병합: 기존 항목을 유지하고 백업 항목을 추가")
        }
        .confirmationDialog(
            "모든 데이터를 삭제합니다.",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("초기화", role: .destructive) {
                security.resetAll()
                // 앱은 다음 진입 시 firstRun 으로 복귀하지만, 사용자가 즉시 첫 실행으로 가도록 처리.
                // 단순한 방법: 종료 후 사용자가 재실행. 여기서는 NotificationCenter 로 PathDockApp 에 알림.
                NotificationCenter.default.post(name: .pathDockSecurityReset, object: nil)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("entries, 첨부, Keychain 마스터키가 모두 삭제됩니다. 복구할 수 없습니다.")
        }
        .sheet(isPresented: $showExportPasswordSheet) {
            ExportPasswordSheet { password in
                runExport(password: password)
            }
        }
        .sheet(item: Binding(
            get: { pendingImportURL.map { ImportTarget(url: $0) } },
            set: { pendingImportURL = $0?.url }
        )) { target in
            ImportPasswordSheet { password in
                runImport(url: target.url, password: password)
            }
        }
        .alert(
            "안내",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            ),
            presenting: resultMessage
        ) { _ in
            Button("확인") { resultMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "iTerm2 가 설치되어 있지 않습니다.",
            isPresented: $showITermMissingAlert
        ) {
            Button("확인", role: .cancel) { }
            Button("설치하기") {
                if let url = URL(string: "https://iterm2.com/") {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: {
            Text("iterm2.com 에서 설치하거나 Terminal 을 선택하세요.")
        }
    }

    /// 백엔드 Picker 의 커스텀 binding.
    /// - iTerm2 선택 + 미설치면 변경 취소 + 알럿 표시
    /// - 백엔드가 실제로 바뀌면 SessionStore 의 매핑을 모두 폐기
    private var backendBinding: Binding<TerminalBackend> {
        Binding(
            get: { preferencesStore.prefs.terminalBackend },
            set: { newValue in
                let current = preferencesStore.prefs.terminalBackend
                if newValue == .iterm2 && !LauncherUtil.isITermInstalled() {
                    // 설치 안 됨 → 변경 막고 알럿
                    showITermMissingAlert = true
                    return
                }
                if newValue != current {
                    preferencesStore.prefs.terminalBackend = newValue
                    // 백엔드 변경 시 기존 세션 매핑은 의미가 없어진다 — 일괄 폐기
                    sessionStore.clearAll()
                }
            }
        )
    }

    // MARK: - 표시 헬퍼

    private var modeText: String {
        guard let cfg = security.config else { return "미설정" }
        switch cfg.mode {
        case .plain: return "평문"
        case .encrypted: return "암호화"
        }
    }

    /// 마지막 iCloud 백업 시각 표시 문자열
    private var lastBackupText: String {
        guard let d = cloudBackup.lastBackupAt else { return "없음" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private var totalAttachmentCount: Int {
        store.entries.reduce(0) { $0 + $1.attachments.count }
    }

    // MARK: - Export

    private func runExport(password: String) {
        let panel = NSSavePanel()
        panel.title = "PathDock 데이터 Export"
        panel.nameFieldStringValue = "PathDock.pathdock"
        panel.allowedContentTypes = [UTType(filenameExtension: "pathdock") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ExportService.export(store: store, password: password, to: url)
            resultMessage = "Export 완료: \(url.path)"
        } catch {
            resultMessage = "Export 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    private func runImportPicker() {
        let panel = NSOpenPanel()
        panel.title = "PathDock 파일 선택"
        panel.allowedContentTypes = [UTType(filenameExtension: "pathdock") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
    }

    private func runImport(url: URL, password: String) {
        do {
            try ImportService.importFile(at: url, password: password, into: store)
            resultMessage = "Import 완료."
        } catch {
            resultMessage = "Import 실패: \(error.localizedDescription)"
        }
    }

    /// .sheet(item:) 용 래퍼
    private struct ImportTarget: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
}

extension Notification.Name {
    /// 비밀번호 초기화 완료 시 PathDockApp 에 phase 를 firstRun 으로 되돌리라고 알림
    static let pathDockSecurityReset = Notification.Name("PathDockSecurityReset")
}
