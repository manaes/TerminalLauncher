//
//  run_unit_tests.swift
//  PathDock - standalone unit test harness
//
//  Xcode 테스트 타겟을 추가하지 않고도 핵심 순수 로직을
//  회귀 테스트할 수 있도록 작성한 standalone 스크립트.
//
//  실행:
//      swift Tests/run_unit_tests.swift
//  (9_TerminalLauncher 디렉토리에서 실행)
//
//  대상 함수는 PathDock/Services/TerminalLauncher.swift 및
//  PathDock/Stores/EntryStore.swift 의 코드를 그대로 복제(미러)한다.
//  코드를 수정하면 이 파일의 미러도 업데이트해야 한다.
//

import Foundation

// MARK: - Mirror: TerminalLauncher helpers (PathDock/Services/TerminalLauncher.swift)

enum TerminalLauncherMirror {
    /// cd '경로' && 명령1 && 명령2 ... 형태의 단일 명령 문자열을 만든다.
    static func buildShellCommand(path: String, commands: [String]) -> String {
        let escapedPath = shellEscapeSingleQuoted(path)
        let trimmed = commands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if trimmed.isEmpty {
            return "cd '\(escapedPath)'"
        }
        let joined = trimmed.joined(separator: " && ")
        return "cd '\(escapedPath)' && \(joined)"
    }

    /// 작은따옴표로 감싸기 위한 escape. ' → '\''
    static func shellEscapeSingleQuoted(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// AppleScript 의 큰따옴표 문자열 안에 들어갈 값을 escape 한다.
    static func escapeForAppleScriptDoubleQuoted(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }
}

// MARK: - Mirror: PathEntry / EntryStore 의 sortIndex 정합성 로직만 복제
// (SwiftUI / @MainActor 의존을 제거한 순수 버전)

struct PathEntryMirror: Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var commands: [String]
    var sortIndex: Int
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        commands: [String] = [],
        sortIndex: Int = 0,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.commands = commands
        self.sortIndex = sortIndex
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

final class EntryStoreMirror {
    private(set) var entries: [PathEntryMirror] = []

    func add(_ entry: PathEntryMirror) {
        var newEntry = entry
        newEntry.sortIndex = entries.count
        newEntry.updatedAt = Date()
        entries.append(newEntry)
    }

    func update(_ entry: PathEntryMirror) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entry
        updated.updatedAt = Date()
        updated.sortIndex = entries[idx].sortIndex
        entries[idx] = updated
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        reindex()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        reindex()
    }

    func duplicate(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let src = entries[idx]
        let copy = PathEntryMirror(
            id: UUID(),
            name: src.name + " 복사본",
            path: src.path,
            commands: src.commands,
            sortIndex: idx + 1,
            note: src.note,
            createdAt: Date(),
            updatedAt: Date()
        )
        entries.insert(copy, at: idx + 1)
        reindex()
    }

    func move(from source: IndexSet, to destination: Int) {
        // SwiftUI 의 Array.move(fromOffsets:toOffset:) 와 동일한 의미를 standalone 환경에서 재현.
        // (PathDock 실제 코드는 SwiftUI 익스텐션을 호출하지만, 결과 sortIndex/순서 정합성을 검증하는 데는 동치.)
        let sortedSource = source.sorted()
        let movingItems = sortedSource.map { entries[$0] }
        // 큰 인덱스부터 제거해야 나머지 인덱스가 안 흔들림
        for i in sortedSource.reversed() {
            entries.remove(at: i)
        }
        // destination 은 "원래 배열" 기준 삽입 위치 — 앞쪽에서 제거된 개수만큼 보정
        let removedBeforeDest = sortedSource.filter { $0 < destination }.count
        let insertAt = destination - removedBeforeDest
        entries.insert(contentsOf: movingItems, at: insertAt)
        reindex()
    }

    func moveUp(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        entries.swapAt(idx, idx - 1)
        reindex()
    }

