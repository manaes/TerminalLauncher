//
//  EntryEditorSheet.swift
//  PathDock
//
//  새 항목 추가 / 기존 항목 편집을 위한 시트.
//  v3: kind(명령어 / SSH / VNC) 별 입력 폼을 동적으로 노출한다.
//  명령어 본문은 DraggableCommandEditor 로 파일 드롭을 받아 {{att:<uuid>}} 토큰을 삽입한다.
//  첨부는 이 시트가 직접 store.attachmentStore.write 를 호출해 즉시 디스크에 반영.
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

    // 공통 필드
    @State private var kind: EntryKind = .command
    @State private var name: String = ""
    @State private var note: String = ""
    /// 현재 편집 중인 entry 의 첨부 메타 목록 (저장 시 함께 commit)
    @State private var attachments: [Attachment] = []

    // 명령어 타입 전용
    @State private var path: String = ""
    @State private var commandsText: String = ""

    // 원격 공통
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    // SSH 전용
    @State private var sshAuth: RemoteAuth = .password
    @State private var keyAttachmentId: UUID?
    /// `~/.ssh/config` 에서 읽어온 Host 목록 (kind == .remoteSSH 일 때만 채워둠)
    @State private var sshConfigHosts: [SSHConfigHost] = []

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
            _kind = State(initialValue: entry.kind)
            _name = State(initialValue: entry.name)
            _note = State(initialValue: entry.note ?? "")
            _attachments = State(initialValue: entry.attachments)
            // 명령어 필드 — 다른 kind 라 해도 값이 있으면 보존 (사용자가 다시 .command 로 돌려놓을 수 있음)
            _path = State(initialValue: entry.path)
            _commandsText = State(initialValue: entry.commands.joined(separator: "\n"))
            // 원격 필드
            _host = State(initialValue: entry.host ?? "")
            _portText = State(initialValue: entry.port.map { String($0) } ?? "")
            _username = State(initialValue: entry.username ?? "")
            _password = State(initialValue: entry.password ?? "")
            _sshAuth = State(initialValue: entry.auth ?? .password)
            _keyAttachmentId = State(initialValue: entry.keyAttachmentId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNewMode ? "새 항목 추가" : "항목 편집")
                .font(.title3.bold())
                .padding(.bottom, 12)

            // 타입 선택 — 최상단에 segmented picker
            Picker("타입", selection: $kind) {
                Text("명령어").tag(EntryKind.command)
                Text("SSH").tag(EntryKind.remoteSSH)
                Text("VNC").tag(EntryKind.remoteVNC)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)

            Form {
                // 공통: 이름
                Section {
                    TextField("이름", text: $name, prompt: Text("예: 예시 항목"))
                }

                // kind 별 본문
                switch kind {
                case .command:
                    commandSections
                case .remoteSSH:
                    sshSections
                case .remoteVNC:
                    vncSections
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
        .frame(minWidth: 560, minHeight: 560)
        .onAppear { loadSSHConfigIfNeeded() }
        .onChange(of: kind) { _ in loadSSHConfigIfNeeded() }
        .alert(
            "알림",
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

    // MARK: - kind 별 섹션

    /// 명령어 타입 입력 섹션
    @ViewBuilder
    private var commandSections: some View {
        Section {
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
    }

    /// SSH 타입 입력 섹션
    @ViewBuilder
    private var sshSections: some View {
        // ~/.ssh/config 의 Host 항목을 골라 폼을 자동 채움
        Section("ssh config") {
            if sshConfigHosts.isEmpty {
                Text("~/.ssh/config 에 등록된 Host 가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(sshConfigHosts) { h in
                        Button {
                            applySSHConfigHost(h)
                        } label: {
                            Text(sshConfigMenuLabel(for: h))
                        }
                    }
                } label: {
                    Label("ssh config 에서 가져오기", systemImage: "square.and.arrow.down")
                }
                .help("선택한 Host 의 HostName / Port / User / IdentityFile 을 폼에 채웁니다.")
            }
        }

        Section("연결 정보") {
            TextField("주소(host)", text: $host, prompt: Text("예: 192.168.0.10 또는 example.com"))
                .font(.system(.body, design: .monospaced))
            TextField("포트", text: $portText, prompt: Text("기본 22"))
                .font(.system(.body, design: .monospaced))
            TextField("사용자명 (옵션)", text: $username, prompt: Text("예: ubuntu"))
                .font(.system(.body, design: .monospaced))
        }

        Section("인증") {
            Picker("방식", selection: $sshAuth) {
                Text("패스워드").tag(RemoteAuth.password)
                Text("키파일").tag(RemoteAuth.keyfile)
            }
            .pickerStyle(.segmented)

            if sshAuth == .password {
                SecureField("패스워드", text: $password)
            } else {
                keyfileRow
            }
        }
    }

    /// VNC 타입 입력 섹션
    @ViewBuilder
    private var vncSections: some View {
        Section("연결 정보") {
            TextField("주소(host)", text: $host, prompt: Text("예: 192.168.0.10"))
                .font(.system(.body, design: .monospaced))
            TextField("포트", text: $portText, prompt: Text("기본 5900"))
                .font(.system(.body, design: .monospaced))
            TextField("사용자명 (옵션)", text: $username)
                .font(.system(.body, design: .monospaced))
            SecureField("패스워드 (옵션)", text: $password)
        }
    }

    /// SSH 키파일 선택/표시 행
    @ViewBuilder
    private var keyfileRow: some View {
        if let id = keyAttachmentId, let att = attachments.first(where: { $0.id == id }) {
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
                    removeKeyfile(att)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("키파일 제거")
            }
        } else {
            Button("키파일 선택…") {
                pickKeyfile()
            }
        }
    }

    // MARK: - ssh config import

    /// kind 가 SSH 일 때 ~/.ssh/config 를 한 번 로드한다. 이미 로드돼 있으면 no-op.
    private func loadSSHConfigIfNeeded() {
        guard kind == .remoteSSH else { return }
        if sshConfigHosts.isEmpty {
            sshConfigHosts = SSHConfigParser.loadDefault()
        }
    }

    /// 메뉴 라벨 — "name — user@hostname:port"
    private func sshConfigMenuLabel(for h: SSHConfigHost) -> String {
        var subtitle = h.effectiveHost
        if let u = h.user, !u.isEmpty {
            subtitle = "\(u)@\(subtitle)"
        }
        if let p = h.port {
            subtitle = "\(subtitle):\(p)"
        }
        if h.name == subtitle {
            return h.name
        }
        return "\(h.name) — \(subtitle)"
    }

    /// ssh config 의 한 Host 를 현재 폼에 반영한다.
    /// IdentityFile 이 있으면 그 파일을 자동으로 첨부 시스템에 import 하고 keyfile 모드로 전환한다.
    private func applySSHConfigHost(_ h: SSHConfigHost) {
        host = h.effectiveHost
        if let p = h.port {
            portText = String(p)
        } else {
            portText = ""
        }
        if let u = h.user {
            username = u
        } else {
            username = ""
        }
        if let keyPath = h.identityFilePath {
            let url = URL(fileURLWithPath: keyPath)
            if FileManager.default.fileExists(atPath: url.path) {
                // ingestKeyfile 이 첨부 시스템에 import + keyAttachmentId 설정
                ingestKeyfile(from: url)
                sshAuth = .keyfile
            } else {
                sshAuth = .keyfile
                alertMessage = "IdentityFile 경로의 파일을 찾을 수 없습니다:\n\(keyPath)\n\"키파일 선택…\" 으로 직접 지정해주세요."
            }
        } else {
            // IdentityFile 미지정 → 패스워드 모드로
            sshAuth = .password
        }
    }

    // MARK: - Helpers

    private var isNewMode: Bool {
        if case .new = mode { return true }
        return false
    }

    /// 저장 활성화 조건 — kind 별로 다른 필수 입력을 검사
    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        switch kind {
        case .command:
            return !path.trimmingCharacters(in: .whitespaces).isEmpty
        case .remoteSSH:
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // 키파일 모드면 keyAttachmentId 가 반드시 있어야 함
            if sshAuth == .keyfile {
                return keyAttachmentId != nil
            }
            return true
        case .remoteVNC:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 폴더 선택 다이얼로그 (명령어 타입)
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

    /// 키파일 선택 다이얼로그 (SSH keyfile 모드)
    private func pickKeyfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "SSH 키파일 선택"
        panel.prompt = "선택"
        panel.showsHiddenFiles = true   // ~/.ssh 내부 파일 접근 편의
        if panel.runModal() == .OK, let url = panel.url {
            ingestKeyfile(from: url)
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

    /// 첨부 제거 (명령어 타입) — 디스크에서 즉시 삭제 + 메타 제거 + 본문 토큰 자동 제거
    private func removeAttachment(_ att: Attachment) {
        store.attachmentStore.remove(id: att.id)
        attachments.removeAll { $0.id == att.id }
        let token = "{{att:\(att.id.uuidString)}}"
        commandsText = commandsText.replacingOccurrences(of: token, with: "")
        // 키파일로 지정돼 있던 첨부였다면 참조 해제
        if keyAttachmentId == att.id {
            keyAttachmentId = nil
        }
    }

    /// SSH 키파일 첨부를 받아 attachments + keyAttachmentId 에 등록
    private func ingestKeyfile(from url: URL) {
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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            alertMessage = "파일을 읽을 수 없습니다.\n\(error.localizedDescription)"
            return
        }
        let att = Attachment(originalName: url.lastPathComponent, sizeBytes: Int64(data.count))
        do {
            try store.attachmentStore.write(id: att.id, plaintext: data)
        } catch let e as AttachmentError {
            alertMessage = e.errorDescription ?? "키파일 저장 실패"
            return
        } catch {
            alertMessage = "키파일 저장 실패\n\(error.localizedDescription)"
            return
        }
        // 이전 키파일이 있었으면 정리 (시트 안에서만 새로 추가된 첨부에 한해)
        if let prevId = keyAttachmentId, prevId != att.id {
            removeKeyfileFromState(id: prevId)
        }
        attachments.append(att)
        keyAttachmentId = att.id
    }

    /// 키파일 첨부 제거 (디스크 + 메타 + 참조)
    private func removeKeyfile(_ att: Attachment) {
        store.attachmentStore.remove(id: att.id)
        attachments.removeAll { $0.id == att.id }
        keyAttachmentId = nil
    }

    /// 키파일 교체 시 이전 첨부만 조용히 정리 (UI 갱신 동반 X)
    private func removeKeyfileFromState(id: UUID) {
        store.attachmentStore.remove(id: id)
        attachments.removeAll { $0.id == id }
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
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToStore: String? = trimmedNote.isEmpty ? nil : trimmedNote

        // 명령어 라인 정리 — 명령어 타입에서만 의미
        let cmdLines = commandsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 원격 공통 — host, port, username, password
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let parsedPort = Int(portText.trimmingCharacters(in: .whitespaces))
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let pw = password    // SecureField 의 값은 그대로 보존

        // kind 와 무관한 필드는 nil/빈값으로 정리해 저장
        // (UI state 는 유지하되, 디스크에는 현재 kind 에 의미있는 값만 저장)
        let finalPath: String
        let finalCommands: [String]
        let finalAttachments: [Attachment]
        let finalHost: String?
        let finalPort: Int?
        let finalUsername: String?
        let finalAuth: RemoteAuth?
        let finalPassword: String?
        let finalKeyId: UUID?

        switch kind {
        case .command:
            finalPath = path.trimmingCharacters(in: .whitespaces)
            finalCommands = cmdLines
            finalAttachments = attachments
            finalHost = nil
            finalPort = nil
            finalUsername = nil
            finalAuth = nil
            finalPassword = nil
            finalKeyId = nil
        case .remoteSSH:
            finalPath = ""
            finalCommands = []
            // SSH 의 경우 attachments 중 키파일만 보존, 다른 잔여 첨부는 제거
            if sshAuth == .keyfile, let keyId = keyAttachmentId,
               let keyAtt = attachments.first(where: { $0.id == keyId }) {
                // 다른 첨부 디스크 정리
                for a in attachments where a.id != keyId {
                    store.attachmentStore.remove(id: a.id)
                }
                finalAttachments = [keyAtt]
                finalKeyId = keyId
            } else {
                // password 모드면 모든 첨부 제거
                for a in attachments {
                    store.attachmentStore.remove(id: a.id)
                }
                finalAttachments = []
                finalKeyId = nil
            }
            finalHost = trimmedHost
            finalPort = parsedPort
            finalUsername = trimmedUser.isEmpty ? nil : trimmedUser
            finalAuth = sshAuth
            finalPassword = (sshAuth == .password && !pw.isEmpty) ? pw : nil
        case .remoteVNC:
            finalPath = ""
            finalCommands = []
            // VNC 는 첨부 사용 안 함 — 잔여 첨부 모두 정리
            for a in attachments {
                store.attachmentStore.remove(id: a.id)
            }
            finalAttachments = []
            finalHost = trimmedHost
            finalPort = parsedPort
            finalUsername = trimmedUser.isEmpty ? nil : trimmedUser
            finalAuth = nil
            finalPassword = pw.isEmpty ? nil : pw
            finalKeyId = nil
        }

        let entry: PathEntry
        if let original = originalEntry {
            entry = PathEntry(
                id: original.id,
                kind: kind,
                name: trimmedName,
                path: finalPath,
                commands: finalCommands,
                sortIndex: original.sortIndex,
                note: noteToStore,
                createdAt: original.createdAt,
                updatedAt: Date(),
                attachments: finalAttachments,
                host: finalHost,
                port: finalPort,
                username: finalUsername,
                auth: finalAuth,
                password: finalPassword,
                keyAttachmentId: finalKeyId
            )
            // 편집 모드: 원본에 있었지만 이번 편집에서 제거된 첨부는 디스크에서도 삭제
            let currentIds = Set(finalAttachments.map { $0.id })
            for old in original.attachments where !currentIds.contains(old.id) {
                store.attachmentStore.remove(id: old.id)
            }
        } else {
            entry = PathEntry(
                id: workingEntryId,
                kind: kind,
                name: trimmedName,
                path: finalPath,
                commands: finalCommands,
                sortIndex: 0,
                note: noteToStore,
                createdAt: Date(),
                updatedAt: Date(),
                attachments: finalAttachments,
                host: finalHost,
                port: finalPort,
                username: finalUsername,
                auth: finalAuth,
                password: finalPassword,
                keyAttachmentId: finalKeyId
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
