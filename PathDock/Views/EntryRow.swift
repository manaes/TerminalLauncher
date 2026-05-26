//
//  EntryRow.swift
//  PathDock
//
//  메인 리스트의 단일 행. kind 별 아이콘 + 뱃지 + 부제목을 표시한다.
//

import SwiftUI

struct EntryRow: View {
    let entry: PathEntry
    /// iTerm2 백엔드에서 해당 entry 의 세션이 살아있는지 여부.
    /// 부모(ContentView)가 폴링 결과로 갱신한다. Terminal.app 백엔드면 항상 false.
    var sessionAlive: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.headline)
                    // 원격 타입에만 뱃지 표시
                    if let label = badgeLabel {
                        Text(label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(badgeColor)
                    }
                    // iTerm2 세션이 살아있을 때만 인디케이터 표시
                    if sessionAlive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("실행 중")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 표시 분기

    /// 좌측 아이콘 (kind 별)
    private var iconName: String {
        switch entry.kind {
        case .command:   return "terminal"
        case .remoteSSH: return "network"
        case .remoteVNC: return "display"
        }
    }

    /// 뱃지 라벨 (명령어 타입은 생략)
    private var badgeLabel: String? {
        switch entry.kind {
        case .command:   return nil
        case .remoteSSH: return "SSH"
        case .remoteVNC: return "VNC"
        }
    }

    /// 뱃지 색상
    private var badgeColor: Color {
        switch entry.kind {
        case .command:   return .secondary
        case .remoteSSH: return .green
        case .remoteVNC: return .blue
        }
    }

    /// 첫 줄 부제 — 명령어는 경로, 원격은 user@host:port
    private var subtitleText: String? {
        switch entry.kind {
        case .command:
            return entry.path.isEmpty ? nil : entry.path
        case .remoteSSH, .remoteVNC:
            return remoteEndpointText
        }
    }

    /// 두 번째 줄 — 명령어 타입에서만 명령어 미리보기
    private var detailText: String? {
        switch entry.kind {
        case .command:
            return commandSummary ?? "(명령어 없음)"
        case .remoteSSH, .remoteVNC:
            return nil
        }
    }

    /// user@host:port 합성
    private var remoteEndpointText: String? {
        guard let host = entry.host, !host.isEmpty else {
            return "(주소 없음)"
        }
        let user = entry.username ?? ""
        let userPrefix = user.isEmpty ? "" : "\(user)@"
        let portSuffix: String
        if let port = entry.port {
            portSuffix = ":\(port)"
        } else {
            // 기본 포트 표시
            switch entry.kind {
            case .remoteSSH: portSuffix = ":22"
            case .remoteVNC: portSuffix = ":5900"
            case .command:   portSuffix = ""
            }
        }
        return "\(userPrefix)\(host)\(portSuffix)"
    }

    /// 명령어 미리보기 한 줄. 예: "→ bundle install && bundle exec ..."
    private var commandSummary: String? {
        let cleaned = entry.commands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "→ " + cleaned.joined(separator: " && ")
    }
}

#Preview {
    VStack(alignment: .leading) {
        EntryRow(entry: PathEntry(
            name: "Example Project",
            path: "~/Example/Path",
            commands: ["echo hello", "ls -la"]
        ))
        EntryRow(entry: PathEntry(
            kind: .remoteSSH,
            name: "My Server",
            host: "192.168.0.10",
            port: 22,
            username: "ubuntu"
        ))
        EntryRow(entry: PathEntry(
            kind: .remoteVNC,
            name: "Mac mini",
            host: "192.168.0.20",
            port: 5900
        ))
    }
    .padding()
}
