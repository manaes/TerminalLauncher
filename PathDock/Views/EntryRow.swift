//
//  EntryRow.swift
//  PathDock
//
//  메인 리스트의 단일 행. 이름, 경로, 명령어 요약을 보여준다.
//

import SwiftUI

struct EntryRow: View {
    let entry: PathEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.headline)

                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let summary = commandSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("(명령어 없음)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
    EntryRow(entry: PathEntry(
        name: "Example Project",
        path: "~/Example/Path",
        commands: ["echo hello", "ls -la"]
    ))
    .padding()
}
