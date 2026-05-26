//
//  FirstRunSetupView.swift
//  PathDock
//
//  첫 실행 시 보안 모드(평문/암호화)를 결정하는 시작 화면.
//  결정 후에는 SecurityStore 가 security.plist 를 생성하고 모드가 고정된다.
//

import SwiftUI

struct FirstRunSetupView: View {
    /// 결정 후 호출 — Bool true 면 암호화 모드, false 면 평문 모드.
    /// 비밀번호는 암호화 모드일 때만 의미가 있다.
    /// backend: 첫 실행 시 사용자가 선택한 터미널 백엔드.
    let onComplete: (_ enableEncryption: Bool, _ password: String, _ backend: TerminalBackend) -> Void

    @State private var password1: String = ""
    @State private var password2: String = ""
    @State private var working = false
    @State private var errorMessage: String?
    /// 사용자가 선택한 터미널 백엔드 (기본 Terminal)
    @State private var backend: TerminalBackend = .terminal
    /// iTerm2 미설치 알럿 표시 여부
    @State private var showITermMissingAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("명령어 / 첨부파일 암호화")
                .font(.title2.bold())

            Text("등록할 명령어와 첨부 파일을 디스크에 저장할 방식을 선택하세요. 한번 결정하면 변경하려면 전체 초기화가 필요합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 비밀번호 입력 영역
            VStack(alignment: .leading, spacing: 8) {
                SecureField("암호 입력", text: $password1)
                    .textFieldStyle(.roundedBorder)
                SecureField("암호 재입력", text: $password2)
                    .textFieldStyle(.roundedBorder)

                // 일치 여부 실시간 표시
                if !password1.isEmpty || !password2.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(passwordsMatch ? .green : .red)
                        Text(passwordsMatch ? "암호가 일치합니다." : "암호가 일치하지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 경고
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("암호 분실 시 데이터 복구가 불가능합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            // 터미널 백엔드 선택
            VStack(alignment: .leading, spacing: 6) {
                Text("터미널")
                    .font(.subheadline.bold())
                Picker("", selection: $backend) {
                    ForEach(TerminalBackend.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if backend == .iterm2 && !LauncherUtil.isITermInstalled() {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("iTerm2 가 설치되어 있지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("설치하기") {
                            if let url = URL(string: "https://iterm2.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            HStack {
                Button("암호화하지 않기") {
                    submit(enable: false)
                }
                .disabled(working)

                Spacer()

                Button("암호화 활성화") {
                    submit(enable: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canActivate || working)
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
        .alert(
            "iTerm2 가 설치되어 있지 않습니다.",
            isPresented: $showITermMissingAlert
        ) {
            Button("확인", role: .cancel) { }
            Button("설치하기") {
                if let url = URL(string: "https://iterm2.com/") {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: {
            Text("iterm2.com 에서 설치하거나 Terminal 을 선택하세요.")
        }
    }

    /// 두 SecureField 값이 같은지
    private var passwordsMatch: Bool {
        !password1.isEmpty && password1 == password2
    }

    /// 활성화 가능 조건
    private var canActivate: Bool {
        passwordsMatch
    }

    /// 공통 제출 처리. iTerm2 선택 + 미설치면 알럿만 띄우고 진행하지 않는다.
    private func submit(enable: Bool) {
        // iTerm2 선택 + 미설치면 진행 불가
        if backend == .iterm2 && !LauncherUtil.isITermInstalled() {
            showITermMissingAlert = true
            return
        }
        if enable {
            guard canActivate else { return }
            working = true
            errorMessage = nil
            // KDF 는 600,000 iter 라서 메인 스레드에서 직접 돌리면 UI 가 끊긴다.
            // 호출자(PathDockApp)가 백그라운드에서 처리하도록 콜백만 던진다.
            let pw = password1
            // 입력 필드 즉시 비움 (Swift String 보장 한계는 있음)
            password1 = ""
            password2 = ""
            onComplete(true, pw, backend)
        } else {
            onComplete(false, "", backend)
        }
    }
}

#Preview {
    FirstRunSetupView { _, _, _ in }
}
