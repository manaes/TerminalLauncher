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

    /// 전체 초기화 확인 다이얼로그 표시 여부
    @State private var showResetConfirm = false
    /// Export 비밀번호 시트 표시 여부
    @State private var showExportPasswordSheet = false
    /// Import 비밀번호 시트 표시 여부 (선택된 파일과 함께 보관)
    @State private var pendingImportURL: URL?
    /// 결과 알림 (성공/실패)
    @State private var resultMessage: String?

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
