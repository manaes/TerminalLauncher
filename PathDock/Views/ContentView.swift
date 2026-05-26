//
//  ContentView.swift
//  PathDock
//
//  메인 윈도우. 등록된 경로 리스트와 추가/편집 시트, 컨텍스트 메뉴를 제공한다.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: EntryStore

    /// 편집 시트 모드 (nil 이면 닫힘)
    @State private var editorMode: EditorMode?
    /// 삭제 확인 다이얼로그 대상
    @State private var pendingDelete: PathEntry?
    /// 실행 실패 알림 표시용
    @State private var launchError: IdentifiableError?

    enum EditorMode: Identifiable {
        case new
        case edit(PathEntry)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let e): return "edit-\(e.id.uuidString)"
            }
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorMode = .new
                } label: {
                    Label("추가", systemImage: "plus")
                }
                .help("새 경로 추가")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openBlankTerminal()
                } label: {
                    Label("새 터미널", systemImage: "macwindow.badge.plus")
                }
                .help("빈 Terminal 새 창 열기")
            }
        }
        .sheet(item: $editorMode) { mode in
            switch mode {
            case .new:
                EntryEditorSheet(mode: .new) { newEntry in
                    store.add(newEntry)
                }
            case .edit(let entry):
                EntryEditorSheet(mode: .edit(entry)) { updated in
                    store.update(updated)
                }
            }
        }
        .alert(item: $launchError) { err in
            Alert(
                title: Text("실행 실패"),
                message: Text(err.message),
                dismissButton: .default(Text("확인"))
            )
        }
        .confirmationDialog(
            "이 항목을 삭제하시겠습니까?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("삭제", role: .destructive) {
                store.delete(id: entry.id)
                pendingDelete = nil
            }
            Button("취소", role: .cancel) {
                pendingDelete = nil
            }
        } message: { entry in
            Text("\"\(entry.name)\" 을(를) 영구적으로 제거합니다.")
        }
    }

    // MARK: - Sub Views

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("등록된 경로가 없습니다")
                .font(.title3)
            Text("우측 상단의 + 버튼으로 자주 사용하는 경로를 추가하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        List {
            ForEach(store.entries) { entry in
                EntryRow(entry: entry)
                    // 더블클릭 시 실행
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        launch(entry)
                    }
                    .contextMenu {
                        Button("편집…") { editorMode = .edit(entry) }
                        Button("실행") { launch(entry) }
                        Button("복제") { store.duplicate(id: entry.id) }
                        Divider()
                        Button("위로") { store.moveUp(id: entry.id) }
                        Button("아래로") { store.moveDown(id: entry.id) }
                        Divider()
                        Button("삭제…", role: .destructive) {
                            pendingDelete = entry
                        }
                    }
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Actions

    private func launch(_ entry: PathEntry) {
        do {
            // entry.kind 에 따라 적절한 런처로 위임
            switch entry.kind {
            case .command:
                try TerminalLauncher.launch(entry, attachmentStore: store.attachmentStore)
            case .remoteSSH:
                try TerminalLauncher.launchSSH(entry, attachmentStore: store.attachmentStore)
            case .remoteVNC:
                try RemoteLauncher.launchVNC(entry)
            }
        } catch let err as LaunchError {
            launchError = IdentifiableError(message: err.errorDescription ?? "알 수 없는 오류")
        } catch {
            launchError = IdentifiableError(message: error.localizedDescription)
        }
    }

    /// 우측상단 "새 터미널" 버튼 — 등록 항목 없이 Terminal 새 창만 띄움
    private func openBlankTerminal() {
        do {
            try TerminalLauncher.launchEmptyWindow()
        } catch let err as LaunchError {
            launchError = IdentifiableError(message: err.errorDescription ?? "알 수 없는 오류")
        } catch {
            launchError = IdentifiableError(message: error.localizedDescription)
        }
    }
}

/// alert(item:) 용 래퍼
struct IdentifiableError: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    ContentView()
        .environmentObject(EntryStore(
            rootDir: FileManager.default.temporaryDirectory,
            encrypted: false,
            key: nil
        ))
}
