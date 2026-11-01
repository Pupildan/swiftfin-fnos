//
// FNOSItemDetailView.swift
// ATV+ 风格详情页复刻：
// - 全屏背景大图（Backdrop 优先，退化 Primary）+ 底部渐变压暗
// - 左下：大标题 / 年份·评级·时长·类型 元信息行 / 简介
// - 按钮：电影/单集 = 白底黑字「播放」（ATV+ 主按钮样式）；剧集 = 「选集」玻璃胶囊
// - 右上角关闭；MENU 也可退出
//

import SwiftUI

struct FNOSItemDetailView: View {

    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String
    let onPlay: (FNOSItem) -> Void
    let onEpisodes: (FNOSItem) -> Void

    @Environment(\.dismiss)
    private var dismiss

    private struct DetailInfo: Decodable {
        let Name: String?
        let Overview: String?
        let ProductionYear: Int?
        let OfficialRating: String?
        let CommunityRating: Double?
        let RunTimeTicks: Int?
        let Genres: [String]?
        let BackdropImageTags: [String]?
    }

    @State private var info: DetailInfo?
    @State private var showSeasons = false
    @State private var loadError: String?

    private var isSeries: Bool { item.type == "Series" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 背景大图
            FNOSAsyncImage(
                url: backdropURL,
                headers: client.mediaHeaders
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .clipped()

            // 渐变压暗（保证文字可读）
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.05), location: 0.3),
                    .init(color: .black.opacity(0.75), location: 0.75),
                    .init(color: .black.opacity(0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 内容（左下）
            VStack(alignment: .leading, spacing: 18) {
                Text(info?.Name ?? item.Name ?? "未命名")
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(2)
                    .foregroundColor(.white)

                if !metaSegments.isEmpty {
                    Text(metaSegments.joined(separator: " · "))
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }

                if let overview = info?.Overview ?? item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(4)
                        .frame(maxWidth: 980, alignment: .leading)
                }

                HStack(spacing: 24) {
                    if isSeries {
                        Button {
                            showSeasons = true
                        } label: {
                            Label("选集", systemImage: "list.bullet")
                                .font(.headline)
                                .padding(.horizontal, 44)
                                .padding(.vertical, 20)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: Capsule())
                    } else {
                        Button {
                            onPlay(item)
                            dismiss()
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 20)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white, in: Capsule())
                    }
                }
                .padding(.top, 6)
            }
            .padding(70)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.top, 28)
            .padding(.trailing, 56)
        }
        .onExitCommand {
            dismiss()
        }
        .task {
            await loadDetail()
        }
        .sheet(isPresented: $showSeasons) {
            FNOSSeasonsSheet(
                series: item,
                client: client,
                userID: userID,
                onPlay: { episode in
                    dismiss()
                    onPlay(episode)
                }
            )
        }
    }

    // MARK: 数据

    private var backdropURL: URL? {
        if let tag = info?.BackdropImageTags?.first ?? item.ImageTags?["Backdrop"] {
            return client.imageURL(itemID: item.Id, imageType: "Backdrop", tag: tag, maxWidth: 1600)
        }
        return client.imageURL(itemID: item.Id, imageType: "Primary", tag: item.ImageTags?["Primary"], maxWidth: 1600)
    }

    private var metaSegments: [String] {
        var parts: [String] = []
        if let year = info?.ProductionYear ?? item.ProductionYear {
            parts.append(String(year))
        }
        if let rating = info?.OfficialRating, !rating.isEmpty {
            parts.append(rating)
        }
        if let ticks = info?.RunTimeTicks, ticks > 0 {
            let minutes = ticks / 600_000_000
            if minutes >= 60 {
                parts.append("\(minutes / 60)小时\(minutes % 60)分")
            } else {
                parts.append("\(minutes)分钟")
            }
        }
        if let genre = info?.Genres?.first {
            parts.append(genre)
        }
        return parts
    }

    private func loadDetail() async {
        do {
            let data = try await client.get(path: "Users/\(userID)/Items/\(item.Id)")
            do {
                info = try JSONDecoder().decode(DetailInfo.self, from: data)
            } catch {
                let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
                print("FNOS❗️详情解析失败: \(error) 原文: \(raw)")
            }
        } catch {
            loadError = error.localizedDescription
            print("FNOS❗️详情加载失败: \(error)")
        }
    }
}
