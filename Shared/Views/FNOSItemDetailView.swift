//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// 影视详情页 —— 1:1 复刻 Apple TV+ 详情页版式。
struct FNOSItemDetailView: View {

    let item: FNOSItem
    let client: FNOSDirectClient?
    let userID: String
    /// 剧集：交给外层弹选集面板
    let onEpisodes: (FNOSItem) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 播放器在本页内打开（不先关详情页），避免 fullScreenCover 竞态导致请求被取消
    @State private var playbackTarget: FNOSPlaybackTarget?

    /// 详情页背景图轮播索引
    @State private var backdropIndex = 0

    // 详情数据（媒体源、时长、演员）
    @State private var mediaSourceID: String?
    @State private var runtimeTicks: Int64?
    @State private var people: [FNOSDirectClient.FNOSPerson] = []
    @State private var loadError: String?
    // 从海报提取的主色（动态液态玻璃背景）
    @State private var themeColor: Color?

    // 三个按钮的焦点
    private enum DetailButton { case play, plus, info }
    @FocusState private var focusedButton: DetailButton?

    /// 全部可用背景图（多张 Backdrop 用于轮播；没有横图时退化为竖版海报）
    private var backdropURLs: [URL] {
        guard let client else { return [] }
        var urls: [URL] = []

        if let tags = item.BackdropImageTags, !tags.isEmpty {
            for (index, tag) in tags.enumerated() where !tag.isEmpty {
                if let url = try? client.url(
                    path: "Items/\(item.Id)/Images/Backdrop/\(index)",
                    query: ["maxWidth": "1920", "quality": "90", "tag": tag]
                ) {
                    urls.append(url)
                }
            }
        }

        if urls.isEmpty, let primary = item.ImageTags?["Primary"], !primary.isEmpty {
            if let url = try? client.url(
                path: "Items/\(item.Id)/Images/Primary",
                query: ["maxWidth": "1920", "quality": "90", "tag": primary]
            ) {
                urls.append(url)
            }
        }

        return urls
    }

    /// 当前展示的背景图
    private var backdropURL: URL? {
        guard !backdropURLs.isEmpty else { return nil }
        return backdropURLs[min(backdropIndex, backdropURLs.count - 1)]
    }

