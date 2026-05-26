//
//  EntryEditorSheet.swift
//  PathDock
//
//  새 항목 추가 / 기존 항목 편집을 위한 시트.
//  명령어 본문은 DraggableCommandEditor 로 파일 드롭을 받아 {{att:<uuid>}} 토큰을 삽입한다.
//  첨부는 이 시트가 직접 store.addAttachment / removeAttachment 를 호출해 즉시 디스크에 반영.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EntryEditorSheet: View {
    enum Mode {
        case new
        case edit(PathEntry)
    }

    let mode: Mode
    /// 저장 콜백. 호출자가 store.add / store.update 를 결정한다.
    let onSave: (PathEntry) -> Void

    @EnvironmentObject private var store: EntryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var path: String = ""
    @State private var commandsText: String = ""
    @State private var note: String = ""
    /// 현재 편집 중인 entry 의 첨부 메타 목록 (저장 시 함께 commit)
    @State private var attachments: [Attachment] = []
    /// 사이즈 초과 등의 사용자 알림
    @State private var alertMessage: String?

    /// 편집기 컨트롤러 — 토큰 삽입에 사용
    @StateObject private var editorController = CommandEditorController()

    /// 편집 모드일 때 보존할 기존 메타데이터
    private let originalEntry: PathEntry?
    /// 시트가 열려 있는 동안의 entry id (신규 모드면 즉석 발급)
    private let workingEntryId: UUID

    init(mode: Mode, onSave: @escaping (PathEntry) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            self.originalEntry = nil
            self.workingEntryId = UUID()
        case .edit(let entry):
            self.originalEntry = entry
            self.workingEntryId = entry.id
            _name = State(initialValue: entry.name)
            _path = State(initialValue: entry.path)
            _commandsText = State(initialValue: entry.commands.joined(separator: "\n"))
            _note = State(initialValue: entry.note ?? "")
            _attachments = State(initialValue: entry.attachments)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNewMode ? "새 경로 추가" : "경로 편집")
                .font(.title3.bold())
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("이름", text: $name, prompt: Text("예: Example Project"))

                    HStack(spacing: 8) {
                        TextField("경로", text: $path, prompt: Text("예: ~/Example/Path"))
                            .font(.system(.body, design: .monospaced))
                        Button("폴더 선택…") {
                            pickFolder()
                        }
                    }
                }

                Section("실행할 명령어 (한 줄에 하나, 파일 드롭 시 첨부 토큰 삽입)") {
                    DraggableCommandEditor(
                        text: $commandsText,
                        onDropFile: handleFileDrop,
                        controller: editorController
                    )
                    .frame(minHeight: 130)
                }

                if !attachments.isEmpty {
                    Section("첨부 파일") {
                        ForEach(attachments) { att in
                            HStack(spacing: 8) {
                                Image(nsImage: iconForFilename(att.originalName))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(att.originalName)
                                        .lineLimit(1)
                                    Text(formatBytes(att.sizeBytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    removeAttachment(att)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("첨부 제거")
                            }
                        }
                    }
                }

                Section("메모 (선택)") {
                    TextField("메모", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("취소") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("저장") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .alert(
            "첨부 추가 실패",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            ),
            presenting: alertMessage
        ) { _ in
            Button("확인") { alertMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Helpers

    private var isNewMode: Bool {
        if case .new = mode { return true }
        return false
    }

    /// 저장 활성화 조건
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 폴더 선택 다이얼로그
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "작업 디렉토리 선택"
        panel.prompt = "선택"
        if panel.runModal() == .OK, let url = panel.url {
            self.path = url.path
        }
    }

    // MARK: - Attachment 처리

    /// 파일 드롭 콜백: 크기 검증 → 디스크 저장 → 메타 push → 토큰 삽입
    private func handleFileDrop(_ url: URL) {
        // 1) 사이즈 검증 (URLResourceValues.fileSize 활용)
        let size: Int64
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            size = Int64(values.fileSize ?? 0)
        } catch {
            alertMessage = "파일 정보를 읽을 수 없습니다.\n\(error.localizedDescription)"
            return
        }
        if size > AttachmentStore.maxBytes {
            let actualMB = Double(size) / (1024 * 1024)
            let limitMB = Double(AttachmentStore.maxBytes) / (1024 * 1024)
            alertMessage = String(format: "파일이 너무 큽니다.\n(%.1f MB / 상한 %.0f MB)", actualMB, limitMB)
            return
        }
        // 2) byte 로드
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            alertMessage = "파일을 읽을 수 없습니다.\n\(error.localizedDescription)"
            return
        }
        // 3) AttachmentStore 에 직접 저장 (entry 메타에는 시트 임시 상태로만 보관)
        let att = Attachment(originalName: url.lastPathComponent, sizeBytes: Int64(data.count))
        do {
            try store.attachmentStore.write(id: att.id, plaintext: data)
        } catch let e as AttachmentError {
            alertMessage = e.errorDescription ?? "첨부 저장 실패"
            return
        } catch {
            alertMessage = "첨부 저장 실패\n\(error.localizedDescription)"
            return
        }
        // 4) 메타 push + 토큰 삽입
        attachments.append(att)
        let token = "{{att:\(att.id.uuidString)}}"
        editorController.insertAtCaret(token)
    }

    /// 첨부 제거 — 디스크에서 즉시 삭제 + 메타 제거 + 본문 토큰 자동 제거
    private func removeAttachment(_ att: Attachment) {
        store.attachmentStore.remove(id: att.id)
        attachments.removeAll { $0.id == att.id }
        let token = "{{att:\(att.id.uuidString)}}"
        commandsText = commandsText.replacingOccurrences(of: token, with: "")
    }

    /// 취소 시 — 이번 시트에서 새로 추가했던 첨부들은 사용자가 의도하지 않은 잔존을 막기 위해 정리한다.
    /// 단, 편집 모드에서 originalEntry 에 이미 있던 첨부는 유지해야 한다.
    private func cancel() {
        if let original = originalEntry {
            let originalIds = Set(original.attachments.map { $0.id })
            for att in attachments where !originalIds.contains(att.id) {
                store.attachmentStore.remove(id: att.id)
            }
        } else {
            // 신규 모드: 이번 시트에서 추가한 건 모두 잔존하지 않도록 삭제
            for att in attachments {
                store.attachmentStore.remove(id: att.id)
            }
        }
        dismiss()
    }

    /// 저장 → 콜백 후 시트 닫기
    private func save() {
        let lines = commandsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToStore: String? = trimmedNote.isEmpty ? nil : trimmedNote

        let entry: PathEntry
        if let original = originalEntry {
            entry = PathEntry(
                id: original.id,
                name: name.trimmingCharacters(in: .whitespaces),
                path: path.trimmingCharacters(in: .whitespaces),
                commands: lines,
                sortIndex: original.sortIndex,
                note: noteToStore,
                createdAt: original.createdAt,
                updatedAt: Date(),
                attachments: attachments
            )
            // 편집 모드: 원본에 있었지만 이번 편집에서 제거된 첨부는 디스크에서도 삭제
            let currentIds = Set(attachments.map { $0.id })
            for old in original.attachments where !currentIds.contains(old.id) {
                store.attachmentStore.remove(id: old.id)
            }
        } else {
            entry = PathEntry(
                id: workingEntryId,
                name: name.trimmingCharacters(in: .whitespaces),
                path: path.trimmingCharacters(in: .whitespaces),
                commands: lines,
                sortIndex: 0,
                note: noteToStore,
                createdAt: Date(),
                updatedAt: Date(),
                attachments: attachments
            )
        }
        onSave(entry)
        dismiss()
    }

    // MARK: - 표시 헬퍼

    /// 파일명의 확장자만으로 아이콘을 얻는다. (평문 임시파일이 없으므로 UTType 기반 폴백 사용)
    private func iconForFilename(_ filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: ut)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    /// 바이트 사람 친화적 표기
    private func formatBytes(_ b: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useAll]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: b)
    }
}

#Preview {
    EntryEditorSheet(mode: .new) { _ in }
        .environmentObject(EntryStore(
            rootDir: FileManager.default.temporaryDirectory,
            encrypted: false,
            key: nil
        ))
}
