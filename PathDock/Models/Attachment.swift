//
//  Attachment.swift
//  PathDock
//
//  PathEntry 에 종속된 명령어 첨부 파일 메타데이터.
//  디스크 상의 실제 파일명은 id(UUID) 그대로 사용한다. (확장자 없이 통일)
//

import Foundation

/// 명령어 본문에 `{{att:<uuid>}}` 토큰으로 참조되는 첨부 한 건.
struct Attachment: Codable, Hashable, Identifiable {
    /// 본문 토큰 `{{att:<uuid>}}` 의 uuid 이자 디스크 파일명
    var id: UUID
    /// UI 표시·실행 시 평문 파일에 사용할 원본 이름
    var originalName: String
    /// 바이트 단위 크기 (원본 평문 기준)
    var sizeBytes: Int64
    /// 추가 시각
    var addedAt: Date

    init(
        id: UUID = UUID(),
        originalName: String,
        sizeBytes: Int64,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.originalName = originalName
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
    }
}
