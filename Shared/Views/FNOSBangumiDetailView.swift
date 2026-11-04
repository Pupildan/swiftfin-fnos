//
// FNOSBangumiDetailView.swift
// v115: Bangumi 番剧详情页 — 数据全从 Bangumi API 抓取，风格与媒体库详情页一致
//

import SwiftUI

struct FNOSBangumiDetail: Identifiable {
    let id: Int
    let title: String
    let nameCN: String
    let summary: String
    let backdropURL: URL?
    let posterURL: URL?
    let score: Double
    let airDate: String?
    let epsCount: Int?
    var tags: [String] = []
    var characters: [BangumiChar] = []

    struct BangumiChar: Identifiable {
        let id: Int
        let name: String
        let role: String
        let imageURL: URL?
    }
}

struct FNOSBangumiDetailView: View {
    let item: FNOSBangumiItem
    let onDismiss: () -> Void

    @State private var detail: FNOSBangumiDetail?
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景
                ZStack {
                    Color.black
                    if let backdrop = detail?.backdropURL ?? item.imageURL {
                        FNOSAsyncImage(url: backdrop, headers: [:])
                            .ignoresSafeArea()
                            .overlay(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.3),
                                        .init(color: .black.opacity(0.7), location: 0.7),
                                        .init(color: .black, location: 1.0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(size: geo.size)
                        infoSection
                            .padding(.horizontal, 60)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .task { await loadDetail() }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let backdrop = detail?.backdropURL ?? item.imageURL {
                FNOSAsyncImage(url: backdrop, headers: [:])
                    .frame(width: size.width, height: size.width * 9 / 16)
                    .clipped()
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.9), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(detail?.nameCN.isEmpty == false ? detail!.nameCN : item.displayTitle)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 12) {
                    if let score = detail?.score, score > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", score))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .font(.system(size: 17))
                    }
                    if let airDate = detail?.airDate ?? item.airDate, airDate.count >= 4 {
                        Text(String(airDate.prefix(4)))
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    if let eps = detail?.epsCount, eps > 0 {
                        Text("\(eps) 话")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    if let wd = item.weekday {
                        Text(wd)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                // 加入影视库按钮
                Button {
                    // Phase 3：PT 搜种 + QBT 推送（暂未实现）
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                        Text("加入影视库")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                            )
                    )
                }
                .buttonStyle(.card)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
        .frame(width: size.width, height: size.width * 9 / 16)
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let summary = detail?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }

            if let tags = detail?.tags, !tags.isEmpty {
                HStack(spacing: 10) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                }
            }

            if let chars = detail?.characters, !chars.isEmpty {
                Text("主要角色")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(chars) { char in
                            VStack(spacing: 8) {
                                if let img = char.imageURL {
                                    FNOSAsyncImage(url: img, headers: [:])
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 80, height: 80)
                                }
                                Text(char.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                Text(char.role)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Load

    private func loadDetail() async {
        do {
            let json = try await FNOSBangumiClient.subject(id: item.id)

            let summary = json["summary"] as? String ?? item.summary
            let score = json["score"] as? Double ?? item.score
            let airDate = json["date"] as? String ?? item.airDate
            let epsCount = json["eps"] as? Int
            let nameCN = json["name_cn"] as? String ?? item.nameCN
            let images = json["images"] as? [String: Any]
            let imgPath = (images?["large"] as? String) ?? (images?["common"] as? String)
            let backdropURL = imgPath.map { URL(string: $0)! }

            // 标签
            let tagList = (json["tags"] as? [[String: Any]])?.prefix(8).compactMap { t -> String? in
                t["name"] as? String
            } ?? []

            // 角色（Bangumi v0 需单独请求 characters 端点）
            var chars: [FNOSBangumiDetail.BangumiChar] = []
            do {
                let charURL = URL(string: "https://api.bgm.tv/v0/subjects/\(item.id)/characters")!
                var charReq = URLRequest(url: charURL)
                charReq.timeoutInterval = 10
                charReq.setValue("application/json", forHTTPHeaderField: "Accept")
                let (charData, _) = try await URLSession.shared.data(for: charReq)
                if let charJSON = try? JSONSerialization.jsonObject(with: charData) as? [[String: Any]] {
                    chars = charJSON.prefix(10).compactMap { c -> FNOSBangumiDetail.BangumiChar? in
                        guard let cid = c["id"] as? Int else { return nil }
                        let name = c["name"] as? String ?? ""
                        let role = (c["role_name"] as? String) ?? (c["relation"] as? String) ?? ""
                        let cImages = c["images"] as? [String: Any]
                        let cImgPath = (cImages?["medium"] as? String) ?? (cImages?["large"] as? String)
                        let cImgURL = cImgPath.map { URL(string: $0)! }
                        return FNOSBangumiDetail.BangumiChar(id: cid, name: name, role: role, imageURL: cImgURL)
                    }
                }
            }

            detail = FNOSBangumiDetail(
                id: item.id,
                title: item.name,
                nameCN: nameCN,
                summary: summary,
                backdropURL: backdropURL,
                posterURL: item.imageURL,
                score: score,
                airDate: airDate,
                epsCount: epsCount,
                tags: tagList,
                characters: chars
            )
            isLoading = false
        } catch {
            print("FNOS⚠️Bangumi 详情加载失败: \(error.localizedDescription)")
            isLoading = false
        }
    }
}
