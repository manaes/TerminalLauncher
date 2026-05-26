//
//  PathEntry.swift
//  PathDock
//
//  단일 등록 항목을 표현하는 데이터 모델.
//  v3: 명령어 타입 외 원격연결(SSH/VNC) 타입을 추가 지원.
//

import Foundation

/// 등록 항목의 종류 — UI/실행 분기의 기준.
enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case command            // 기존 동작 (cd + 명령어 실행)
    case remoteSSH          // ssh 원격 접속
    case remoteVNC          // vnc 원격 접속

    var id: String { rawValue }
}

/// SSH 항목에서 사용할 인증 방식.
enum RemoteAuth: String, Codable {
    case password
    case keyfile           // attachments 중 하나(keyAttachmentId)를 키파일로 사용
}

/// 등록된 작업 디렉토리/원격 한 건을 의미한다.
struct PathEntry: Identifiable, Codable, Hashable {
    /// 고유 식별자
    var id: UUID
    /// 항목 종류 (v2 이하 JSON 에는 없을 수 있어 디코드 시 .command 로 기본 처리)
    var kind: EntryKind
    /// 사용자에게 보여줄 별칭 (예: "Example Project")
    var name: String
    /// 자유 메모 (옵션)
    var note: String?
    /// 리스트 정렬을 위한 인덱스
    var sortIndex: Int
    /// 생성 시각
    var createdAt: Date
    /// 마지막 수정 시각
    var updatedAt: Date

    // MARK: - 명령어 타입 전용 (kind == .command)

    /// 절대 경로 또는 ~ 시작 경로. (원격 타입에서는 비워두는 게 일반적이지만 기본값 "" 로 호환 유지)
    var path: String
    /// cd 직후 실행할 명령어 줄들. 빈 줄은 무시한다.
    /// 본문 안에 `{{att:<uuid>}}` 토큰을 포함할 수 있으며 실행 직전에 평문 경로로 치환된다.
    var commands: [String]
    /// 첨부 파일 메타 목록. (v1 JSON 과의 호환을 위해 누락 시 빈 배열로 해석)
    /// 원격 타입의 SSH 키파일도 동일한 첨부 시스템을 재사용한다.
    var attachments: [Attachment]

    // MARK: - 원격연결 전용 (kind == .remoteSSH / .remoteVNC)

    /// 호스트(IP 또는 도메인)
    var host: String?
    /// 포트 (nil 이면 ssh=22, vnc=5900 기본)
    var port: Int?
    /// 사용자명 (옵션). 비어 있으면 ssh URL/명령에서 생략된다.
    var username: String?
    /// SSH 인증 방식. VNC 는 항상 password 로 간주한다.
    var auth: RemoteAuth?
    /// 패스워드 (SSH password 모드, VNC 둘 다 사용).
    /// 보안: 마스터 비밀번호 모드에서는 entries.enc 안에 함께 암호화되어 저장된다.
    var password: String?
    /// SSH 키파일로 쓸 attachments 의 id. attachments 안에 같은 id 가 존재해야 한다.
    var keyAttachmentId: UUID?
    /// SSH 추가 옵션 라인들. 각 줄은 `Key Value` 형식(ssh config 와 동일).
    /// 실행 시 `-oKey=Value` 인자로 변환되어 ssh 명령에 합성된다.
    /// 예: ["HostKeyAlgorithms +ssh-rsa,ssh-dss", "ServerAliveInterval 30"]
    var sshExtraOptions: [String]?

    init(
        id: UUID = UUID(),
        kind: EntryKind = .command,
        name: String,
        path: String = "",
        commands: [String] = [],
        sortIndex: Int = 0,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attachments: [Attachment] = [],
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        auth: RemoteAuth? = nil,
        password: String? = nil,
        keyAttachmentId: UUID? = nil,
        sshExtraOptions: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.commands = commands
        self.sortIndex = sortIndex
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.password = password
        self.keyAttachmentId = keyAttachmentId
        self.sshExtraOptions = sshExtraOptions
    }

    // MARK: - Codable (backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, path, commands, sortIndex, note, createdAt, updatedAt, attachments
        case host, port, username, auth, password, keyAttachmentId, sshExtraOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // v2 이하 JSON 에 kind 가 없으면 명령어 타입으로 간주
        self.kind = (try? c.decode(EntryKind.self, forKey: .kind)) ?? .command
        self.name = try c.decode(String.self, forKey: .name)
        // path: 원격 타입에서는 누락될 수 있으므로 안전하게 디코드
        self.path = (try? c.decode(String.self, forKey: .path)) ?? ""
        self.commands = (try? c.decode([String].self, forKey: .commands)) ?? []
        self.sortIndex = try c.decode(Int.self, forKey: .sortIndex)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        // v1 JSON 호환: attachments 키가 없으면 빈 배열
        self.attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        // 원격 전용 필드는 명령어 타입 JSON 에 없으므로 모두 optional
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.auth = try c.decodeIfPresent(RemoteAuth.self, forKey: .auth)
        self.password = try c.decodeIfPresent(String.self, forKey: .password)
        self.keyAttachmentId = try c.decodeIfPresent(UUID.self, forKey: .keyAttachmentId)
        self.sshExtraOptions = try c.decodeIfPresent([String].self, forKey: .sshExtraOptions)
    }
}
