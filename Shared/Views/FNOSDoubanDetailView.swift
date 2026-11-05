//
// FNOSDoubanDetailView.swift
// v126: 豆瓣条目详情页（轻量——豆瓣 subject 页反爬 302 抓不了，
//       用列表数据展示：大海报 + 评分 + 类型 + 集数；背景取色高斯模糊）
//

import SwiftUI

struct FNOSDoubanDetailView: View {
    let item: FNOSDoubanItem
    let onDismiss: () -> Void

    @State private var themeColor: Color?
    /// v129：frodo 完整详情（简介/类型/年份/主演/导演）
    @State private var frodo: FNOSDoubanClient.FNOSDoubanFrodoDetail?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景：海报取色 → 渐变 → 高斯模糊（同热门影视/番剧详情页）
                ZStack {
                    Color.black
                    if let theme = themeColor {
                        LinearGradient(
                            stops: [
                                .init(color: theme.opacity(0.5), location: 0),
                                .init(color: theme.opacity(0.28), location: 0.5),
                                .init(color: theme.opacity(0.12), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .blur(radius: 60)
                    }
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.3), location: 0),
                            .init(color: .black.opacity(0.55), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: themeColor)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Hero 区（海报 backdrop + 左下文字 + 右下主演导演，同热门影视/番剧）
                        heroSection(size: geo.size)
                        // 内容行（简介/类型/主演/导演，frodo 数据）
                        contentSection
                            .padding(.horizontal, 60)
                            .padding(.top, 20)
                            .padding(.bottom, 60)
                            .focusable()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand { onDismiss() }
        .task {
            themeColor = await FNOSDominantColor.color(for: item.coverURL, headers: ["Referer": "https://movie.douban.com/"])
            // v129：frodo 完整详情（简介/类型/主演/导演）
            frodo = await FNOSDoubanClient.frodoDetail(id: item.id, category: item.category)
        }
    }

    // MARK: - Hero（海报 backdrop + 左下文字 + 右下主演导演，同热门影视/番剧详情页）

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 海报作 backdrop（全宽铺满）
            if let cover = item.coverURL {
                FNOSAsyncImage(url: cover, headers: ["Referer": "https://movie.douban.com/"], usePosterCache: true)
                    .frame(width: size.width, height: size.width * 9 / 16)
                    .clipped()
            }

            // 渐变压暗：左黑右透 + 下黑上透
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .black.opacity(0.3), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.85), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 左下信息区
            VStack(alignment: .leading, spacing: 14) {
                // 类型徽章
                Text(item.category)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.white.opacity(0.18))
                            .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                    )

                Text(item.title)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(2)
                    .foregroundColor(.white)

                // 评分 + 集数
                HStack(spacing: 12) {
                    if let rating = item.displayRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                        }
                    }
                    if !item.episodesInfo.isEmpty {
                        Text(item.episodesInfo)
                    }
                    if let f = frodo, !f.year.isEmpty {
                        Text(f.year + " 年")
                    }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.85))

                // 类型 badges（frodo）
                if let f = frodo, !f.genres.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(f.genres.prefix(5), id: \.self) { g in
                            Text(g)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)

            // 右下：主演 / 导演（同热门影视/番剧）
            if let f = frodo, !f.castNames.isEmpty || !f.directors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !f.castNames.isEmpty {
                        Text("主演 \(f.castNames.joined(separator: ", "))")
                    }
                    if !f.directors.isEmpty {
                        Text("导演 \(f.directors.joined(separator: " / "))")
                    }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 60)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.width * 9 / 16)
    }

    // MARK: - 内容行（简介，frodo 数据）

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let f = frodo, !f.summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("简介")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text(f.summary)
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.8))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 来源说明（frodo 拿不到时降级显示）
            if frodo == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("数据来源")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text("本条目信息来自豆瓣（movie.douban.com）。豆瓣未提供公开 API，故此处展示列表可获取的标题、评分、类型与集数信息。")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
            }
        }
    }
}