    func moveDown(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), idx < entries.count - 1 else { return }
        entries.swapAt(idx, idx + 1)
        reindex()
    }

    private func reindex() {
        for i in entries.indices {
            entries[i].sortIndex = i
        }
    }
}

// MARK: - 작은 테스트 러너

var passed = 0
var failed = 0
var failures: [String] = []

func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        failures.append("FAIL [\(file):\(line)] \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        failures.append("FAIL [\(file):\(line)] \(name): expected=\(expected) actual=\(actual)")
    }
}

func describe(_ title: String, _ block: () -> Void) {
    print("▶ \(title)")
    block()
}

// MARK: - shellEscapeSingleQuoted

describe("shellEscapeSingleQuoted") {
    expectEqual(
        TerminalLauncherMirror.shellEscapeSingleQuoted("/tmp/normal"),
        "/tmp/normal",
        "따옴표/특수문자 없는 경로는 그대로"
    )
    expectEqual(
        TerminalLauncherMirror.shellEscapeSingleQuoted("/tmp/don't"),
        "/tmp/don'\\''t",
        "작은따옴표 하나는 '\\'' 로 치환"
    )
    expectEqual(
        TerminalLauncherMirror.shellEscapeSingleQuoted("a'b'c"),
        "a'\\''b'\\''c",
        "작은따옴표 여러 개를 모두 치환"
    )
    expectEqual(
        TerminalLauncherMirror.shellEscapeSingleQuoted("/Users/me/My Folder"),
        "/Users/me/My Folder",
        "공백은 그대로 (작은따옴표 감싸기로 처리)"
    )
    expectEqual(
        TerminalLauncherMirror.shellEscapeSingleQuoted(""),
        "",
        "빈 문자열도 통과"
    )
}

// MARK: - buildShellCommand

describe("buildShellCommand") {
    // cd 만
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(path: "/tmp/foo", commands: []),
        "cd '/tmp/foo'",
        "명령어 없으면 cd 만"
    )
    // cd + 한 줄
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(path: "/tmp/foo", commands: ["ls -la"]),
        "cd '/tmp/foo' && ls -la",
        "명령어 한 줄은 && 로 연결"
    )
    // cd + 여러 줄
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/tmp/foo",
            commands: ["bundle install", "bundle exec fastlane ios test"]
        ),
        "cd '/tmp/foo' && bundle install && bundle exec fastlane ios test",
        "명령어 여러 줄은 모두 && 로 연결"
    )
    // 빈 줄/공백 줄 trim & 제외
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/tmp/foo",
            commands: ["", "  ", "ls", "\t", "pwd"]
        ),
        "cd '/tmp/foo' && ls && pwd",
        "빈/공백 줄은 무시"
    )
    // 명령어 앞뒤 공백 trim
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/tmp/foo",
            commands: ["  ls  ", "\tpwd\t"]
        ),
        "cd '/tmp/foo' && ls && pwd",
        "명령어 앞뒤 공백 제거"
    )
    // 작은따옴표가 포함된 경로
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/tmp/don't",
            commands: ["pwd"]
        ),
        "cd '/tmp/don'\\''t' && pwd",
        "작은따옴표 포함 경로 escape"
    )
    // 공백 포함 경로
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/Users/me/My Folder",
            commands: []
        ),
        "cd '/Users/me/My Folder'",
        "공백 포함 경로는 작은따옴표 감싸기로 안전"
    )
    // 모든 줄이 공백뿐일 때
    expectEqual(
        TerminalLauncherMirror.buildShellCommand(
            path: "/tmp/foo",
            commands: ["", "   ", "\t"]
        ),
        "cd '/tmp/foo'",
        "모든 명령어가 공백뿐이면 cd 만"
    )
}

// MARK: - escapeForAppleScriptDoubleQuoted

