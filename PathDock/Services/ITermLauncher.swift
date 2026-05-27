//
//  ITermLauncher.swift
//  PathDock
//
//  iTerm2 백엔드 구현체.
//  - AppleScript 로 iTerm2 를 제어해 새 창/세션 생성, 살아있음 검사, 활성화, 종료를 수행한다.
//  - SSH 패스워드 자동 입력은 prefs.itermAutoTypePassword == true 일 때만 동작 (delay 2초 + write text).
//  - 명령어 합성 / 첨부 평문 풀기 / SSH 옵션 합성은 TerminalLauncher 의 헬퍼를 재사용한다.
//
//  ※ iTerm2 의 AppleScript dictionary 는 공개된 ‘Python-API 시대’ 이후의 사양을 기준으로 한다.
//     - `id of current session` : 세션 UUID 문자열
//     - `id of current window`  : 윈도우 ID 문자열
//     이 가정은 사용자의 manual test 로 검증한다 (실패 시 itermScriptFailed 로 surface).
//

import Foundation
import AppKit

/// iTerm2 백엔드 런처.
struct ITermLauncher: Launcher {

    // MARK: - Launcher

    @MainActor
    func launch(_ entry: PathEntry, attachmentStore: AttachmentStore, prefs: Preferences) throws -> ITermSession? {
        guard LauncherUtil.isITermInstalled() else {
            throw LaunchError.itermNotInstalled
        }

        // kind 별 셸 명령 합성 + 자동 입력 패스워드 준비
        let shellCommand: String
        // 자동 입력할 패스워드 (있을 때만). VNC 는 자기 자신이 처리하므로 여기로 안 옴.
        var autoTypePassword: String? = nil

        switch entry.kind {
        case .command:
            // ~ 확장 + 존재 여부 검증 + 토큰 치환 (TerminalLauncher 와 동일)
            let resolvedPath = NSString(string: entry.path).expandingTildeInPath
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir)
            guard exists else {
                throw LaunchError.pathNotFound(resolvedPath)
            }
            let prepared = try TerminalLauncher.prepareCommands(entry: entry, attachmentStore: attachmentStore)
            shellCommand = TerminalLauncher.buildShellCommand(path: resolvedPath, commands: prepared.commands)

        case .remoteSSH:
            // SSH 셸 명령은 TerminalLauncher 의 순수 합성 결과를 그대로 쓴다 (echo/클립보드 미포함).
            // 패스워드 전달은 iTerm2 정책에 맞게 여기서 결정한다.
            // - 자동 입력 ON : AppleScript write text 로 입력 (클립보드/echo 모두 X)
            // - 자동 입력 OFF: 패스워드만 클립보드에 복사해 사용자가 ⌘V (echo 는 X — 새 창에 안내 줄이 어색)
            let auth = entry.auth ?? .password
            if auth == .password {
                if prefs.itermAutoTypePassword,
                   let pw = entry.password, !pw.isEmpty {
                    autoTypePassword = pw
                } else {
                    _ = TerminalLauncher.copyPasswordToClipboardIfNeeded(for: entry)
                }
            }
            shellCommand = try TerminalLauncher.prepareSshShellCommand(
                entry: entry,
                attachmentStore: attachmentStore
            )

        case .remoteVNC:
            // VNC 는 NSWorkspace 가 처리. iTerm 백엔드와도 무관.
            try RemoteLauncher.launchVNC(entry)
            return nil
        }

