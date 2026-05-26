//
//  PathDockApp.swift
//  PathDock
//
//  앱 진입점. 보안 상태머신(firstRun / locked / ready)에 따라 화면을 분기한다.
//

import AppKit
import SwiftUI

/// 앱의 진입 단계
enum AppPhase {
    /// security.plist 가 없음 → 첫 실행 시작 화면
    case firstRun
    /// encrypted 모드인데 Keychain 에 키가 없음 → 잠금 해제 필요
    case locked
    /// EntryStore 로드 가능 상태
    case ready
}

@main
struct PathDockApp: App {
    /// 보안/키 관리. 어느 단계에서나 살아있어야 한다.
    @StateObject private var security = SecurityStore()
    /// 현재 단계
    @State private var phase: AppPhase = .firstRun
    /// ready 단계에서만 살아있는 EntryStore. 단계 전이마다 교체된다.
    @State private var store: EntryStore?
    /// ready 단계에서만 살아있는 SessionStore (iTerm2 세션 매핑)
    @State private var sessionStore: SessionStore?
    /// 환경설정. ready 진입 시 생성. (rootDir 를 알기 위해 SecurityStore 의존)
    @State private var preferencesStore: PreferencesStore?
    /// 잠금 해제 실패 메시지 (UnlockView 에 전달)
    @State private var unlockError: String?
    /// 첫 실행 중 KDF 진행 표시 (활성화 시 spinner)
    @State private var setupWorking = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PathDock") {
            content
                .frame(minWidth: 520, minHeight: 360)
                .onAppear(perform: bootstrap)
                .onReceive(NotificationCenter.default.publisher(for: .pathDockSecurityReset)) { _ in
                    // 비밀번호 초기화 후: 메모리 상의 store 폐기 + firstRun 으로 복귀
                    self.store = nil
                    self.sessionStore = nil
                    self.preferencesStore = nil
                    self.phase = .firstRun
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        // ⌘, 단축키로 자동 연결되는 Settings Scene
        Settings {
            if let store = store, let sessionStore = sessionStore, let preferencesStore = preferencesStore {
                SettingsView()
                    .environmentObject(store)
                    .environmentObject(security)
                    .environmentObject(sessionStore)
                    .environmentObject(preferencesStore)
            } else {
                // ready 진입 전엔 의미 없으므로 빈 화면
                Text("PathDock 이 아직 준비되지 않았습니다.")
                    .padding()
                    .frame(width: 320, height: 120)
            }
        }
    }

