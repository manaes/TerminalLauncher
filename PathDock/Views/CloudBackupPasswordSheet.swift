//
//  CloudBackupPasswordSheet.swift
//  PathDock
//
//  iCloud 백업을 처음 설정할 때 백업 파일을 보호할 비밀번호를 입력받는 시트.
//  확정 시 비밀번호는 Keychain 에 저장되어 이후 원탭 백업/복원에 재사용된다.
//

import SwiftUI

struct CloudBackupPasswordSheet: View {
    /// 사용자가 비밀번호를 확정했을 때 호출. 빈/불일치면 호출되지 않음.
    let onConfirm: (_ password: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var password1: String = ""
    @State private var password2: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("iCloud 백업 비밀번호 설정")
                .font(.title3.bold())

            Text("iCloud 에 올라가는 백업 파일을 암호화할 비밀번호입니다. 앱 비밀번호와 무관하며, 이 비밀번호는 Keychain 에 저장되어 이후 자동/수동 백업·복원에 재사용됩니다.\n\n⚠️ 비밀번호를 잊으면 백업을 복원할 수 없습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("비밀번호", text: $password1).textFieldStyle(.roundedBorder)
            SecureField("비밀번호 재입력", text: $password2).textFieldStyle(.roundedBorder)

            if !password1.isEmpty || !password2.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(passwordsMatch ? .green : .red)
                    Text(passwordsMatch ? "비밀번호 일치" : "비밀번호 불일치")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("설정 후 백업") {
                    let pw = password1
                    password1 = ""
                    password2 = ""
                    onConfirm(pw)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!passwordsMatch)
            }
        }
        .padding(20)
        .frame(width: 440, height: 300)
    }

    private var passwordsMatch: Bool {
        !password1.isEmpty && password1 == password2
    }
}

#Preview {
    CloudBackupPasswordSheet { _ in }
}
