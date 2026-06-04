//
//  SSHConfigExporter.swift
//  PathDock
//
//  등록된 SSH(remoteSSH) 항목들을 `~/.ssh/config` 로 내보낸다.
//   - 같은 Host 이름 또는 같은 HostName(주소)을 가진 기존 블록은 교체(덮어쓰기)
//   - 그 외 블록·주석·전역(preamble) 설정은 원형 그대로 보존
//   - keyfile 인증 항목은 키파일을 `~/.ssh/pathdock/` 로 평문 저장(0600)하고
//     IdentityFile 경로를 그쪽으로 지정
//   - 쓰기 직전 기존 config 를 타임스탬프 백업
//
//  순수 로직(렌더/병합/이름 정규화)은 IO 와 분리해 단위 테스트 가능하게 둔다.
//

import Foundation

/// SSH config 내보내기 단계 오류
enum SSHConfigExportError: LocalizedError {
    case noSSHEntries
    case homeUnavailable
    case keyReadFailed(entryName: String, detail: String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .noSSHEntries:
            return "내보낼 SSH 항목이 없습니다."
        case .homeUnavailable:
            return "홈 디렉토리를 찾을 수 없습니다."
        case .keyReadFailed(let name, let detail):
            return "키파일 처리 실패 (\(name)): \(detail)"
        case .ioFailure(let msg):
            return "SSH config 쓰기 실패: \(msg)"
        }
    }
}

enum SSHConfigExporter {

    // MARK: - 경로

