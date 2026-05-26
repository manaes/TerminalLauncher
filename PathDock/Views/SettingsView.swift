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
                    Toggle("SSH 패스워드 자동 입력 (delay 2초)", isOn: $preferencesStore.prefs.itermAutoTypePassword)
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
