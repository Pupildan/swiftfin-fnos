//
// FNOSLoginView.swift
// 飞牛影视（fnOS）原生登录页 —— 替代 Swiftfin 登录栈。
//

import SwiftUI

struct FNOSLoginView: View {

    @ObservedObject var auth: FNOSAuthStore

    @State private var serverInput = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Text("飞牛影视")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 16) {
                    fieldLabel("服务器地址（如 192.168.10.120:8005）")
                    TextField("192.168.10.120:8005", text: $serverInput)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    fieldLabel("用户名")
                    TextField("", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    fieldLabel("密码")
                    SecureField("", text: $password)
                }
                .frame(maxWidth: 640)

                if let errorMessage {
                    Text("❗️ \(errorMessage)")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await login() }
                } label: {
                    Group {
                        if isLoggingIn {
                            ProgressView()
                        } else {
                            Text("登录")
                                .font(.headline)
                        }
                    }
                    .frame(width: 320, height: 64)
                }
                .buttonStyle(.card)
                .disabled(isLoggingIn || serverInput.isEmpty || username.isEmpty)

                Text("FNOS v\(FNOSAdapterBuild.version)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(40)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    private func login() async {
        isLoggingIn = true
        errorMessage = nil
        do {
            let credentials = try await FNOSAuthClient.login(
                serverInput: serverInput,
                username: username,
                password: password
            )
            auth.save(credentials)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoggingIn = false
    }
}
