//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

struct SettingsView: View {

    #if os(iOS)
    @Default(.userAppearance)
    private var appearance
    #endif

    @Default(.userAccentColor)
    private var accentColor

    @InjectedObject(\.userSessionManager)
    private var userSessionManager: UserSessionManager

    @Router
    private var router

    // 飞牛适配实时诊断结果（打开设置页时现场查询）
    @State
    private var fnosDiagnostics: [String] = []

    // MARK: - Body

    var body: some View {
        Form(image: .jellyfinBlobBlue) {
            fnosSection
            serverSection
            customizeSection
            diagnosticsSection
        }
        .task {
            await runFnOSDiagnostics()
        }
        #if os(iOS)
        .navigationTitle(L10n.settings)
            .navigationBarCloseButton {
                router.dismiss()
            }
        #endif
    }

    // MARK: - 飞牛适配（版本 + 实时诊断）

    /// 版本号放在设置根页最顶部，用户无需翻找即可核对更新是否生效
    private var fnosSection: some View {
        Section {
            LabeledContent(
                "飞牛适配版",
                value: "FNOS \(FNOSAdapterBuild.version)"
            )

            LabeledContent(
                L10n.version,
                value: "\(UIApplication.appVersion ?? .emptyDash) (\(UIApplication.bundleVersion ?? .emptyDash))"
            )

            ForEach(fnosDiagnostics, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("飞牛适配")
        }
    }

    @MainActor
    private func runFnOSDiagnostics() async {
        guard let session = userSessionManager.currentSession else {
            fnosDiagnostics = ["未登录服务器"]
            return
        }

        var lines = ["服务器: \(session.server.effectiveServerURL.absoluteString)"]

        do {
            let parameters = Paths.GetUserViewsParameters(userID: session.user.id)
            let request = Paths.getUserViews(parameters: parameters)
            // 直接走 client.send 以拿到原始响应（头/体），用于判断适配层是否介入
            let response = try await session.client.send(request)

            if let http = response.response as? HTTPURLResponse {
                let shim = http.value(forHTTPHeaderField: "X-FnOS-Shim") ?? "无"
                lines.append("HTTP \(http.statusCode) · Shim: \(shim)")
            }

            // 原始请求是否带 Token=（canInit 命中前提）
            if let originalRequest = response.originalRequest,
               let auth = originalRequest.value(forHTTPHeaderField: "Authorization"),
               auth.contains("Token=")
            {
                lines.append("请求带Token: 是")
            } else {
                lines.append("请求带Token: 否（canInit 不会命中）")
            }

            let stats = FnOSCompatURLProtocol.stats()
            lines.append("拦截计数: canInit=\(stats.canInit) start=\(stats.startLoading) inject=\(stats.injected)")

            // 原始响应体里是否带 CollectionType（区分「未注入」与「注入但解码丢失」）
            if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let items = object["Items"] as? [[String: Any]]
            {
                let withKey = items.filter { $0["CollectionType"] != nil }.count
                lines.append("原始体含类型: \(withKey)/\(items.count)")
            }

            let views = response.value.items ?? []
            if views.isEmpty {
                lines.append("⚠️ 服务器返回 0 个媒体库")
            } else {
                for view in views {
                    let type = view.collectionType?.rawValue ?? "无类型"
                    lines.append("· \(view.name ?? "?") → \(type)")
                }
            }
        } catch {
            lines.append("⚠️ 查询失败: \(String(describing: error))")
        }

        fnosDiagnostics = lines
    }

    // MARK: - Server Section

    @ViewBuilder
    private var serverSection: some View {
        if let userSession = userSessionManager.currentSession {
            Section {
                UserProfileRow(user: userSession.user.data) {
                    router.route(to: .localUserSettings(user: userSession.user.data))
                }

                ChevronButton(
                    L10n.server,
                    action: {
                        router.route(to: .editLocalServer(server: userSession.server))
                    }
                ) {
                    Label {
                        Text(userSession.server.name)
                    } icon: {
                        if !userSession.server.isVersionCompatible {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                    }
                    .labelStyle(.sectionFooterWithImage(imageStyle: .orange))
                }

                #if os(iOS)
                if userSession.user.data.policy?.isAdministrator == true {
                    ChevronButton(L10n.dashboard) {
                        router.route(to: .adminDashboard)
                    }
                }
                #endif
            }
        }

        Section {
            Button {
                Task { @MainActor in
                    UIDevice.impact(.medium)
                    await userSessionManager.signOut(reason: .explicit)
                    router.dismiss()
                }
            } label: {
                Text(L10n.switchUser)
                    .frame(maxWidth: .infinity)
                    // Otherwise non-Liquid Glass only uses text height
                    .if(!UIDevice.supportsLiquidGlass) { button in
                        button
                            .frame(maxHeight: .infinity)
                    }
            }
            .listRowInsets(.zero)
            .listRowBackground(Color.clear)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
            .fontWeight(.semibold)
            .backport
            .buttonStyle(.glassProminent.shadow(false))
            .tint(accentColor)
            #if os(iOS)
            .controlSize(.large)
            #endif
        }
    }

    // MARK: - Customization Section

    private var customizeSection: some View {
        Section {
            #if os(iOS)
            Picker(L10n.appearance, selection: $appearance)
            #endif

            ColorPicker(L10n.accentColor, selection: $accentColor, supportsOpacity: false)

            ChevronButton(L10n.advanced) {
                router.route(to: .customizeSettingsView)
            }
        } header: {
            Text(L10n.customize)
        } footer: {
            Text(L10n.viewsMayRequireRestart)
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section {

            if ExperimentalSettingsView.isEnabled {
                ChevronButton(L10n.experimental) {
                    router.route(to: .experimentalSettings)
                }
            }

            ChevronButton(L10n.logs) {
                router.route(to: .log)
            }

            #if DEBUG
            ChevronButton("Debug") {
                router.route(to: .debugSettings)
            }
            #endif
        }
    }
}