    /// `~/.ssh`
    static var sshDir: URL {
        URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath, isDirectory: true)
    }
    /// `~/.ssh/config`
    static var configURL: URL { sshDir.appendingPathComponent("config") }
    /// PathDock 전용 키파일 디렉토리 `~/.ssh/pathdock`
    static var keyDir: URL { sshDir.appendingPathComponent("pathdock", isDirectory: true) }

    // MARK: - 미리보기 계획

    /// 확인 다이얼로그용 요약. (디스크에 손대지 않고 기존 config 만 읽어 계산)
    struct Plan {
        /// 대상 SSH 항목 수
        let total: Int
        /// 신규로 추가될 블록 수
        let newCount: Int
        /// 기존 블록을 덮어쓸 수
        let overwriteCount: Int
        /// 로컬에 풀어 쓸 키파일 수
        let keyFileCount: Int
        /// 대상 config 경로(표시용)
        let configPath: String
    }

    /// 수행 결과 요약.
    struct ExportResult {
        let written: Int
        let overwritten: Int
        let keyFiles: Int
        /// 백업본 경로 (기존 config 가 없었으면 nil)
        let backupPath: String?
        let configPath: String
        /// 키파일을 쓴 디렉토리 (키파일이 0개면 nil)
        let keyDir: String?
    }

    /// 렌더 단계에서 생성된 한 Host 블록.
    /// blockText 는 `Host …` 부터 마지막 옵션까지 한 덩어리(끝에 개행 없음).
    struct GeneratedHost {
        let name: String
        let hostName: String
        let blockText: String
    }

    // MARK: - 공개 API

    /// 대상 항목과 현재 config 를 바탕으로 계획을 계산한다.
    static func plan(entries: [PathEntry]) -> Plan {
        let ssh = sshEntries(from: entries)
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let generated = renderHosts(from: ssh, keyPathProvider: { _ in nil })
        let counts = mergeCounts(existing: existing, generated: generated)
        let keyCount = ssh.filter { ($0.auth ?? .password) == .keyfile && $0.keyAttachmentId != nil }.count
        return Plan(
            total: ssh.count,
            newCount: counts.newCount,
            overwriteCount: counts.overwriteCount,
            keyFileCount: keyCount,
            configPath: configURL.path
        )
    }

    /// 실제 내보내기. SSH 항목만 대상으로 하며 config 를 병합 후 덮어쓴다.
    /// - throws: 대상이 없거나 IO/키 처리 실패 시
    @MainActor
    static func export(entries: [PathEntry], attachmentStore: AttachmentStore) throws -> ExportResult {
        let ssh = sshEntries(from: entries)
        guard !ssh.isEmpty else { throw SSHConfigExportError.noSSHEntries }

        let fm = FileManager.default

        // 1) ~/.ssh 디렉토리 보장 (0700)
        try ensureDirectory(sshDir, permissions: 0o700)

        // 2) keyfile 항목 → ~/.ssh/pathdock/ 로 평문 저장, 항목별 IdentityFile 경로 매핑
        var keyPathByEntry: [UUID: String] = [:]
        var keyFileCount = 0
        let keyfileEntries = ssh.filter { ($0.auth ?? .password) == .keyfile && $0.keyAttachmentId != nil }
        if !keyfileEntries.isEmpty {
            try ensureDirectory(keyDir, permissions: 0o700)
            // 같은 정규화 이름이 겹치지 않도록 파일명 유일화
            var usedFileNames: Set<String> = []
            for entry in keyfileEntries {
                guard let keyId = entry.keyAttachmentId,
                      entry.attachments.contains(where: { $0.id == keyId }) else { continue }
                let baseName = uniqueName(sanitizeHostName(entry.name, fallback: entry.host ?? "host"), used: &usedFileNames)
                let target = keyDir.appendingPathComponent(baseName)
                do {
                    let data = try attachmentStore.read(id: keyId)
                    try data.write(to: target, options: [.atomic])
                    try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: target.path)
                } catch {
                    throw SSHConfigExportError.keyReadFailed(entryName: entry.name, detail: String(describing: error))
                }
                keyPathByEntry[entry.id] = target.path
                keyFileCount += 1
            }
        }

        // 3) Host 블록 렌더 (키 경로 주입)
        let generated = renderHosts(from: ssh, keyPathProvider: { keyPathByEntry[$0.id] })

        // 4) 기존 config 병합
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let merged = mergeConfig(existing: existing, generated: generated)

        // 5) 기존 config 백업 (있을 때만)
        var backupPath: String? = nil
        if fm.fileExists(atPath: configURL.path) {
            let stamp = backupTimestamp()
            let backupURL = sshDir.appendingPathComponent("config.pathdock-backup-\(stamp)")
            do {
                try fm.copyItem(at: configURL, to: backupURL)
                backupPath = backupURL.path
            } catch {
                throw SSHConfigExportError.ioFailure("백업 생성 실패: \(String(describing: error))")
            }
        }

        // 6) config 쓰기 (0600)
        do {
            try merged.text.write(to: configURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: configURL.path)
        } catch {
            throw SSHConfigExportError.ioFailure(String(describing: error))
        }

        return ExportResult(
            written: merged.newCount,
            overwritten: merged.overwriteCount,
            keyFiles: keyFileCount,
            backupPath: backupPath,
            configPath: configURL.path,
            keyDir: keyFileCount > 0 ? keyDir.path : nil
        )
    }

    // MARK: - 순수 로직 (테스트 대상)

    /// entries 중 SSH 타입만 추린다.
    static func sshEntries(from entries: [PathEntry]) -> [PathEntry] {
        entries.filter { $0.kind == .remoteSSH }
    }

    /// SSH 항목들을 Host 블록으로 렌더한다.
    /// - parameter keyPathProvider: 항목별 IdentityFile 경로(없으면 nil). 미리보기 단계에선 항상 nil.
    static func renderHosts(from entries: [PathEntry], keyPathProvider: (PathEntry) -> String?) -> [GeneratedHost] {
        var usedNames: Set<String> = []
        var result: [GeneratedHost] = []
        for entry in entries {
            let host = (entry.host ?? "").trimmingCharacters(in: .whitespaces)
            // 주소가 비어있으면 ssh 로 의미가 없으므로 건너뛴다.
            guard !host.isEmpty else { continue }
            let name = uniqueName(sanitizeHostName(entry.name, fallback: host), used: &usedNames)
            let block = renderBlock(
                name: name,
                hostName: host,
                port: entry.port,
                user: (entry.username ?? "").trimmingCharacters(in: .whitespaces),
                identityFile: keyPathProvider(entry),
                extras: entry.sshExtraOptions ?? []
            )
            result.append(GeneratedHost(name: name, hostName: host, blockText: block))
        }
        return result
    }

    /// 단일 Host 블록 텍스트를 만든다. (끝에 개행 없음, 본문은 4칸 들여쓰기)
    static func renderBlock(
        name: String,
        hostName: String,
        port: Int?,
        user: String,
        identityFile: String?,
        extras: [String]
    ) -> String {
        var lines: [String] = ["Host \(name)"]
        lines.append("    HostName \(configQuote(hostName))")
        // 포트는 비표준(22 아님)일 때만 명시
        if let p = port, p != 22 {
            lines.append("    Port \(p)")
        }
        if !user.isEmpty {
            lines.append("    User \(configQuote(user))")
        }
        if let key = identityFile, !key.isEmpty {
            lines.append("    IdentityFile \(configQuote(key))")
            // 키파일을 명시했으면 비대화형에서도 키 우선이 되도록 IdentitiesOnly 를 켠다.
            lines.append("    IdentitiesOnly yes")
        }
        // sshExtraOptions: 이미 `Key Value` 원형 — 유효한 줄만 들여써서 추가
        for raw in extras {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append("    \(trimmed)")
        }
        return lines.joined(separator: "\n")
    }

    /// 기존 config 텍스트에 generated 블록을 병합한 결과 텍스트와 신규/덮어쓰기 카운트.
    /// 충돌(같은 Host 이름 또는 같은 HostName)하는 기존 블록은 제거하고, 모든 generated 블록을 끝에 추가한다.
    static func mergeConfig(existing: String, generated: [GeneratedHost]) -> (text: String, newCount: Int, overwriteCount: Int) {
        let parsed = parseBlocks(existing)
        let exportNames = Set(generated.map { $0.name.lowercased() })
        let exportHostNames = Set(generated.map { $0.hostName.lowercased() })

        func conflicts(_ block: RawBlock) -> Bool {
            if block.hostNames.contains(where: { exportNames.contains($0.lowercased()) }) { return true }
            if let hn = block.hostName, exportHostNames.contains(hn.lowercased()) { return true }
            return false
        }

        let surviving = parsed.blocks.filter { !conflicts($0) }
        let counts = mergeCounts(parsedBlocks: parsed.blocks, generated: generated)

        // 보존 영역(preamble + 살아남은 블록) → 원형 유지
        var headLines = parsed.preamble
        for block in surviving { headLines.append(contentsOf: block.lines) }
        let head = trimTrailingBlank(headLines).joined(separator: "\n")

        var sections: [String] = []
        if !head.isEmpty { sections.append(head) }
        for g in generated { sections.append(g.blockText) }

        let text = sections.isEmpty ? "" : sections.joined(separator: "\n\n") + "\n"
        return (text, counts.newCount, counts.overwriteCount)
    }

    /// Host 이름을 ssh config 의 단일 토큰으로 정규화한다.
    /// 공백 → `-`, 와일드카드/주석 문자 제거. 비면 fallback(주소)을 정규화해 사용한다.
    static func sanitizeHostName(_ raw: String, fallback: String) -> String {
        let cleaned = cleanToken(raw)
        if !cleaned.isEmpty { return cleaned }
        let fb = cleanToken(fallback)
        return fb.isEmpty ? "pathdock-host" : fb
    }

    // MARK: - 순수 헬퍼

    /// config 값에 공백이 있으면 큰따옴표로 감싼다. (빈 값도 따옴표 처리)
    static func configQuote(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        if value.contains(where: { $0 == " " || $0 == "\t" }) {
            // 내부 큰따옴표는 escape (드물지만 안전하게)
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// 토큰 정규화: 공백 묶음을 `-` 로, `* ? # "` 제거.
    private static func cleanToken(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var lastWasDash = false
        for ch in trimmed {
            if ch == " " || ch == "\t" {
                if !lastWasDash && !out.isEmpty { out.append("-"); lastWasDash = true }
                continue
            }
            if ch == "*" || ch == "?" || ch == "#" || ch == "\"" { continue }
            out.append(ch)
            lastWasDash = false
        }
        // 끝의 `-` 정리
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// base 가 이미 쓰였으면 `-2`, `-3` … 을 붙여 유일화. (대소문자 무시 비교)
    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// 신규/덮어쓰기 카운트만 계산 (텍스트 파싱 후).
    private static func mergeCounts(existing: String, generated: [GeneratedHost]) -> (newCount: Int, overwriteCount: Int) {
        let parsed = parseBlocks(existing)
        return mergeCounts(parsedBlocks: parsed.blocks, generated: generated)
    }

    private static func mergeCounts(parsedBlocks: [RawBlock], generated: [GeneratedHost]) -> (newCount: Int, overwriteCount: Int) {
        var newCount = 0
        var overwriteCount = 0
        for g in generated {
            let matched = parsedBlocks.contains { block in
                block.hostNames.contains(where: { $0.lowercased() == g.name.lowercased() })
                    || (block.hostName.map { $0.lowercased() == g.hostName.lowercased() } ?? false)
            }
            if matched { overwriteCount += 1 } else { newCount += 1 }
        }
        return (newCount, overwriteCount)
    }

    /// 끝쪽의 연속 빈 줄을 제거.
    private static func trimTrailingBlank(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result
    }

    // MARK: - 기존 config 블록 파싱 (원형 보존)

    /// 원형 라인을 보존한 한 블록 (`Host …` 부터 다음 Host 직전까지).
    private struct RawBlock {
        var lines: [String]
        var hostNames: [String]
        var hostName: String?
    }

    /// config 를 preamble(첫 Host 이전) + Host 블록들로 쪼갠다. 라인은 원형 유지.
    private static func parseBlocks(_ text: String) -> (preamble: [String], blocks: [RawBlock]) {
        var preamble: [String] = []
        var blocks: [RawBlock] = []
        var current: RawBlock?

        for rawLine in text.components(separatedBy: "\n") {
            let (key, value) = keyAndValue(of: rawLine)
            if key?.lowercased() == "host" {
                if let c = current { blocks.append(c) }
                current = RawBlock(
                    lines: [rawLine],
                    hostNames: (value ?? "")
                        .components(separatedBy: .whitespaces)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    hostName: nil
                )
            } else if current == nil {
                preamble.append(rawLine)
            } else {
                current!.lines.append(rawLine)
                if key?.lowercased() == "hostname", let v = value, !v.isEmpty {
                    current!.hostName = v
                }
            }
        }
        if let c = current { blocks.append(c) }
        return (preamble, blocks)
    }

    /// 한 줄에서 (key, value) 추출. 주석/빈 줄은 (nil, nil). `key=value`/`key value` 모두 지원.
    private static func keyAndValue(of rawLine: String) -> (String?, String?) {
        // 인라인 주석 제거(따옴표 밖 #)
        var inQuote = false
        var stripped = ""
        for ch in rawLine {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            stripped.append(ch)
        }
        let line = stripped.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return (nil, nil) }
        if let eq = line.firstIndex(of: "=") {
            let firstWS = line.firstIndex { $0 == " " || $0 == "\t" }
            if firstWS == nil || eq < firstWS! {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                return (key, dequote(value))
            }
        }
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
        if parts.count == 2 {
            return (String(parts[0]), dequote(String(parts[1]).trimmingCharacters(in: .whitespaces)))
        }
        return (parts.first.map(String.init), nil)
    }

    private static func dequote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: - IO 헬퍼

    private static func ensureDirectory(_ url: URL, permissions: Int16) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: NSNumber(value: permissions)])
            } catch {
                throw SSHConfigExportError.ioFailure("디렉토리 생성 실패(\(url.lastPathComponent)): \(String(describing: error))")
            }
        }
    }

    /// 백업 파일명용 타임스탬프 (yyyyMMdd-HHmmss).
    private static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
