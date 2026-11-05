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
                // 背景：海报取色 → 渐变 → 高斯模糊
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
                    VStack(alignment: .leading, spacing: 24) {
                        // 海报 + 基本信息
                        HStack(alignment: .top, spacing: 32) {
                            if let cover = item.coverURL {
                                FNOSAsyncImage(url: cover, headers: ["Referer": "https://movie.douban.com/"], usePosterCache: true)
                                    .frame(width: 280, height: 420)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                Text(item.title)
                                    .font(.system(size: 38, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(3)

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

                                // 评分
                                if let rating = item.displayRating {
                                    HStack(spacing: 6) {
                                        Image(systemName: "star.fill").foregroundColor(.yellow)
                                        Text(String(format: "%.1f", rating))
                                            .foregroundColor(.white.opacity(0.9))
                                        Text("豆瓣评分")
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    .font(.system(size: 18))
                                }

                                // 集数信息
                                if !item.episodesInfo.isEmpty {
                                    Text(item.episodesInfo)
                                        .font(.system(size: 17))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.top, 40)

                        // v129：frodo 完整数据（简介/类型/主演/导演）
                        if let f = frodo {
                            // 类型 badges
                            if !f.genres.isEmpty {
                                HStack(spacing: 10) {
                                    ForEach(f.genres.prefix(5), id: \.self) { g in
                                        Text(g)
                                            .font(.system(size: 15))
                                            .foregroundColor(.white.opacity(0.75))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(Color.white.opacity(0.12)))
                                    }
                                }
                            }

                            // 主演
                            if !f.castNames.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("主演")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.92))
                                    Text(f.castNames.joined(separator: " / "))
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.8))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            // 导演
                            if !f.directors.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("导演")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.92))
                                    Text(f.directors.joined(separator: " / "))
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }

                            // 简介
                            if !f.summary.isEmpty {
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
                            .padding(.horizontal, 60)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
                            .padding(.horizontal, 60)
                            .focusable()
                        }
                    }
                    .padding(.bottom, 60)
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand { onDismiss() }
        .task {
            themeColor = await FNOSDominantColor.color(for: item.coverURL, headers: [:])
            // v129：frodo 完整详情（简介/类型/主演/导演）
            frodo = await FNOSDoubanClient.frodoDetail(id: item.id, category: item.category)
        }
    }
}
