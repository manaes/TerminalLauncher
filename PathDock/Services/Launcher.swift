//
//  Launcher.swift
//  PathDock
//
//  터미널 백엔드(Terminal.app / iTerm2)를 추상화하는 Launcher 프로토콜과
//  공용 헬퍼(iTerm2 설치 검출)를 정의한다.
//

import Foundation
import AppKit

/// 백엔드별로 구현되는 터미널 런처 추상화.
/// - Terminal.app 백엔드는 세션 추적을 지원하지 않으므로 isAlive/activate/terminate 는 의미가 없다.
protocol Launcher {
    /// 새 세션을 띄운다.
    /// - returns: iTerm2 백엔드는 ITermSession 을, Terminal.app 백엔드는 nil 을 반환한다.
    @MainActor
    func launch(_ entry: PathEntry, attachmentStore: AttachmentStore, prefs: Preferences) throws -> ITermSession?

    /// 세션이 살아있는지 확인 (Terminal.app 백엔드는 항상 false).
    /// - note: 단건 정확 검사용. 폴링/렌더에는 aliveSessionIds() 의 일괄 결과를 캐시해 쓰는 것을 권장.
    @MainActor
    func isAlive(_ session: ITermSession) -> Bool

    /// 현재 살아있는 모든 세션의 sessionId 를 한 번의 호출로 수집한다.
    /// 폴링/리스트 인디케이터에서 세션마다 isAlive 를 호출하지 않도록 일괄 조회를 제공한다.
    /// Terminal.app 백엔드는 세션 추적을 안 하므로 빈 집합.
    @MainActor
    func aliveSessionIds() -> Set<String>

    /// 살아있는 세션을 앞으로 가져온다 (Terminal.app 백엔드는 throw).
    @MainActor
    func activate(_ session: ITermSession) throws

    /// 세션 강제 종료 (Terminal.app 백엔드는 throw).
    @MainActor
    func terminate(_ session: ITermSession) throws
}

/// 백엔드 공용 유틸
enum LauncherUtil {
    /// iTerm2 설치 여부.
    /// - LSCopyApplicationURLsForBundleIdentifier 로 "com.googlecode.iterm2" 의 URL 을 조회한다.
    static func isITermInstalled() -> Bool {
        // NSWorkspace 의 publicly stable API 로 bundle id 조회
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            return true
        }
        return false
    }
}