describe("escapeForAppleScriptDoubleQuoted") {
    expectEqual(
        TerminalLauncherMirror.escapeForAppleScriptDoubleQuoted("plain"),
        "plain",
        "특수문자 없는 문자열은 그대로"
    )
    expectEqual(
        TerminalLauncherMirror.escapeForAppleScriptDoubleQuoted("a\"b"),
        "a\\\"b",
        "큰따옴표는 \\\" 로 escape"
    )
    expectEqual(
        TerminalLauncherMirror.escapeForAppleScriptDoubleQuoted("a\\b"),
        "a\\\\b",
        "역슬래시는 \\\\ 로 escape"
    )
    // 역슬래시와 큰따옴표가 동시에 — 역슬래시 먼저 escape 되어야 \" 가 \\" 가 되지 않아야 함
    expectEqual(
        TerminalLauncherMirror.escapeForAppleScriptDoubleQuoted("a\\\"b"),
        "a\\\\\\\"b",
        "역슬래시 + 큰따옴표 순서 보존"
    )
    // 빌드 결과를 AppleScript 페이로드로 한 번 더 감싼 형태도 동작해야 함.
    // shell 에서 '\'' 였던 시퀀스(역슬래시 1개 포함)는 AppleScript escape 단계에서
    // 역슬래시가 2개로 늘어나 '\\'' 가 된다. AppleScript 가 do script "..." 안에서
    // 역방향으로 한 번 풀면 원래의 '\'' 로 복원되어 셸이 정상 해석한다.
    let shell = TerminalLauncherMirror.buildShellCommand(path: "/tmp/don't", commands: ["echo \"hi\""])
    let scripted = TerminalLauncherMirror.escapeForAppleScriptDoubleQuoted(shell)
    expect(
        scripted.contains("'\\\\''"),
        "AppleScript escape 후 shell 의 '\\'' 가 '\\\\'' 로 보존되어야 함 → 결과: \(scripted)"
    )
    expect(
        scripted.contains("\\\"hi\\\""),
        "AppleScript escape 가 명령어 내부의 큰따옴표를 \\\" 로 변환 → 결과: \(scripted)"
    )
    // do script "<scripted>" 형태로 AppleScript 가 실제 셸에 넘기는 문자열을 시뮬레이션해본다.
    // (AppleScript 가 문자열 리터럴을 해석할 때 \\ → \, \" → " 로 푼다.)
    func unescapeAppleScriptDoubleQuoted(_ s: String) -> String {
        // 단순화된 unescape: \\ → \ , \" → "
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(after: i) < s.endIndex {
                let next = s[s.index(after: i)]
                if next == "\\" || next == "\"" {
                    result.append(next)
                    i = s.index(i, offsetBy: 2)
                    continue
                }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }
    expectEqual(
        unescapeAppleScriptDoubleQuoted(scripted),
        shell,
        "AppleScript escape 는 round-trip 손실이 없어야 함"
    )
}

// MARK: - EntryStore CRUD & sortIndex 정합성

describe("EntryStore.add → sortIndex 자동 할당") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    expectEqual(store.entries.count, 3, "3건 추가")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1, 2], "sortIndex 0..n-1")
    expectEqual(store.entries.map { $0.name }, ["A", "B", "C"], "추가 순서 유지")
}

describe("EntryStore.update → sortIndex 보존") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    var b = store.entries[1]
    let originalSort = b.sortIndex
    b.name = "B-edited"
    b.path = "/b2"
    // 의도적으로 sortIndex 를 다르게 넣어 들어와도 무시되는지 확인
    b.sortIndex = 999
    store.update(b)
    expectEqual(store.entries[1].name, "B-edited", "이름 갱신")
    expectEqual(store.entries[1].path, "/b2", "경로 갱신")
    expectEqual(store.entries[1].sortIndex, originalSort, "sortIndex 는 기존 값 유지")
}

describe("EntryStore.delete(id:) → reindex") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    let bID = store.entries[1].id
    store.delete(id: bID)
    expectEqual(store.entries.map { $0.name }, ["A", "C"], "B 가 빠짐")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1], "sortIndex 0..n-1 로 재정렬")
}

