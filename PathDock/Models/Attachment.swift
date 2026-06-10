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

    /// 평문으로 풀 때 디스크 파일명으로 사용할 안전한 이름.
    /// originalName 은 Import / iCloud 복원 시 외부 `.pathdock` 파일에서 그대로 들어오므로
    /// `../` 같은 경로 성분이 섞여 있으면 decrypted/ 밖으로 벗어날 수 있다.
    /// 마지막 경로 성분만 취하고, 비정상 값(빈 문자열 / "." / "..")이면 id 로 대체한다.
    var safeFileName: String {
        let base = (originalName as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
        if base.isEmpty || base == "." || base == ".." {
            return id.uuidString
        }
        return base
    }
}
