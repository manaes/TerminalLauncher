//
//  ImportPasswordSheet.swift
//  PathDock
//
//  Import 대상 `.pathdock` 의 비밀번호 입력 시트.
//

import SwiftUI

struct ImportPasswordSheet: View {
    /// 사용자가 비밀번호를 확정했을 때 호출.
    let onConfirm: (_ password: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import 비밀번호 입력")
                .font(.title3.bold())

            Text("선택한 .pathdock 파일을 복호화할 비밀번호를 입력하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            if let msg = errorMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }

    private func confirm() {
        guard !password.isEmpty else { return }
        let pw = password
        password = ""
        onConfirm(pw)
        dismiss()
    }
}

#Preview {
    ImportPasswordSheet { _ in }
}
