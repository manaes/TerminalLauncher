//
//  SSHConfigParser.swift
//  PathDock
//
//  ~/.ssh/config 의 Host 항목을 가볍게 파싱한다.
//  지원: Host / HostName / User / Port / IdentityFile (~ 확장 포함)
//  무시: Include / Match / ProxyCommand / ProxyJump / 기타 옵션, 주석(#)
//  제외: Host 행에 와일드카드(* ?)가 포함된 항목 — 실제 호스트가 아니라 패턴
//

import Foundation

/// ssh config 에서 추출한 한 Host 의 요약
struct SSHConfigHost: Identifiable, Hashable {
    /// `Host <name>` 의 이름. UI 표시·식별에 사용한다.
    let name: String
    /// HostName 디렉티브 값. 없으면 name 을 그대로 사용.
    let hostName: String?
    /// Port 디렉티브 값
    let port: Int?
    /// User 디렉티브 값
    let user: String?
    /// IdentityFile 디렉티브 값 (~ 확장된 절대 경로)
    let identityFilePath: String?
    /// PathDock 이 직접 매핑하지 않는 그 외 옵션들. 원형(`Key Value`)을 보존한다.
    /// 예: ["HostKeyAlgorithms +ssh-rsa,ssh-dss", "ServerAliveInterval 30"]
    /// 실행 시 `-oKey=Value` 형식으로 ssh 인자에 합성된다.
    let extraOptions: [String]

    var id: String { name }

    /// EntryEditorSheet 에서 host 필드에 채울 값 (HostName 우선, 없으면 Host 이름)
    var effectiveHost: String { hostName ?? name }
}

/// `~/.ssh/config` 파서.
/// 호출 비용이 작아 매번 재파싱해도 무방하다.
enum SSHConfigParser {

    /// 기본 경로 (`~/.ssh/config`) 에서 로드.
    static func loadDefault() -> [SSHConfigHost] {
        let path = NSString(string: "~/.ssh/config").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return load(from: url)
    }

    /// 임의 URL 에서 로드. 파일이 없거나 읽기 실패면 빈 배열.
    static func load(from url: URL) -> [SSHConfigHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// 텍스트로부터 직접 파싱 (단위 테스트용).
    static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []

        // 현재 Host 블록 누적
        var currentNames: [String] = []   // `Host a b c` 처럼 여러 이름 가능
        var hostName: String?
        var port: Int?
        var user: String?
        var identity: String?
        var extras: [String] = []         // 그 외 키-값 (`Key Value` 원형)

        func flush() {
            // 와일드카드/패턴 포함 이름은 모두 제외, 나머지는 각각 한 건씩 산출
            for name in currentNames where !name.contains("*") && !name.contains("?") {
                hosts.append(SSHConfigHost(
                    name: name,
                    hostName: hostName,
                    port: port,
                    user: user,
                    identityFilePath: identity,
                    extraOptions: extras
                ))
            }
            currentNames = []
            hostName = nil
            port = nil
            user = nil
            identity = nil
            extras = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            // 주석 / 공백 처리
            let stripped = stripInlineComment(rawLine).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }

            // ssh config 는 `key value` 또는 `key=value` 형태. 키는 대소문자 무관.
            let (key, value) = splitKeyValue(stripped)
            guard let key = key, let value = value, !value.isEmpty else { continue }
            let keyLower = key.lowercased()

            // Match / Include 블록은 무시. 현재 블록을 닫고 패턴은 currentNames 에 두지 않는다.
            if keyLower == "include" || keyLower == "match" {
                flush()
                continue
            }

            if keyLower == "host" {
                // 새 Host 블록 시작 — 이전 블록 산출
                flush()
                // value 는 공백 분리된 여러 이름일 수 있음
                currentNames = value
                    .components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }

            // Host 블록 밖이면 (currentNames 비어있음) 다른 키들은 모두 글로벌이라 무시.
            if currentNames.isEmpty { continue }

            switch keyLower {
            case "hostname":
                hostName = value
            case "port":
                port = Int(value)
            case "user":
                user = value
            case "identityfile":
                identity = NSString(string: stripQuotes(value)).expandingTildeInPath
            default:
                // 그 외 모든 키는 원형(`Key Value`)으로 보존 → 사용자에게 노출 후
                // 실행 시 `-oKey=Value` 로 합성
                extras.append("\(key) \(value)")
            }
        }
        flush()
        return hosts
    }

    // MARK: - 헬퍼

    /// `# 주석` 을 제거. 큰따옴표 내부의 `#` 는 보존한다.
    private static func stripInlineComment(_ s: String) -> String {
        var inQuote = false
        var result = ""
        for ch in s {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            result.append(ch)
        }
        return result
    }

    /// `key value` 또는 `key=value` 형태에서 key 와 value 를 분리.
    /// value 는 큰따옴표 1쌍으로 감싸져 있을 수 있다.
    private static func splitKeyValue(_ line: String) -> (String?, String?) {
        // = 또는 공백/탭으로 분리. 첫 토큰이 key, 나머지가 value.
        if let eq = line.firstIndex(of: "=") {
            // key=value 인지 확인 — '=' 가 첫 공백보다 앞에 있을 때만
            let firstWS = line.firstIndex { $0 == " " || $0 == "\t" }
            if firstWS == nil || eq < firstWS! {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                return (key, stripQuotes(value))
            }
        }
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
        if parts.count == 2 {
            return (String(parts[0]), stripQuotes(String(parts[1]).trimmingCharacters(in: .whitespaces)))
        }
        return (parts.first.map { String($0) }, nil)
    }

    /// 양쪽 큰따옴표 1쌍을 벗긴다.
    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
