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
///   (iCloud 백업 비밀번호는 Keychain 에 저장하며 여기에는 토글만 둔다.)
struct Preferences: Codable {
    /// 더블클릭/실행 시 사용할 터미널 백엔드
    var terminalBackend: TerminalBackend = .terminal
    /// iTerm2 + SSH password 모드일 때 자동 입력 사용 여부
    var itermAutoTypePassword: Bool = true
    /// iTerm2 SSH 패스워드 자동 입력 시 ssh 프롬프트가 뜨길 기다리는 시간(초).
    /// 너무 짧으면 프롬프트보다 먼저 입력돼 누락/노출될 수 있어 사용자가 조정할 수 있게 한다.
    var itermAutoTypeDelaySeconds: Double = 2.0
    /// iCloud 백업 사용 여부. 백업 비밀번호를 Keychain 에 설정하면 true 가 된다.
    var icloudBackupEnabled: Bool = false
    /// 데이터 변경 시 iCloud 자동 백업 여부 (icloudBackupEnabled == true 일 때만 의미)
    var icloudAutoBackup: Bool = true

    /// 기본값
    static let `default` = Preferences()

    init(
        terminalBackend: TerminalBackend = .terminal,
        itermAutoTypePassword: Bool = true,
        itermAutoTypeDelaySeconds: Double = 2.0,
        icloudBackupEnabled: Bool = false,
        icloudAutoBackup: Bool = true
    ) {
        self.terminalBackend = terminalBackend
        self.itermAutoTypePassword = itermAutoTypePassword
        self.itermAutoTypeDelaySeconds = itermAutoTypeDelaySeconds
        self.icloudBackupEnabled = icloudBackupEnabled
        self.icloudAutoBackup = icloudAutoBackup
    }

    // MARK: - Codable (forward/backward compat)
    // 새 필드를 추가해도 구버전 preferences.json 디코드가 실패하지 않도록 누락 키는 기본값으로 채운다.

    private enum CodingKeys: String, CodingKey {
        case terminalBackend, itermAutoTypePassword, itermAutoTypeDelaySeconds
        case icloudBackupEnabled, icloudAutoBackup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.terminalBackend = (try? c.decode(TerminalBackend.self, forKey: .terminalBackend)) ?? .terminal
        self.itermAutoTypePassword = (try? c.decode(Bool.self, forKey: .itermAutoTypePassword)) ?? true
        self.itermAutoTypeDelaySeconds = (try? c.decode(Double.self, forKey: .itermAutoTypeDelaySeconds)) ?? 2.0
        self.icloudBackupEnabled = (try? c.decode(Bool.self, forKey: .icloudBackupEnabled)) ?? false
        self.icloudAutoBackup = (try? c.decode(Bool.self, forKey: .icloudAutoBackup)) ?? true
    }
}
