//
//  ITermSession.swift
//  PathDock
//
//  iTerm2 백엔드에서 PathEntry 와 매핑된 단일 세션의 메타데이터.
//  Terminal.app 백엔드는 세션 추적을 하지 않으므로 이 구조체를 만들지 않는다.
//

import Foundation

/// iTerm2 의 (세션, 윈도우) 한 쌍에 대한 메타.
/// - id: 매핑 key. PathEntry 의 id 와 동일하게 두어 SessionStore 의 dictionary key 일관성을 유지.
/// - sessionId / windowId: iTerm2 AppleScript dictionary 가 반환하는 unique id 문자열.
struct ITermSession: Codable, Hashable, Identifiable {
    /// 매핑 식별자 (= PathEntry.id)
    let id: UUID
    /// iTerm2 의 세션 id (`id of current session`)
    let sessionId: String
    /// iTerm2 의 윈도우 id (`id of current window`)
    let windowId: String
    /// 세션 생성 시각
    let startedAt: Date
}