    // MARK: - Phase 라우팅

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .firstRun:
            ZStack {
                FirstRunSetupView { enable, password, backend in
                    completeFirstRun(enable: enable, password: password, backend: backend)
                }
                if setupWorking {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    ProgressView("암호 키 생성 중…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .locked:
            UnlockView { password in
                tryUnlock(password: password)
            }
            .alert(
                "잠금 해제 실패",
                isPresented: Binding(
                    get: { unlockError != nil },
                    set: { if !$0 { unlockError = nil } }
                ),
                presenting: unlockError
            ) { _ in
                Button("확인") { unlockError = nil }
            } message: { msg in
                Text(msg)
            }
        case .ready:
            if let store = store, let sessionStore = sessionStore, let preferencesStore = preferencesStore {
                ContentView()
                    .environmentObject(store)
                    .environmentObject(security)
                    .environmentObject(sessionStore)
                    .environmentObject(preferencesStore)
                    .onAppear { appDelegate.store = store }
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - 부트스트랩

    /// onAppear 시 모드/잠금 상태 결정
    private func bootstrap() {
        // 평문 임시 디렉토리 정리는 어차피 ready 진입 직후 시도하면 되지만,
        // firstRun 단계에서는 EntryStore 가 없어 별도 처리.
        guard let cfg = security.config else {
            phase = .firstRun
            return
        }
        switch cfg.mode {
        case .plain:
            enterReady(encrypted: false, key: nil)
        case .encrypted:
            if security.tryAutoUnlock(), let key = security.derivedKey {
                enterReady(encrypted: true, key: key)
            } else {
                phase = .locked
            }
        }
    }

    // MARK: - 첫 실행 완료

    private func completeFirstRun(enable: Bool, password: String, backend: TerminalBackend) {
        if !enable {
            do {
                try security.setupPlain()
                enterReady(encrypted: false, key: nil, initialBackend: backend)
            } catch {
                NSLog("[PathDock] setupPlain 실패: %@", String(describing: error))
            }
            return
        }
        // 암호화 활성화: KDF 가 무거우므로 백그라운드에서 처리
        setupWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try await MainActor.run {
                    try security.setupEncrypted(password: password)
                }
                await MainActor.run {
                    setupWorking = false
                    if let key = security.derivedKey {
                        enterReady(encrypted: true, key: key, initialBackend: backend)
                    } else {
                        phase = .firstRun
                    }
                }
            } catch {
                NSLog("[PathDock] setupEncrypted 실패: %@", String(describing: error))
                await MainActor.run {
                    setupWorking = false
                }
            }
        }
    }

    // MARK: - 잠금 해제

    private func tryUnlock(password: String) {
        Task.detached(priority: .userInitiated) {
            do {
                try await MainActor.run {
                    try security.unlock(password: password)
                }
                await MainActor.run {
                    if let key = security.derivedKey {
                        enterReady(encrypted: true, key: key)
                    }
                }
            } catch let err as SecurityStoreError {
                await MainActor.run {
                    unlockError = err.errorDescription ?? "잠금 해제 실패"
                }
            } catch {
                await MainActor.run {
                    unlockError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - ready 진입

    /// ready 진입을 일반화한 진입점.
    /// - parameter initialBackend: 첫 실행 직후 첫 진입일 때만 의미가 있는 백엔드 초기값.
    ///   nil 이면 디스크에 저장된 preferences.json 을 그대로 사용.
    private func enterReady(encrypted: Bool, key: LockedData?, initialBackend: TerminalBackend? = nil) {
        let s = EntryStore(rootDir: security.rootDir, encrypted: encrypted, key: key)
        // 매 앱 실행 시 1회: 평문 임시 디렉토리 정리
        s.attachmentStore.cleanupDecrypted()
        let sess = SessionStore(rootDir: security.rootDir, encrypted: encrypted, key: key)
        let prefsStore = PreferencesStore(rootDir: security.rootDir)
        // 첫 실행 직후 첫 진입이면 사용자가 선택한 backend 를 prefs 에 반영
        if let initialBackend = initialBackend {
            prefsStore.prefs.terminalBackend = initialBackend
        }
        self.store = s
        self.sessionStore = sess
        self.preferencesStore = prefsStore
        self.phase = .ready
        // ready 진입 시 SessionStore 의 모든 매핑을 백엔드별 launcher 로 검증.
        // dead 매핑은 폐기. (현재 백엔드가 iterm2 일 때만 실질 검사)
        validateSessionsOnReady(prefs: prefsStore.prefs, sessionStore: sess)
    }

    /// SessionStore 의 모든 매핑을 현재 백엔드에 맞는 Launcher.isAlive 로 검증.
    /// dead 인 매핑은 폐기한다.
    @MainActor
    private func validateSessionsOnReady(prefs: Preferences, sessionStore: SessionStore) {
        let launcher: Launcher = prefs.terminalBackend == .terminal
            ? TerminalAppLauncher()
            : ITermLauncher()
        for (entryId, session) in sessionStore.sessions {
            if !launcher.isAlive(session) {
                sessionStore.clear(entryId: entryId)
            }
        }
    }
}

/// 앱 종료(Cmd+Q, 시스템 로그아웃 등) 직전에 EntryStore 의 디바운스 저장을 강제로 flush 한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EntryStore?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.saveNow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
