//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// 影视详情页 —— 1:1 复刻 Apple TV+ 详情页版式。
///
/// 版式要点（对照 ATV+ 截图）：
/// - 全屏 Backdrop 打底 + 左黑下黑双渐变，左上角留出片名区
/// - 左下：奖项胶囊 → 大标题 → 类型/分级行 → 简介 → 元信息行 → 白色主按钮 + 圆形辅按钮
/// - 右侧：主演 / 导演 署名（右对齐，淡色）
/// - 向下滚动：关于卡片、信息卡片（发行/时长/分级/地区）
struct FNOSItemDetailView: View {

    let item: FNOSItem
    let client: FNOSDirectClient?
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var backdropURL: URL? {
        guard let client else { return nil }
        let tag = item.BackdropImageTags?.first ?? item.ImageTags?["Primary"]
        let path = item.BackdropImageTags?.isEmpty == false
            ? "Items/\(item.Id)/Images/Backdrop"
            : "Items/\(item.Id)/Images/Primary"
        guard let tag, !tag.isEmpty else { return nil }
        do {
            return try client.url(
                path: path,
                query: ["maxWidth": "1920", "quality": "90", "tag": tag]
            )
        } catch {
            return nil
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = item.ProductionYear { parts.append(String(year)) }
        if let duration = item.durationString { parts.append(duration) }
        return parts.joined(separator: " · ")
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
                Color.black.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(size: geo.size)

                        infoSection
                            .padding(.horizontal, 60)
                            .padding(.top, 10)
                            .padding(.bottom, 80)
                    }
                }
                .ignoresSafeArea()

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
    }

    // MARK: - 顶部全屏 Hero

    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 背景大图
            FNOSAsyncImage(
                url: backdropURL,
                headers: client?.mediaHeaders ?? [:],
                contentMode: .fill
            )
            .frame(width: size.width, height: size.height)
            .clipped()

            // 左黑 → 右透
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.42),
                    .init(color: .clear, location: 0.92),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // 下黑
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.85), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 左下内容区
            VStack(alignment: .leading, spacing: 18) {
                // 奖项胶囊（示例位；飞牛无该字段时显示适配版标识）
                Text(FNOSAdapterBuild.version == "" ? "" : "飞牛影视 · 精选")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(Color.white.opacity(0.16))
                    )

                // 片名
                Text(item.Name ?? "未命名")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // 类型 · 分级
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

                // 简介
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                // 元信息行
                HStack(spacing: 12) {
                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    Text("4K")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6)))
                }

                // 按钮行
                HStack(spacing: 16) {
                    // 白色主按钮
                    Button {
                        onPlay()
                    } label: {
                        Text(item.type == "Series" ? "选集" : "播放")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.card)

                    // 稍后观看（圆形 +）
                    Button {
                        toggleWatchLater()
                    } label: {
                        Image(systemName: isWatchLater ? "checkmark" : "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                    }
                    .buttonStyle(.card)

                    // 信息（圆形 i）
                    Button {
                        // 详情页已展示全部信息，此处仅占位保持 ATV+ 版式
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(Color.white.opacity(0.22)))
                    }
                    .buttonStyle(.card)
                }
                .padding(.top, 6)
            }
            .padding(.leading, 60)
            .padding(.bottom, 90)
            .padding(.top, size.height * 0.42)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 下方信息区块

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 34) {
            // 关于
            if let overview = item.Overview, !overview.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("关于")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)

                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                        )
                }
            }

            // 信息
            VStack(alignment: .leading, spacing: 16) {
                Text("信息")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                HStack(alignment: .top, spacing: 24) {
                    infoCard(
                        rows: [
                            ("发行时间", item.ProductionYear.map(String.init) ?? "—"),
                            ("片长", item.durationString ?? "—"),
                            ("分级", item.OfficialRating ?? "—"),
                            ("类型", (item.Genres ?? []).joined(separator: "、").isEmpty
                                ? Self.categoryName(item)
                                : (item.Genres ?? []).joined(separator: "、")),
                        ]
                    )
                }
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

    // MARK: - 稍后观看

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
