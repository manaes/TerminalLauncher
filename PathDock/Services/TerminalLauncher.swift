//
//  TerminalLauncher.swift
//  PathDock
//
//  Terminal.app 의 새 창을 띄워 cd + 등록된 명령을 실행하는 서비스.
//  명령어 본문의 `{{att:<uuid>}}` 토큰은 실행 직전 평문 임시파일 경로로 치환된다.
//

import Foundation
import AppKit

/// 터미널/원격 실행 중 발생할 수 있는 오류
enum LaunchError: LocalizedError {
    case pathNotFound(String)
    case appleScriptFailed(String)
    /// 명령어에 첨부 메타에 없는 토큰이 들어있음
    case invalidAttachmentToken(uuid: String)
    /// 평문 풀기(write) 실패
    case attachmentExtractionFailed(String)
    /// 원격 항목의 필수 필드 누락 / 잘못된 설정
    case invalidRemoteConfig(String)
    /// VNC URL 을 NSWorkspace 로 여는 데 실패
    case vncOpenFailed(String)

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
        case .invalidRemoteConfig(let msg):
            return "원격 연결 설정이 올바르지 않습니다.\n\(msg)"
        case .vncOpenFailed(let msg):
            return "VNC 연결에 실패했습니다.\n\(msg)"
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
    /// - note: kind == .command 인 항목만 지원. 다른 kind 가 들어오면 invalidRemoteConfig 로 throw.
    ///   호출 측(ContentView 의 launch)이 kind 별로 적절한 헬퍼로 분기해야 한다.
    @MainActor
    static func launch(_ entry: PathEntry, attachmentStore: AttachmentStore) throws {
        guard entry.kind == .command else {
            throw LaunchError.invalidRemoteConfig("이 항목은 명령어 타입이 아닙니다. (kind=\(entry.kind.rawValue))")
        }

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

    /// SSH 항목 한 건을 Terminal.app 의 새 창에서 실행한다.
    /// - parameter entry: kind == .remoteSSH 인 항목
    /// - parameter attachmentStore: 키파일 모드에서 첨부 평문 풀기에 사용
    ///
    /// 동작:
    /// - keyfile 모드: 키파일을 decrypted/ 임시폴더로 풀고 0600 권한을 적용, `ssh -i <키파일>` 명령 합성
    /// - password 모드: 패스워드를 NSPasteboard 에 자동 복사하고, 안내 echo + ssh 명령 합성
    @MainActor
    static func launchSSH(_ entry: PathEntry, attachmentStore: AttachmentStore) throws {
        guard entry.kind == .remoteSSH else {
            throw LaunchError.invalidRemoteConfig("SSH 타입이 아닙니다. (kind=\(entry.kind.rawValue))")
        }
        let shellCommand = try prepareSshShellCommand(entry: entry, attachmentStore: attachmentStore)
        let script = terminalScript(for: shellCommand)
        try runAppleScript(script)
    }

    /// SSH 항목을 Terminal 에서 실행할 단일 셸 명령 문자열로 합성한다.
    /// - returns: `echo '...' && ssh user@host -p port [-i key]` 형태
    @MainActor
    static func prepareSshShellCommand(entry: PathEntry, attachmentStore: AttachmentStore) throws -> String {
        // 1) host 검증
        let host = (entry.host ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            throw LaunchError.invalidRemoteConfig("호스트(주소)가 비어 있습니다.")
        }
        let port = entry.port ?? 22
        let username = (entry.username ?? "").trimmingCharacters(in: .whitespaces)
        let userHost: String = username.isEmpty ? host : "\(username)@\(host)"

        // 2) 인증 분기
        let auth = entry.auth ?? .password
        var prefixEchoLine: String? = nil   // ssh 실행 직전 사용자 안내
        var keyfileArg: String? = nil       // -i <키파일경로>

        switch auth {
        case .keyfile:
            guard let keyId = entry.keyAttachmentId else {
                throw LaunchError.invalidRemoteConfig("키파일이 지정되지 않았습니다.")
            }
            guard let att = entry.attachments.first(where: { $0.id == keyId }) else {
                throw LaunchError.invalidRemoteConfig("키파일 첨부 메타를 찾을 수 없습니다.")
            }
            // 이번 실행 전용 디렉토리에 평문 풀기
            let runId = UUID().uuidString
            let runDir = attachmentStore.decryptedDir.appendingPathComponent(runId, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            } catch {
                throw LaunchError.attachmentExtractionFailed(String(describing: error))
            }
            let target = runDir.appendingPathComponent(att.originalName)
            do {
                let data = try attachmentStore.read(id: keyId)
                try data.write(to: target, options: [.atomic])
            } catch {
                throw LaunchError.attachmentExtractionFailed(String(describing: error))
            }
            // SSH 키 파일은 0600 권한이어야 함
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: target.path
                )
            } catch {
                throw LaunchError.attachmentExtractionFailed("키파일 권한 설정 실패: \(String(describing: error))")
            }
            keyfileArg = target.path

        case .password:
            // 패스워드 자동 클립보드 복사 (있을 때만)
            if let pw = entry.password, !pw.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(pw, forType: .string)
                prefixEchoLine = "echo '🔑 패스워드가 클립보드에 복사되었습니다. 프롬프트에서 ⌘V 로 붙여넣으세요.'"
            }
        }

        // 3) ssh 명령 합성
        var sshParts: [String] = ["ssh", "'\(shellEscapeSingleQuoted(userHost))'"]
        sshParts.append("-p")
        sshParts.append(String(port))
        if let keyPath = keyfileArg {
            sshParts.append("-i")
            sshParts.append("'\(shellEscapeSingleQuoted(keyPath))'")
        }
        // 추가 옵션: "Key Value" → -oKey=Value (셸 escape + 작은따옴표 감싸기)
        for line in entry.sshExtraOptions ?? [] {
            if let opt = formatExtraSshOption(line) {
                sshParts.append(opt)
            }
        }
        let sshCommand = sshParts.joined(separator: " ")

        if let echoLine = prefixEchoLine {
            return "\(echoLine) && \(sshCommand)"
        }
        return sshCommand
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

    /// `Key Value` 한 줄을 ssh 의 `-oKey=Value` 인자로 변환한다.
    /// - 빈 줄 / Key 만 있는 줄은 nil 반환 (무시)
    /// - Value 는 작은따옴표로 감싸 셸 escape
    /// - Key 도 이론상 escape 필요 없지만 일관성 위해 단순 trim 만
    static func formatExtraSshOption(_ rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // 첫 공백/탭을 기준으로 Key 와 Value 분리. `Key=Value` 도 허용.
        let key: String
        let value: String
        if let eq = trimmed.firstIndex(of: "=") {
            let firstWS = trimmed.firstIndex { $0 == " " || $0 == "\t" }
            if firstWS == nil || eq < firstWS! {
                key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                guard parts.count == 2 else { return nil }
                key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard parts.count == 2 else { return nil }
            key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        if key.isEmpty || value.isEmpty { return nil }
        // ssh 의 -o 인자: Key=Value 한 토큰. 전체를 작은따옴표로 감싸 셸 escape 처리.
        return "-o'\(shellEscapeSingleQuoted(key))=\(shellEscapeSingleQuoted(value))'"
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
