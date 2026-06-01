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
        ScrollView {
            // 카드 그리드 — 폭에 따라 1~3 컬럼으로 자동 적응 (카드 최소 폭 280).
            // GridItem alignment: .top → 같은 행 안의 카드들이 가장 큰 카드 높이로 늘어나고,
            //   짧은 카드는 상단 정렬로 위로 붙는다.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                terminalCard
                if preferencesStore.prefs.terminalBackend == .iterm2 {
                    itermCard
                }
                iCloudCard
                dataCard
                infoCard
                dangerCard
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 460, idealWidth: 720, maxWidth: .infinity,
            minHeight: 360, idealHeight: 560, maxHeight: .infinity
        )
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

    // MARK: - 카드들

    /// 터미널 백엔드 선택 카드
    private var terminalCard: some View {
        SettingsCard(title: "터미널", systemImage: "terminal", tint: .accentColor) {
            Picker("백엔드", selection: backendBinding) {
                ForEach(TerminalBackend.allCases) { b in
                    Text(b.rawValue).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if preferencesStore.prefs.terminalBackend == .iterm2 && !LauncherUtil.isITermInstalled() {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("iTerm2 가 설치되어 있지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("설치하기") {
                        if let url = URL(string: "https://iterm2.com/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    /// iTerm2 자동 입력 옵션 카드 (백엔드가 iTerm2 일 때만)
    private var itermCard: some View {
        SettingsCard(title: "iTerm2", systemImage: "macwindow", tint: .indigo) {
            Toggle("SSH 패스워드 자동 입력", isOn: $preferencesStore.prefs.itermAutoTypePassword)
            if preferencesStore.prefs.itermAutoTypePassword {
                Stepper(
                    value: $preferencesStore.prefs.itermAutoTypeDelaySeconds,
                    in: 0.5...10.0,
                    step: 0.5
                ) {
                    HStack {
                        Text("프롬프트 대기")
                        Spacer()
                        Text(String(format: "%.1f초", preferencesStore.prefs.itermAutoTypeDelaySeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("ssh 프롬프트가 늦게 뜨거나 호스트 키 확인(yes/no)이 먼저 나오면 값을 늘리세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// iCloud 백업 카드 — 가용/미설정/설정완료 3가지 상태. 자연 높이로 컴팩트하게.
    private var iCloudCard: some View {
        SettingsCard(title: "iCloud 백업", systemImage: "icloud", tint: .blue) {
            if !cloudBackup.available {
                Label("iCloud 를 사용할 수 없습니다.", systemImage: "icloud.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("iCloud Drive 로그인 / 앱 iCloud 권한을 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                CardActionButton(
                    title: "다시 확인",
                    systemImage: "arrow.clockwise",
                    tint: .blue
                ) {
                    cloudBackup.refreshAvailability()
                }
            } else if !preferencesStore.prefs.icloudBackupEnabled {
                Text("백업 비밀번호를 설정하면 iCloud 에 암호화된 백업을 올리고 원탭으로 복원할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CardActionButton(
                    title: "iCloud 백업 설정…",
                    systemImage: "icloud.and.arrow.up",
                    tint: .blue
                ) {
                    showBackupPasswordSheet = true
                }
            } else {
                infoRow(label: "마지막 백업", value: lastBackupText)
                Toggle("변경 시 자동 백업", isOn: $preferencesStore.prefs.icloudAutoBackup)
                    .toggleStyle(.switch)
                HStack(spacing: 8) {
                    CardActionButton(
                        title: cloudBackup.isBusy ? "백업 중…" : "지금 백업",
                        systemImage: "icloud.and.arrow.up",
                        tint: .blue
                    ) {
                        cloudBackup.backupNow()
                    }
                    .disabled(cloudBackup.isBusy)
                    CardActionButton(
                        title: "복원…",
                        systemImage: "icloud.and.arrow.down",
                        tint: .blue
                    ) {
                        showRestoreDialog = true
                    }
                    .disabled(cloudBackup.isBusy)
                }
                CardActionButton(
                    title: "백업 해제",
                    systemImage: "xmark.circle",
                    tint: .gray,
                    role: .destructive
                ) {
                    cloudBackup.disableBackup()
                }
                .disabled(cloudBackup.isBusy)
            }
            if let msg = cloudBackup.statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Export / Import 카드 — 가로 2버튼으로 컴팩트
    private var dataCard: some View {
        SettingsCard(title: "데이터", systemImage: "square.and.arrow.up.on.square", tint: .green) {
            Text("암호화된 `.pathdock` 단일 파일로 내보내고/가져옵니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                CardActionButton(
                    title: "Export…",
                    systemImage: "square.and.arrow.up",
                    tint: .green
                ) {
                    showExportPasswordSheet = true
                }
                CardActionButton(
                    title: "Import…",
                    systemImage: "square.and.arrow.down",
                    tint: .green
                ) {
                    runImportPicker()
                }
            }
        }
    }

    /// 정보 카드 — 통계만
    private var infoCard: some View {
        SettingsCard(title: "정보", systemImage: "info.circle", tint: .gray) {
            infoRow(label: "현재 모드", value: modeText)
            infoRow(label: "등록된 항목", value: "\(store.entries.count)개")
            infoRow(label: "첨부 파일", value: "\(totalAttachmentCount)개")
            infoRow(label: "터미널 백엔드", value: preferencesStore.prefs.terminalBackend.rawValue)
        }
    }

    /// 위험 영역 — 비밀번호 초기화 (실수 방지 위해 별도 카드)
    private var dangerCard: some View {
        SettingsCard(title: "위험 영역", systemImage: "exclamationmark.triangle", tint: .red) {
            Text("아래 동작은 되돌릴 수 없습니다. 모든 데이터를 삭제하고 첫 실행 화면으로 돌아갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            CardActionButton(
                title: "비밀번호 초기화…",
                systemImage: "trash",
                tint: .red,
                role: .destructive
            ) {
                showResetConfirm = true
            }
            .help("entries, 첨부, Keychain 마스터키가 모두 삭제됩니다.")
        }
    }

    /// 정보 카드 내부 행
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
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

/// 설정 화면의 단일 카드. 헤더(SF Symbol + 제목) + 자유 컨텐츠.
/// 카드 높이는 컨텐츠에 맞춘 자연 높이 — 강제 minHeight 없이 컴팩트하게 둔다.
/// 시각 일관성은 컨텐츠 안의 패딩·spacing·버튼 스타일을 통일해 확보한다.
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.callout.weight(.semibold))
                    .frame(width: 16, height: 16, alignment: .center)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
        .padding(12)
        // 카드가 row 안 가장 큰 카드 높이까지 늘어나도록 maxHeight: .infinity.
        // 컨텐츠는 .topLeading 으로 카드 상단에 붙는다 (가운데 정렬 X).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// 카드 안에서 사용할 액션 버튼 — bordered + 작은 SF Symbol + 라벨, 카드 폭을 가득 채움.
/// 모든 카드의 액션이 시각적으로 동일한 모양/크기를 갖도록 한다.
struct CardActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let role: ButtonRole?
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.regular)
    }
}