    /// 每 2 秒切换到下一张剧照（只有 1 张时不动）
    @MainActor
    private func rotateBackdrops() async {
        let count = backdropURLs.count
        guard count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.7)) {
                backdropIndex = (backdropIndex + 1) % count
            }
        }
    }

    /// 时长文案：优先 PlaybackInfo 的 RunTimeTicks（Jellyfin 单位 100ns）
    private var durationString: String? {
        guard let ticks = runtimeTicks ?? item.RunTimeTicks, ticks > 0 else { return nil }
        let seconds = ticks / 10_000_000
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    private var genreLine: String {
        var parts: [String] = [Self.categoryName(item)]
        if let genres = item.Genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " · "))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 动态液态玻璃背景：从海报自动取色，向下逐渐过渡到纯黑
                ZStack {
                    Color.black
                    if let themeColor {
                        RadialGradient(
                            colors: [themeColor.opacity(0.55), themeColor.opacity(0.18), .clear],
                            center: .top,
                            startRadius: 0,
                            endRadius: geo.size.height * 1.1
                        )
                    }
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: themeColor)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            heroSection(size: geo.size, proxy: proxy)

                            infoSection
                                .padding(.horizontal, 60)
                                .padding(.top, 10)
                                .padding(.bottom, 90)
                                .id("detail-info")
                        }
                    }
                    .ignoresSafeArea()
                }

                // 右上角关闭
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 44)
                        .padding(.top, 40)
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .task {
            await loadDetail()
        }
        .task(id: item.Id) {
            await rotateBackdrops()
        }
        .fullScreenCover(item: $playbackTarget) { target in
            FNOSPlayerContainerView(
                item: target.item,
                client: target.client,
                userID: target.userID
            )
        }
    }

    // MARK: - 顶部全屏 Hero

    private func heroSection(size: CGSize, proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomLeading) {
            FNOSAsyncImage(
                url: backdropURL,
                headers: client?.mediaHeaders ?? [:],
                contentMode: .fill
            )
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.7), value: backdropIndex)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.42),
                    .init(color: .clear, location: 0.92),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.85), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 20) {
                Text("飞牛影视 · 精选")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.16)))

                Text(item.Name ?? "未命名")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Image(systemName: "appletv.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                    Text(genreLine)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    if let rating = item.OfficialRating, !rating.isEmpty {
                        Text(rating)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow))
                    }
                }

                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                HStack(spacing: 12) {
                    if let duration = durationString {
                        Text(duration)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    if let year = item.ProductionYear {
                        Text(String(year))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Text("4K")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white.opacity(0.6))
                        )
                }

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 15))
                        .foregroundColor(.red.opacity(0.9))
                }

                HStack(spacing: 28) {
                    // 立即播放（白色主按钮）
                    detailButton(.play, isPrimary: true) {
                        playNow()
                    } label: {
                        Text(item.type == "Series" ? "选集" : "立即播放")
                            .font(.system(size: 21, weight: .semibold))
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }

                    // 稍后观看
                    detailButton(.plus, isPrimary: false) {
                        toggleWatchLater()
                    } label: {
                        Image(systemName: isWatchLater ? "checkmark" : "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 54, height: 54)
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }

                    // 信息
                    detailButton(.info, isPrimary: false) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("detail-info", anchor: .top)
                        }
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 54, height: 54)
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("detail-info", anchor: .top)
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .defaultFocus($focusedButton, .play)
            }
            .padding(.leading, 60)
            .padding(.bottom, 130)
            .padding(.top, size.height * 0.40)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 详情页按钮（未选中：半透明液态玻璃；选中：纯白背景 + 黑字）

    @ViewBuilder
    private func detailButton<Label: View>(
        _ id: DetailButton,
        isPrimary: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isFocused = focusedButton == id
        Button(action: action) {
            FNOSFocusButtonLabel(isFocused: isFocused, isPrimary: isPrimary) {
                label()
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focusedButton, equals: id)
        .focusEffectDisabled()
    }

    // MARK: - 下方信息区块

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 40) {
            // 演员阵容
            if !people.isEmpty {
                castSection
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("信息")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                infoCard(
                    rows: [
                        ("发行时间", item.ProductionYear.map(String.init) ?? "—"),
                        ("片长", durationString ?? "—"),
                        ("分级", item.OfficialRating ?? "—"),
                        ("类型", (item.Genres ?? []).isEmpty
                            ? Self.categoryName(item)
                            : (item.Genres ?? []).joined(separator: "、")),
                    ]
                )
            }
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("演员阵容")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 8) {
                            FNOSAsyncImage(
                                url: person.id.flatMap { id in
                                    client?.personImageURL(personID: id, tag: person.imageTag)
                                },
                                headers: client?.mediaHeaders ?? [:],
                                contentMode: .fill
                            )
                            .frame(width: 124, height: 124)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

                            Text(person.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(person.role ?? " ")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(width: 150)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func infoCard(rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.0)
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.5))
                    Text(row.1)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
        }
        .padding(28)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
    }

    // MARK: - 数据与动作

    @MainActor
    private func loadDetail() async {
        guard let client else { return }
        do {
            let detail = try await client.fetchItemDetail(itemID: item.Id, userID: userID)
            mediaSourceID = detail.mediaSourceID
            runtimeTicks = detail.runTimeTicks
            people = detail.people
            if mediaSourceID == nil {
                loadError = "未获取到媒体源"
            }
            print("FNOSℹ️详情 \(item.Name ?? "?") 时长ticks=\(runtimeTicks ?? -1) 源=\(mediaSourceID ?? "nil") 演员=\(people.count)")

            // 从海报提取主题色（失败就保持黑底，不影响功能）
            if let url = backdropURL {
                themeColor = await FNOSDominantColor.color(for: url, headers: client.mediaHeaders)
            }
        } catch {
            loadError = "获取播放信息失败：\(error.localizedDescription)"
            print("FNOS❗️详情加载失败: \(error)")
        }
    }

    private func playNow() {
        if item.type == "Series" {
            onEpisodes(item)
            return
        }
        guard let client else {
            loadError = "客户端未初始化"
            return
        }
        loadError = nil
        // 在本页内打开播放器（详情页不关闭），彻底避免 cover 竞态导致请求被取消
        playbackTarget = FNOSPlaybackTarget(item: item, client: client, userID: userID)
    }

    @AppStorage("fnos.watchlater") private var watchLaterIDs = ""

    private var isWatchLater: Bool {
        watchLaterIDs.split(separator: ",").map(String.init).contains(item.Id)
    }

    private func toggleWatchLater() {
        var ids = watchLaterIDs.split(separator: ",").map(String.init)
        if let index = ids.firstIndex(of: item.Id) {
            ids.remove(at: index)
        } else {
            ids.append(item.Id)
        }
        watchLaterIDs = ids.joined(separator: ",")
    }

    private static func categoryName(_ item: FNOSItem) -> String {
        switch item.type {
        case "Movie": return "电影"
        case "Series": return "剧集"
        case "Episode": return "单集"
        default: return item.type ?? "影片"
        }
    }
}