describe("EntryStore.delete(ids:) 다중 삭제 → reindex") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    store.add(PathEntryMirror(name: "D", path: "/d"))
    let targets: Set<UUID> = [store.entries[0].id, store.entries[2].id]
    store.delete(ids: targets)
    expectEqual(store.entries.map { $0.name }, ["B", "D"], "A,C 가 빠짐")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1], "sortIndex 재정렬")
}

describe("EntryStore.move(from:to:) → reindex") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    // A 를 C 뒤로 이동
    store.move(from: IndexSet(integer: 0), to: 3)
    expectEqual(store.entries.map { $0.name }, ["B", "C", "A"], "A 가 끝으로 이동")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1, 2], "sortIndex 재정렬")
}

describe("EntryStore.moveUp → 이웃과 스왑") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    store.moveUp(id: store.entries[2].id) // C 를 위로
    expectEqual(store.entries.map { $0.name }, ["A", "C", "B"], "C 와 B 가 스왑")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1, 2], "sortIndex 재정렬")

    // 맨 위 항목은 더 이상 위로 못 감 (no-op)
    let before = store.entries.map { $0.name }
    store.moveUp(id: store.entries[0].id)
    expectEqual(store.entries.map { $0.name }, before, "최상단 moveUp 은 no-op")
}

describe("EntryStore.moveDown → 이웃과 스왑") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a"))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    store.moveDown(id: store.entries[0].id) // A 를 아래로
    expectEqual(store.entries.map { $0.name }, ["B", "A", "C"], "A 와 B 가 스왑")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1, 2], "sortIndex 재정렬")

    // 맨 아래 항목은 더 이상 아래로 못 감 (no-op)
    let before = store.entries.map { $0.name }
    store.moveDown(id: store.entries.last!.id)
    expectEqual(store.entries.map { $0.name }, before, "최하단 moveDown 은 no-op")
}

describe("EntryStore.duplicate → 원본 바로 아래 삽입 + 이름 ' 복사본'") {
    let store = EntryStoreMirror()
    store.add(PathEntryMirror(name: "A", path: "/a", commands: ["ls"]))
    store.add(PathEntryMirror(name: "B", path: "/b"))
    store.add(PathEntryMirror(name: "C", path: "/c"))
    let aID = store.entries[0].id
    store.duplicate(id: aID)
    expectEqual(store.entries.map { $0.name }, ["A", "A 복사본", "B", "C"], "복사본이 원본 바로 아래")
    expectEqual(store.entries.map { $0.sortIndex }, [0, 1, 2, 3], "sortIndex 재정렬")
    expectEqual(store.entries[1].path, "/a", "경로 복사")
    expectEqual(store.entries[1].commands, ["ls"], "명령어 복사")
    expect(store.entries[1].id != aID, "복사본은 새 id")
}

// MARK: - v2 첨부 / 토큰 / 패키지 포맷 (Mirror)

/// 명령어 본문의 `{{att:<uuid>}}` 토큰을 잡는 정규식
let attachmentTokenRegexMirror: NSRegularExpression = {
    let pattern = "\\{\\{att:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\\}\\}"
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(pattern: pattern)
}()

/// 한 줄에서 토큰 UUID 들을 추출 (등장 순서 유지)
func extractTokenUUIDs(_ line: String) -> [String] {
    let ns = line as NSString
    let matches = attachmentTokenRegexMirror.matches(in: line, range: NSRange(location: 0, length: ns.length))
    return matches.map { ns.substring(with: $0.range(at: 1)) }
}

/// 단일 첨부 크기 상한 (10MB)
let attachmentMaxBytes: Int = 10 * 1024 * 1024

func isAttachmentSizeAllowed(_ size: Int) -> Bool {
    return size > 0 && size <= attachmentMaxBytes
}