        // iTerm2 새 창 생성 + 명령 실행 + id 반환
        let ids = try createNewWindowAndRun(shellCommand: shellCommand, autoTypePassword: autoTypePassword)
        return ITermSession(
            id: entry.id,
            sessionId: ids.sessionId,
            windowId: ids.windowId,
            startedAt: Date()
        )
    }

    @MainActor
    func isAlive(_ session: ITermSession) -> Bool {
        // 살아있는 모든 세션의 id 집합과 sessionId 일치 여부 검사.
        // iTerm 이 실행 중이 아니면 즉시 false (불필요하게 iTerm 을 깨우지 않음).
        guard isITermRunning() else { return false }
        let sidEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(session.sessionId)
        let script = """
        tell application "iTerm"
            set theFound to false
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is equal to "\(sidEsc)" then
                            set theFound to true
                            exit repeat
                        end if
                    end repeat
                    if theFound then exit repeat
                end repeat
                if theFound then exit repeat
            end repeat
            if theFound then
                return "1"
            else
                return "0"
            end if
        end tell
        """
        guard let result = try? runAppleScriptReturningString(script) else {
            return false
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    @MainActor
    func aliveSessionIds() -> Set<String> {
        // iTerm 이 실행 중이 아니면 살아있는 세션도 없음 — 불필요하게 깨우지 않는다.
        guard isITermRunning() else { return [] }
        // 모든 윈도우/탭/세션의 id 를 줄바꿈으로 이어 한 번에 수집한다.
        let script = """
        tell application "iTerm"
            set outIds to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set outIds to outIds & (id of s) & "\\n"
                    end repeat
                end repeat
            end repeat
            return outIds
        end tell
        """
        guard let result = try? runAppleScriptReturningString(script) else {
            return []
        }
        let ids = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    @MainActor
    func activate(_ session: ITermSession) throws {
        guard LauncherUtil.isITermInstalled() else {
            throw LaunchError.itermNotInstalled
        }
        let sidEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(session.sessionId)
        let widEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(session.windowId)
        // 윈도우 select → 세션 select → 앱 activate.
        let script = """
        tell application "iTerm"
            activate
            repeat with w in windows
                if (id of w) is equal to "\(widEsc)" then
                    select w
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is equal to "\(sidEsc)" then
                                select s
                                return "1"
                            end if
                        end repeat
                    end repeat
                end if
            end repeat
            return "0"
        end tell
        """
        _ = try runAppleScriptReturningString(script)
    }

    @MainActor
    func terminate(_ session: ITermSession) throws {
        guard LauncherUtil.isITermInstalled() else {
            throw LaunchError.itermNotInstalled
        }
        let sidEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(session.sessionId)
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is equal to "\(sidEsc)" then
                            close s
                            return "1"
                        end if
                    end repeat
                end repeat
            end repeat
            return "0"
        end tell
        """
        _ = try runAppleScriptReturningString(script)
    }

    // MARK: - Internal

    /// iTerm 이 현재 실행 중인지 NSRunningApplication 으로 확인.
    @MainActor
    private func isITermRunning() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2")
        return !running.isEmpty
    }

    /// iTerm2 새 창을 생성하고 명령 실행 후 (sessionId, windowId) 를 반환.
    /// autoTypePassword 가 있으면 delay 2초 후 write text 로 패스워드 + newline 입력.
    @MainActor
    private func createNewWindowAndRun(shellCommand: String, autoTypePassword: String?) throws -> (sessionId: String, windowId: String) {
        let cmdEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(shellCommand)

        // 자동 입력 패스워드는 그 자체로 별도 write text 로 보내야 안전 (셸 명령에 합성하지 않음).
        let autoTypeBlock: String
        if let pw = autoTypePassword, !pw.isEmpty {
            let pwEsc = TerminalLauncher.escapeForAppleScriptDoubleQuoted(pw)
            // ssh 가 프롬프트를 띄울 시간 확보 (휴리스틱 2초). newline 포함을 위해 별도 write text "" 가 아닌
            // 단일 write text 의 끝에 임의 newline 을 명시적으로 더하기 어려워 두 줄로 처리.
            autoTypeBlock = """
                delay 2.0
                tell newSess
                    write text "\(pwEsc)"
                end tell
            """
        } else {
            autoTypeBlock = ""
        }

        let script = """
        tell application "iTerm"
            activate
            set newWin to (create window with default profile)
            set newSess to (current session of newWin)
            set sessId to (id of newSess)
            set winId to (id of newWin)
            tell newSess
                write text "\(cmdEsc)"
            end tell
        \(autoTypeBlock)
            return sessId & "|" & winId
        end tell
        """

        let result: String
        do {
            result = try runAppleScriptReturningString(script)
        } catch let err as LaunchError {
            throw err
        } catch {
            throw LaunchError.itermScriptFailed(String(describing: error))
        }

        // "sessionId|windowId" 분할
        let parts = result.components(separatedBy: "|")
        guard parts.count >= 2 else {
            throw LaunchError.itermScriptFailed("세션/윈도우 id 파싱 실패: \(result)")
        }
        let sid = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let wid = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !wid.isEmpty else {
            throw LaunchError.itermScriptFailed("세션/윈도우 id 가 비어 있습니다: \(result)")
        }
        return (sid, wid)
    }

    /// AppleScript 실행. 결과 문자열을 반환. 실패 시 itermScriptFailed throw.
    @MainActor
    private func runAppleScriptReturningString(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.itermScriptFailed("AppleScript 컴파일에 실패했습니다.")
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                ?? "알 수 없는 오류"
            throw LaunchError.itermScriptFailed(msg)
        }
        return descriptor.stringValue ?? ""
    }
}
