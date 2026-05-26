//
//  ExportPasswordSheet.swift
//  PathDock
//
//  Export 시 패키지 파일을 보호할 별도 비밀번호 입력 시트.
//

import SwiftUI

struct ExportPasswordSheet: View {
    /// 사용자가 비밀번호를 확정했을 때 호출. 빈 문자열이면 호출되지 않음.
    let onConfirm: (_ password: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var password1: String = ""
    @State private var password2: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export 비밀번호 설정")
                .font(.title3.bold())

            Text("패키지(.pathdock) 파일을 암호화할 비밀번호를 입력하세요. 앱 비밀번호와 무관합니다.")
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
                Button("Export") {
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
        .frame(width: 420, height: 240)
    }

    private var passwordsMatch: Bool {
        !password1.isEmpty && password1 == password2
    }
}

#Preview {
    ExportPasswordSheet { _ in }
}
