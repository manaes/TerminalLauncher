//
//  UnlockView.swift
//  PathDock
//
//  encrypted 모드인데 Keychain 에 마스터키가 없는 경우의 잠금 해제 화면.
//

import SwiftUI

struct UnlockView: View {
    /// 비밀번호로 잠금 해제 시도 — 성공/실패는 호출자가 결정한 후 결과를 다시 반영한다.
    let onUnlock: (_ password: String) -> Void

    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("PathDock 잠금 해제")
                    .font(.title3.bold())
            }

            Text("저장된 마스터키가 없습니다. 비밀번호를 입력해 잠금을 해제하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { attempt() }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("잠금 해제") {
                    attempt()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 420, height: 240)
    }

    private func attempt() {
        guard !password.isEmpty else { return }
        working = true
        errorMessage = nil
        let pw = password
        password = ""
        onUnlock(pw)
        // 호출자가 실패하면 reportFailure(...) 로 다시 알릴 수 있게 함.
        // 일단 working 은 즉시 풀어 다음 시도 허용.
        working = false
    }

    /// 호출자가 실패 시 호출해 메시지를 띄움
    mutating func reportFailure(_ message: String) {
        self.errorMessage = message
    }
}

#Preview {
    UnlockView { _ in }
}