describe("attachment token: 추출") {
    let line1 = "open {{att:11111111-2222-3333-4444-555555555555}}"
    expectEqual(extractTokenUUIDs(line1), ["11111111-2222-3333-4444-555555555555"], "단일 토큰")

    let line2 = "diff {{att:11111111-2222-3333-4444-555555555555}} {{att:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}}"
    expectEqual(
        extractTokenUUIDs(line2),
        ["11111111-2222-3333-4444-555555555555", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
        "한 줄 다중 토큰 순서 유지"
    )

    expectEqual(extractTokenUUIDs("no tokens here"), [], "토큰 없으면 빈 배열")
    expectEqual(extractTokenUUIDs("{{att:not-a-valid-uuid}}"), [], "UUID 형식 아닌 것은 매칭 안 됨")
}

describe("attachment token: 정규식 case-insensitive 16진수") {
    // 정규식은 대소문자 hex 모두 허용
    let lower = "{{att:abcdefab-cdef-abcd-efab-abcdefabcdef}}"
    expectEqual(extractTokenUUIDs(lower), ["abcdefab-cdef-abcd-efab-abcdefabcdef"], "소문자 hex 허용")
    let upper = "{{att:ABCDEFAB-CDEF-ABCD-EFAB-ABCDEFABCDEF}}"
    expectEqual(extractTokenUUIDs(upper), ["ABCDEFAB-CDEF-ABCD-EFAB-ABCDEFABCDEF"], "대문자 hex 허용")
}

describe("attachment size: 10MB 경계") {
    expect(isAttachmentSizeAllowed(1), "1B 허용")
    expect(isAttachmentSizeAllowed(10 * 1024 * 1024), "정확히 10MB 허용")
    expect(!isAttachmentSizeAllowed(10 * 1024 * 1024 + 1), "10MB + 1B 거부")
    expect(!isAttachmentSizeAllowed(0), "0B 거부")
    expect(!isAttachmentSizeAllowed(-1), "음수 거부")
}

// .pathdock 패키지 포맷: magic(8) + version(2 LE) + salt(16) + nonce(12) + ct(N) + tag(16)
let pathdockMagic: [UInt8] = [0x50, 0x44, 0x4F, 0x43, 0x4B, 0x76, 0x31, 0x00] // "PDOCKv1\0"

func pathdockHeaderLength() -> Int { return 8 + 2 + 16 + 12 } // 38 = magic + version + salt + nonce

func validatePathdockMagic(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 8 else { return false }
    return Array(bytes[0..<8]) == pathdockMagic
}

func validatePathdockVersion(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 10 else { return nil }
    let lo = Int(bytes[8])
    let hi = Int(bytes[9])
    return lo | (hi << 8)
}

describe("pathdock 포맷: magic / version / 헤더 길이") {
    expectEqual(pathdockHeaderLength(), 38, "헤더 = magic(8) + version(2) + salt(16) + nonce(12)")
    expect(validatePathdockMagic(pathdockMagic + [0, 0]), "정확한 magic 통과")
    expect(!validatePathdockMagic([0x50, 0x44, 0x4F, 0x43, 0x4B, 0x76, 0x32, 0x00]), "magic v2 는 거부")
    expect(!validatePathdockMagic([0x00]), "너무 짧으면 거부")

    // version = 1 (little-endian)
    let v1Bytes: [UInt8] = pathdockMagic + [0x01, 0x00] + Array(repeating: 0, count: 28)
    expectEqual(validatePathdockVersion(v1Bytes), 1, "version 1 디코드")
    let v258Bytes: [UInt8] = pathdockMagic + [0x02, 0x01] + Array(repeating: 0, count: 28)
    expectEqual(validatePathdockVersion(v258Bytes), 258, "LE 16-bit 디코드(0x0102 = 258)")
}

// MARK: - 결과 출력

print("")
print("─────────────────────────────────────────")
print("✅ passed: \(passed)")
print("❌ failed: \(failed)")
if !failures.isEmpty {
    print("")
    for f in failures {
        print(f)
    }
}
print("─────────────────────────────────────────")
exit(failed == 0 ? 0 : 1)
