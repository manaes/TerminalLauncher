//
//  Preferences.swift
//  PathDock
//
//  사용자 환경설정. 보안에 민감하지 않은 값만 담는 단순 평문 JSON.
//  저장 위치: ~/Library/Application Support/PathDock/preferences.json
//

import Foundation

/// 터미널 백엔드 선택지
enum TerminalBackend: String, Codable, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm2 = "iTerm2"

    var id: String { rawValue }
}

/// 사용자 환경설정 본체.
/// - 평문 JSON 으로 저장하므로 절대 비밀번호/키 같은 민감값은 넣지 말 것.
struct Preferences: Codable {
    /// 더블클릭/실행 시 사용할 터미널 백엔드
    var terminalBackend: TerminalBackend = .terminal
    /// iTerm2 + SSH password 모드일 때 자동 입력 사용 여부 (delay 2초)
    var itermAutoTypePassword: Bool = true

    /// 기본값
    static let `default` = Preferences()
}
