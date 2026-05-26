//
//  TerminalAppLauncher.swift
//  PathDock
//
//  Terminal.app 백엔드 구현체.
//  - 기존 TerminalLauncher / RemoteLauncher 로직을 그대로 위임한다.
//  - 세션 추적은 지원하지 않으며, isAlive 는 항상 false 이고 activate/terminate 는 throw 한다.
//

import Foundation

/// Terminal.app 백엔드 런처.
struct TerminalAppLauncher: Launcher {

    /// 새 터미널 창에서 항목 실행.
    /// - kind 별로 적절한 헬퍼로 위임하며, Terminal.app 은 세션 추적을 안 하므로 nil 반환.
    /// - prefs 는 현재 백엔드에서 사용하지 않지만 프로토콜 시그니처 일관성을 위해 받아둔다.
    @MainActor
    func launch(_ entry: PathEntry, attachmentStore: AttachmentStore, prefs: Preferences) throws -> ITermSession? {
        switch entry.kind {
        case .command:
            try TerminalLauncher.launch(entry, attachmentStore: attachmentStore)
        case .remoteSSH:
            try TerminalLauncher.launchSSH(entry, attachmentStore: attachmentStore)
        case .remoteVNC:
            // VNC 는 NSWorkspace 로 vnc:// URL 을 열기만 한다 — Terminal 과 무관.
            try RemoteLauncher.launchVNC(entry)
        }
        return nil
    }

    @MainActor
    func isAlive(_ session: ITermSession) -> Bool {
        // Terminal.app 백엔드는 세션을 추적하지 않으므로 항상 false.
        return false
    }

    @MainActor
    func activate(_ session: ITermSession) throws {
        throw LaunchError.backendDoesNotSupportSessionTracking
    }

    @MainActor
    func terminate(_ session: ITermSession) throws {
        throw LaunchError.backendDoesNotSupportSessionTracking
    }
}
