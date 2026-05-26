//
//  TerminalLauncher.swift
//  PathDock
//
//  Terminal.app 의 새 창을 띄워 cd + 등록된 명령을 실행하는 서비스.
//  명령어 본문의 `{{att:<uuid>}}` 토큰은 실행 직전 평문 임시파일 경로로 치환된다.
//

import Foundation
import AppKit

/// 터미널 실행 중 발생할 수 있는 오류
enum LaunchError: LocalizedError {
    case pathNotFound(String)
    case appleScriptFailed(String)
    /// 명령어에 첨부 메타에 없는 토큰이 들어있음
    case invalidAttachmentToken(uuid: String)
    /// 평문 풀기(write) 실패
    case attachmentExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let p):
            return "경로를 찾을 수 없습니다:\n\(p)"
        case .appleScriptFailed(let msg):
            return "터미널 실행에 실패했습니다.\n\n\(msg)\n\n시스템 설정 → 개인 정보 보호 및 보안 → 자동화에서 PathDock 의 Terminal 제어 권한을 허용했는지 확인하세요."
        case .invalidAttachmentToken(let uuid):
            return "유효하지 않은 첨부 토큰입니다: {{att:\(uuid)}}\n해당 첨부가 제거되었거나 메타에 존재하지 않습니다."
        case .attachmentExtractionFailed(let msg):
            return "첨부 파일을 평문으로 풀지 못했습니다.\n\(msg)"
        }
    }
}

/// `{{att:<uuid>}}` 토큰 정규식 (전역 캐시)
private let attachmentTokenRegex: NSRegularExpression = {
    // uuid: 8-4-4-4-12 (hex)
    let pattern = "\\{\\{att:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\\}\\}"
    // pattern 은 컴파일 타임에 안전한 정규식이므로 force-try
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(pattern: pattern)
}()

/// PathEntry 한 건을 Terminal.app 에서 실행한다.
enum TerminalLauncher {

    /// 등록된 항목 없이 Terminal.app 새 창을 그냥 하나 띄운다.
    static func launchEmptyWindow() throws {
        let script = """
        tell application "Terminal"
            activate
            do script ""
        end tell
        """
        try runAppleScript(script)
    }

    /// 항목을 실행한다. 첨부 토큰이 있으면 평문 임시 파일로 풀어 치환한다.
    /// 평문 임시 파일은 다음 앱 실행 시 startup cleanup 으로 정리된다.
    @MainActor
    static func launch(_ entry: PathEntry, attachmentStore: AttachmentStore) throws {
        // 1) ~ 확장 후 존재 여부 확인
        let resolvedPath = NSString(string: entry.path).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir)
        guard exists else {
            throw LaunchError.pathNotFound(resolvedPath)
        }

        // 2) 토큰 치환 + 평문 풀기
        let prepared = try prepareCommands(entry: entry, attachmentStore: attachmentStore)

        // 3) 단일 셸 명령 문자열 합성
        let fullCommand = buildShellCommand(path: resolvedPath, commands: prepared.commands)

        // 4) AppleScript 실행
        let script = terminalScript(for: fullCommand)
        try runAppleScript(script)
    }

    /// 첨부 토큰을 평문 경로로 치환한 명령어 배열 반환.
    /// - parameter entry: 대상 PathEntry
    /// - parameter attachmentStore: 첨부 read 위임체
    /// - returns: 치환된 명령어 배열 + 정리 후보 경로(현재는 startup cleanup 에 맡기므로 사용자는 무시 가능)
    @MainActor
    static func prepareCommands(entry: PathEntry, attachmentStore: AttachmentStore) throws -> (commands: [String], pendingCleanup: [URL]) {
        // attachments 메타를 id → Attachment 로 인덱싱
        let byId: [UUID: Attachment] = Dictionary(uniqueKeysWithValues: entry.attachments.map { ($0.id, $0) })

        // 이번 실행 전용 디렉토리
        let runId = UUID().uuidString
        let runDir = attachmentStore.decryptedDir.appendingPathComponent(runId, isDirectory: true)
        // 토큰을 한 번도 만나지 않으면 runDir 은 만들 필요가 없어, lazily 생성한다.
        var runDirCreated = false
        var written: [URL] = []

        // 한 줄에 같은 토큰이 여러 번 나올 수 있고, 줄 사이에 같은 uuid 가 재등장할 수 있다.
        // 같은 uuid 는 한 번만 평문으로 풀고 경로를 재사용.
        var resolvedPathById: [UUID: String] = [:]

        var output: [String] = []
        for line in entry.commands {
            let ns = line as NSString
            var resultLine = line
            // 정규식으로 모든 매칭을 찾아 뒤에서 앞으로 교체 (인덱스 안정성)
            let matches = attachmentTokenRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                output.append(line)
                continue
            }
            for match in matches.reversed() {
                let uuidRange = match.range(at: 1)
                let fullRange = match.range(at: 0)
                let uuidStr = ns.substring(with: uuidRange)
                guard let uuid = UUID(uuidString: uuidStr), let att = byId[uuid] else {
                    throw LaunchError.invalidAttachmentToken(uuid: uuidStr)
                }
                // 아직 평문 안 풀린 첨부면 풀기
                let pathStr: String
                if let cached = resolvedPathById[uuid] {
                    pathStr = cached
                } else {
                    if !runDirCreated {
                        do {
                            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
                        } catch {
                            throw LaunchError.attachmentExtractionFailed(String(describing: error))
                        }
                        runDirCreated = true
                    }
                    let target = runDir.appendingPathComponent(att.originalName)
                    do {
                        let data = try attachmentStore.read(id: uuid)
                        try data.write(to: target, options: [.atomic])
                    } catch {
                        throw LaunchError.attachmentExtractionFailed(String(describing: error))
                    }
                    written.append(target)
                    pathStr = target.path
                    resolvedPathById[uuid] = pathStr
                }
                // 셸 escape 적용 후 작은따옴표로 감싸 치환
                let escaped = "'" + shellEscapeSingleQuoted(pathStr) + "'"
                let nsResult = resultLine as NSString
                resultLine = nsResult.replacingCharacters(in: fullRange, with: escaped)
            }
            output.append(resultLine)
        }
        return (output, written)
    }

    // MARK: - Internal helpers

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

    /// Terminal.app 용 AppleScript 생성
    static func terminalScript(for shellCommand: String) -> String {
        let safe = escapeForAppleScriptDoubleQuoted(shellCommand)
        return """
        tell application "Terminal"
            activate
            do script "\(safe)"
        end tell
        """
    }

    /// NSAppleScript 실행 래퍼. 실패 시 LaunchError.appleScriptFailed throw.
    static func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.appleScriptFailed("AppleScript 컴파일에 실패했습니다.")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                ?? "알 수 없는 오류"
            throw LaunchError.appleScriptFailed(msg)
        }
    }
}
