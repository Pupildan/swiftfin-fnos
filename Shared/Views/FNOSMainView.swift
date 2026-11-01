//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import SwiftUI
import UIKit

/// 飞牛影视（fnOS）主界面 —— 独立直连版。
///
/// 本界面**完全绕开** Jellyfin SDK / BaseItemDto / URLProtocol / delegate 适配层：
/// 用最原始的 URLSession 直连 fnOS 8005 兼容层（必须带 X-Emby-Authorization 头）。
/// 数据加载成功与否、错误原因，全部实时显示在底部日志区 + print 到控制台。
struct FNOSMainView: View {

    @InjectedObject(\.userSessionManager)
    private var userSessionManager: UserSessionManager

    @State private var client: FNOSDirectClient?
    @State private var userID = ""
    @State private var serverDescription = ""

    @State private var libraries: [FNOSLibrary] = []
    @State private var selectedLibraryID: String?
    @State private var items: [FNOSItem] = []

    @State private var logs: [String] = []
    @State private var isLoading = false
    @State private var selectedItem: FNOSItem?
    @State private var didBootstrap = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 20)]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            libraryRow
            contentArea
            logArea
        }
        .padding(24)
        .background(Color.black.ignoresSafeArea())
        .task {
            await bootstrapIfNeeded()
        }
        .sheet(item: $selectedItem) { item in
            FNOSItemDetailSheet(item: item)
        }
    }

    // MARK: - 顶部（版本号：一眼核对是否装上本版）

    private var header: some View {
        HStack(spacing: 16) {
            Text("FNOS v\(FNOSAdapterBuild.version)")
                .font(.title2)
                .bold()
            Text(serverDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                didBootstrap = false
                Task { await bootstrapIfNeeded() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - 媒体库选择行

    private var libraryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(libraries) { library in
                    Button {
                        selectedLibraryID = library.Id
                        Task { await loadItems(for: library) }
                    } label: {
                        Text(library.Name ?? "未命名")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .background(
                        selectedLibraryID == library.Id
                            ? Color.accentColor
                            : Color.white.opacity(0.12)
                    )
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - 内容网格

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            VStack(spacing: 12) {
                Text("暂无内容")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("媒体库已列出但这里为空时，请把下方日志拍照反馈")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            FNOSItemCell(item: item, client: client)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 底部实时日志（print 的内容同步显示，无需连电脑）

    private var logArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(logs.suffix(5).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 数据加载（全 do-catch，绝不静默）

    @MainActor
    private func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await bootstrap()
    }

    @MainActor
    private func bootstrap() async {
        log("启动 FNOS 直连 v\(FNOSAdapterBuild.version)")

        guard let session = userSessionManager.currentSession else {
            log("❗️未登录：无当前会话")
            print("FNOS❗️bootstrap: userSessionManager.currentSession 为 nil")
            return
        }

        let baseURL = session.server.effectiveServerURL
        let token = session.user.accessToken
        userID = session.user.id
        serverDescription = baseURL.absoluteString

        log("服务器 \(serverDescription) · 令牌 \(token.count) 字符")

        let newClient = FNOSDirectClient(baseURL: baseURL, token: token)
        client = newClient

        do {
            let data = try await newClient.get(path: "Users/\(userID)/Views")

            let envelope: FNOSViewsEnvelope
            do {
                envelope = try JSONDecoder().decode(FNOSViewsEnvelope.self, from: data)
            } catch {
                let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
                print("FNOS❗️解析 /Views 失败: \(error) 原文: \(raw)")
                throw FNOSDirectError("解析 /Views 失败: \(error.localizedDescription) 原文: \(raw)")
            }

            libraries = envelope.Items
            log("✅ 媒体库 \(libraries.count) 个")

            if let first = libraries.first {
                selectedLibraryID = first.Id
                await loadItems(for: first)
            }
        } catch {
            print("FNOS❗️加载媒体库失败: \(error)")
            log("❗️媒体库加载失败: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadItems(for library: FNOSLibrary) async {
        guard let client else {
            log("❗️客户端未初始化")
            print("FNOS❗️loadItems: client 为 nil")
            return
        }

        isLoading = true
        items = []

        do {
            let data = try await client.get(
                path: "Users/\(userID)/Items",
                query: [
                    "ParentId": library.Id,
                    "Recursive": "true",
                    "Limit": "200",
                    "SortBy": "SortName",
                    "SortOrder": "Ascending",
                    "Fields": "PrimaryImageAspectRatio,ProductionYear,Overview",
                ]
            )

            let envelope: FNOSItemsEnvelope
            do {
                envelope = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data)
            } catch {
                let raw = String(data: data.prefix(400), encoding: .utf8) ?? "(非文本)"
                print("FNOS❗️解析 /Items 失败: \(error) 原文: \(raw)")
                throw FNOSDirectError("解析 /Items 失败: \(error.localizedDescription) 原文: \(raw)")
            }

            items = envelope.Items
            log("✅ 「\(library.Name ?? "?")」\(items.count) 条")
        } catch {
            print("FNOS❗️加载内容失败: \(error)")
            log("❗️内容加载失败: \(error.localizedDescription)")
        }

        isLoading = false
    }

    @MainActor
    private func log(_ line: String) {
        print("FNOSℹ️ \(line)")
        logs.append(line)
        if logs.count > 40 {
            logs.removeFirst(logs.count - 40)
        }
    }
}

// MARK: - 内容单元格（文字永远显示，图片失败只影响海报区）

private struct FNOSItemCell: View {

    let item: FNOSItem
    let client: FNOSDirectClient?

    @StateObject private var loader = FNOSImageLoader()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))

                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.title)
                        Text(item.type ?? "无类型")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.Name ?? "未命名")
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)

            if let year = item.ProductionYear {
                Text(String(year))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await loadPoster()
        }
    }

    private func loadPoster() async {
        guard let client else {
            print("FNOS❗️海报: client 为 nil (\(item.Name ?? item.Id))")
            return
        }
        guard loader.image == nil else { return }
        guard item.ImageTags?["Primary"] != nil else {
            // 无海报数据：占位符（图标+类型文字）保持显示，不算错误
            return
        }
        guard let url = client.imageURL(itemID: item.Id) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (key, value) in client.requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw FNOSDirectError("海报非 HTTP 响应: \(String(describing: response)) \(item.Id)")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FNOSDirectError("海报 HTTP \(http.statusCode): \(item.Id)")
            }
            guard let image = UIImage(data: data) else {
                throw FNOSDirectError("海报解码失败: \(item.Id)")
            }

            loader.image = image
        } catch {
            // 图片失败绝不影响文字显示：占位符保持可见，只打印报错
            print("FNOS❗️海报加载失败 \(item.Name ?? item.Id): \(error.localizedDescription)")
        }
    }
}

@MainActor
final class FNOSImageLoader: ObservableObject {
    @Published var image: UIImage?
}

// MARK: - 详情弹层（纯文字信息）

private struct FNOSItemDetailSheet: View {

    let item: FNOSItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.Name ?? "未命名")
                    .font(.title2)
                    .bold()

                HStack(spacing: 12) {
                    Text(item.type ?? "-")
                    if let year = item.ProductionYear {
                        Text(String(year))
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.body)
                } else {
                    Text("无简介")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }
}
