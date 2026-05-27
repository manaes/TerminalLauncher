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
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var preferencesStore: PreferencesStore
    /// 윈도우 활성/백그라운드 추적 — 비활성일 때 폴링 일시정지.
    @Environment(\.scenePhase) private var scenePhase

    /// 편집 시트 모드 (nil 이면 닫힘)
    @State private var editorMode: EditorMode?
    /// 삭제 확인 다이얼로그 대상
    @State private var pendingDelete: PathEntry?
    /// 실행 실패 알림 표시용
    @State private var launchError: IdentifiableError?

    /// 현재 살아있는 iTerm2 세션 id 캐시. 2초 폴링에서 일괄 조회로 1회 갱신한다.
    /// 리스트 인디케이터(isSessionAlive)는 이 캐시만 읽어 AppleScript 호출을 피한다.
    @State private var aliveIds: Set<String> = []
    /// 폴링 타이머 publisher (autoconnect 후 매 2초마다 발화)
    private let pollTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

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
        .onReceive(pollTimer) { _ in
            // 윈도우 비활성 시 폴링 일시정지
            guard scenePhase == .active else { return }
            refreshAliveSessions()
        }
        .onAppear { refreshAliveSessions() }
        .onChange(of: scenePhase) { phase in
            // 다시 활성화되면 즉시 1회 갱신 (2초 기다리지 않도록)
            if phase == .active { refreshAliveSessions() }
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
                // iTerm2 백엔드일 때만 세션 매핑 + isAlive 결과로 인디케이터 표시.
                // Terminal.app 백엔드는 항상 false.
                EntryRow(entry: entry, sessionAlive: isSessionAlive(for: entry))
                    // 더블클릭 시 실행
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        launch(entry)
                    }
                    .contextMenu {
                        Button("편집…") { editorMode = .edit(entry) }
                        Button("실행") { launch(entry) }
                        // iTerm2 백엔드 전용: 항상 새 세션
                        if preferencesStore.prefs.terminalBackend == .iterm2 {
                            Button("새 세션으로 실행") { launchNewSession(entry) }
                        }
                        // 세션이 살아있을 때만 종료 버튼
                        if isSessionAlive(for: entry) {
                            Button("세션 종료") { terminateSession(entry) }
                        }
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

    /// 현재 prefs 기반 런처 인스턴스를 만든다.
    private func makeLauncher() -> Launcher {
        switch preferencesStore.prefs.terminalBackend {
        case .terminal: return TerminalAppLauncher()
        case .iterm2:   return ITermLauncher()
        }
    }

    /// 현재 entry 의 세션이 살아있는지 — aliveIds 캐시만 조회한다 (AppleScript 호출 없음).
    /// 캐시는 refreshAliveSessions() 가 2초마다 / scenePhase 활성 전환 시 갱신한다.
    private func isSessionAlive(for entry: PathEntry) -> Bool {
        guard preferencesStore.prefs.terminalBackend == .iterm2 else { return false }
        guard let s = sessionStore.sessions[entry.id] else { return false }
        return aliveIds.contains(s.sessionId)
    }

    /// 더블클릭/메뉴 "실행" — 살아있는 세션이 있으면 activate, 없으면 새 세션.
    private func launch(_ entry: PathEntry) {
        let launcher = makeLauncher()
        do {
            // 살아있는 세션이 있으면 활성화 우선
            if let s = sessionStore.sessions[entry.id], launcher.isAlive(s) {
                try launcher.activate(s)
                return
            }
            // 새 세션 생성
            let newSession = try launcher.launch(
                entry,
                attachmentStore: store.attachmentStore,
                prefs: preferencesStore.prefs
            )
            if let newSession = newSession {
                sessionStore.set(entryId: entry.id, session: newSession)
            }
        } catch let err as LaunchError {
            launchError = IdentifiableError(message: err.errorDescription ?? "알 수 없는 오류")
        } catch {
            launchError = IdentifiableError(message: error.localizedDescription)
        }
    }

    /// "새 세션으로 실행" — 기존 매핑이 있으면 폐기하고 새 세션을 띄운다.
    private func launchNewSession(_ entry: PathEntry) {
        let launcher = makeLauncher()
        // 기존 매핑은 폐기 (살아있더라도 매핑만 떼고 새 세션을 만든다)
        sessionStore.clear(entryId: entry.id)
        do {
            let newSession = try launcher.launch(
                entry,
                attachmentStore: store.attachmentStore,
                prefs: preferencesStore.prefs
            )
            if let newSession = newSession {
                sessionStore.set(entryId: entry.id, session: newSession)
            }
        } catch let err as LaunchError {
            launchError = IdentifiableError(message: err.errorDescription ?? "알 수 없는 오류")
        } catch {
            launchError = IdentifiableError(message: error.localizedDescription)
        }
    }

    /// "세션 종료" — 매핑된 iTerm2 세션을 close 하고 매핑 폐기.
    private func terminateSession(_ entry: PathEntry) {
        let launcher = makeLauncher()
        guard let s = sessionStore.sessions[entry.id] else { return }
        do {
            try launcher.terminate(s)
        } catch {
            // 이미 죽었거나 백엔드가 지원 안 함 — 어쨌든 매핑은 정리
            NSLog("[PathDock] terminate 실패(무시): %@", String(describing: error))
        }
        sessionStore.clear(entryId: entry.id)
    }

    /// 우측상단 "새 터미널" 버튼 — 등록 항목 없이 빈 창 한 개. 백엔드는 항상 Terminal.app 으로 고정.
    private func openBlankTerminal() {
        do {
            try TerminalLauncher.launchEmptyWindow()
        } catch let err as LaunchError {
            launchError = IdentifiableError(message: err.errorDescription ?? "알 수 없는 오류")
        } catch {
            launchError = IdentifiableError(message: error.localizedDescription)
        }
    }

    /// 살아있는 세션 id 를 일괄 1회 조회해 캐시(aliveIds)를 갱신하고,
    /// 매핑돼 있지만 죽은 세션은 폐기한다. (AppleScript 호출은 세션 수와 무관하게 1회)
    ///
    /// ⚠️ 재진입 방지: NSAppleScript 동기 실행은 내부적으로 이벤트 루프를 돌리므로,
    ///    SwiftUI 뷰 평가/업데이트 콜스택(onAppear, onChange, List diff 등) 도중에
    ///    실행하면 AttributeGraph 가 재진입 precondition 위반으로 abort 한다.
    ///    따라서 실제 AppleScript 호출은 항상 다음 turn(Task @MainActor)에서 수행한다.
    private func refreshAliveSessions() {
        guard preferencesStore.prefs.terminalBackend == .iterm2 else {
            // Terminal 백엔드면 세션 추적 의미 없음 — 캐시만 비운다.
            if !aliveIds.isEmpty { aliveIds = [] }
            return
        }
        // Task 는 현재 동기 실행(뷰 평가/업데이트)을 중단하지 않고 그 이후에 실행되므로
        // 재진입을 막는다. @MainActor 격리로 aliveSessionIds / @State 접근도 컴파일 검증된다.
        Task { @MainActor in
            let ids = makeLauncher().aliveSessionIds()
            aliveIds = ids
            // 매핑돼 있지만 더 이상 살아있지 않은 세션은 폐기
            var deadIds: [UUID] = []
            for (entryId, session) in sessionStore.sessions where !ids.contains(session.sessionId) {
                deadIds.append(entryId)
            }
            for id in deadIds {
                sessionStore.clear(entryId: id)
            }
        }
    }
}

/// alert(item:) 용 래퍼
struct IdentifiableError: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    let tmp = FileManager.default.temporaryDirectory
    return ContentView()
        .environmentObject(EntryStore(
            rootDir: tmp,
            encrypted: false,
            key: nil
        ))
        .environmentObject(SessionStore(
            rootDir: tmp,
            encrypted: false,
            key: nil
        ))
        .environmentObject(PreferencesStore(rootDir: tmp))
}
