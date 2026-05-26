//
//  PathEntry.swift
//  PathDock
//
//  단일 등록 항목을 표현하는 데이터 모델.
//

import Foundation

/// 등록된 작업 디렉토리 한 건을 의미한다.
struct PathEntry: Identifiable, Codable, Hashable {
    /// 고유 식별자
    var id: UUID
    /// 사용자에게 보여줄 별칭 (예: "Example Project")
    var name: String
    /// 절대 경로 또는 ~ 시작 경로
    var path: String
    /// cd 직후 실행할 명령어 줄들. 빈 줄은 무시한다.
    /// 본문 안에 `{{att:<uuid>}}` 토큰을 포함할 수 있으며 실행 직전에 평문 경로로 치환된다.
    var commands: [String]
    /// 리스트 정렬을 위한 인덱스
    var sortIndex: Int
    /// 자유 메모 (옵션)
    var note: String?
    /// 생성 시각
    var createdAt: Date
    /// 마지막 수정 시각
    var updatedAt: Date
    /// 첨부 파일 메타 목록. (v1 JSON 과의 호환을 위해 누락 시 빈 배열로 해석)
    var attachments: [Attachment]

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        commands: [String] = [],
        sortIndex: Int = 0,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.commands = commands
        self.sortIndex = sortIndex
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
    }

    // MARK: - Codable (backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, name, path, commands, sortIndex, note, createdAt, updatedAt, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        self.commands = try c.decode([String].self, forKey: .commands)
        self.sortIndex = try c.decode(Int.self, forKey: .sortIndex)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        // v1 JSON 호환: attachments 키가 없으면 빈 배열
        self.attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
    }
}
