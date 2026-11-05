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
    /// v121：MoviePilot 入库（未配置则隐藏按钮）
    var mpBase: String = ""
    var mpKey: String = ""
    /// v121：飞牛库内探测闭包（主视图注入，返回 true = 已在库）
    var inLibraryCheck: ((FNOSBangumiItem) async -> Bool)? = nil

    @State private var detail: FNOSBangumiDetail?
    @State private var isLoading = true

    // MARK: v123 富数据状态
    @State private var persons: [FNOSBangumiClient.BangumiPerson] = []
    @State private var related: [FNOSBangumiClient.BangumiRelated] = []
    @State private var infoboxRows: [(String, String)] = []
    @State private var platformText: String = ""
    @State private var airWeekdayText: String = ""
    @State private var ratingCount: Int = 0
    @State private var collectionText: String = ""
    @State private var relatedDetailItem: FNOSBangumiItem?  // 相关条目进详情

    /// v121：入库按钮状态机（与 TMDB 详情页同构）
    private enum LibState {
        case idle, checking, subscribed, inLibrary, adding
    }
    @State private var libState: LibState = .idle
    @State private var mpMessage: String = ""

    private var mpConfigured: Bool {
        FNOSMoviePilotClient.configured(base: mpBase, apiKey: mpKey)
    }

    /// 番剧放送年份（airDate 形如 "2026-10" 或 "2026"）
    private var subYear: String? {
        guard let y = item.airDate, y.count >= 4 else { return nil }
        return String(y.prefix(4))
    }

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
                            // v117: 信息区可聚焦，否则下键无可落点、ScrollView 不滚动
                            .focusable()
                        // v123: 制作人员行
                        if !persons.isEmpty {
                            personsSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                        }
                        // v123: 相关条目行
                        if !related.isEmpty {
                            relatedSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                        }
                        // v123: 放送信息卡
                        if !infoboxRows.isEmpty {
                            infoboxSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 60)
                                .focusable()
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .task { await loadDetail() }
        .task { await refreshLibState() }
        // v123: 相关条目进详情
        .fullScreenCover(item: $relatedDetailItem) { relItem in
            FNOSBangumiDetailView(
                item: relItem,
                onDismiss: { relatedDetailItem = nil },
                mpBase: mpBase,
                mpKey: mpKey,
                inLibraryCheck: inLibraryCheck
            )
        }
    }

    // MARK: - v121 入库状态机（番剧）

    private func refreshLibState() async {
        guard mpConfigured else { return }
        libState = .checking
        let sub = await FNOSMoviePilotClient.lookupSubscribeByName(
            base: mpBase, apiKey: mpKey, name: item.displayTitle
        )
        var inLib = false
        if let check = inLibraryCheck {
            inLib = await check(item)
        }
        libState = inLib ? .inLibrary : (sub != nil ? .subscribed : .idle)
    }

    private func addToLibrary() async {
        guard libState == .idle else { return }
        libState = .adding
        let (ok, message) = await FNOSMoviePilotClient.addSubscribe(
            base: mpBase,
            apiKey: mpKey,
            type: "tv",
            name: item.displayTitle,
            year: subYear,
            bangumiid: item.id
        )
        if ok {
            mpMessage = ""
            libState = .subscribed
        } else {
            mpMessage = message.isEmpty ? "添加失败" : message
            libState = .idle
        }
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

                // v121：加入影视库按钮（状态机，POST 带 bangumiid，MP 经 Bangumi 源识别）
                if mpConfigured {
                    Button {
                        Task { await addToLibrary() }
                    } label: {
                        HStack(spacing: 8) {
                            switch libState {
                            case .checking:
                                ProgressView().tint(.white)
                                Text("检查中…")
                            case .inLibrary:
                                Image(systemName: "checkmark.circle.fill")
                                Text("已在库中")
                            case .subscribed:
                                Image(systemName: "arrow.down.circle.fill")
                                Text("已订阅·下载中")
                            case .adding:
                                ProgressView().tint(.white)
                                Text("提交中…")
                            case .idle:
                                Image(systemName: "plus")
                                Text("加入影视库")
                            }
                        }
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(libState == .inLibrary ? Color.green.opacity(0.35) : Color.white.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                                )
                        )
                    }
                    .buttonStyle(.card)
                    .disabled(libState != .idle)

                    if !mpMessage.isEmpty {
                        Text(mpMessage)
                            .font(.system(size: 15))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }
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
            // v123 修复：Bangumi v0 的评分在 rating.score 对象里，顶层无 score 字段
            var score = item.score
            if let rating = json["rating"] as? [String: Any], let s = rating["score"] as? Double, s > 0 {
                score = s
            } else if let topScore = json["score"] as? Double, topScore > 0 {
                score = topScore
            }
            // v123: 评分人数
            if let rating = json["rating"] as? [String: Any] {
                ratingCount = rating["total"] as? Int ?? 0
            }
            let airDate = json["date"] as? String ?? item.airDate
            let epsCount = json["eps"] as? Int ?? (json["total_episodes"] as? Int)
            let nameCN = json["name_cn"] as? String ?? item.nameCN
            let images = json["images"] as? [String: Any]
            let imgPath = (images?["large"] as? String) ?? (images?["common"] as? String)
            let backdropURL = imgPath.flatMap { URL(string: $0) }

            // v123: 平台/放送星期
            platformText = json["platform"] as? String ?? ""
            if let wd = json["air_weekday"] as? Int, wd > 0 {
                let names = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                if wd < names.count { airWeekdayText = names[wd] }
            }

            // 标签
            let tagList = (json["tags"] as? [[String: Any]])?.prefix(8).compactMap { t -> String? in
                t["name"] as? String
            } ?? []

            // v123: infobox
            infoboxRows = FNOSBangumiClient.infobox(from: json)

            // v123: 收藏统计
            if let coll = json["collection"] as? [String: Any] {
                let doing = coll["doing"] as? Int ?? 0
                let wish = coll["wish"] as? Int ?? 0
                let collect = coll["collect"] as? Int ?? 0
                var parts: [String] = []
                if collect > 0 { parts.append("看过 \(collect)") }
                if doing > 0 { parts.append("在看 \(doing)") }
                if wish > 0 { parts.append("想看 \(wish)") }
                collectionText = parts.joined(separator: " · ")
            }

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
                        let cImgURL = cImgPath.flatMap { URL(string: $0) }
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

        // v123: 制作人员 + 相关条目（独立请求，失败不影响主体）
        persons = await FNOSBangumiClient.persons(id: item.id)
        related = await FNOSBangumiClient.relatedSubjects(id: item.id)
    }

    // MARK: - v123 新区块视图

    /// 制作人员行
    private var personsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("制作人员")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(persons) { person in
                        VStack(spacing: 8) {
                            if let img = person.imageURL {
                                FNOSAsyncImage(url: img, headers: [:])
                                    .frame(width: 88, height: 88)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 88, height: 88)
                            }
                            Text(person.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                                .frame(width: 100)
                            if !person.role.isEmpty {
                                Text(person.role)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .frame(width: 100)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 相关条目行
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("相关条目")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(related) { rel in
                        Button {
                            relatedDetailItem = FNOSBangumiItem(
                                id: rel.id, name: rel.name, nameCN: "",
                                imageURL: rel.imageURL, summary: "", score: 0,
                                airDate: nil, weekday: nil
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FNOSAsyncImage(url: rel.imageURL, headers: [:], usePosterCache: true)
                                    .frame(width: 150, height: 150 * 3 / 2)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(rel.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(width: 150, alignment: .leading)
                                if !rel.relation.isEmpty {
                                    Text(rel.relation)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                        .frame(width: 150, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    /// 放送信息卡
    private var infoboxSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("放送信息")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(infoboxRows.prefix(10).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 20) {
                        Text(row.0)
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 17))
                            .foregroundColor(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
                // 评分人数 + 收藏 + 平台 + 放送日补充
                if ratingCount > 0 || !collectionText.isEmpty || !platformText.isEmpty {
                    HStack(alignment: .top, spacing: 20) {
                        Text("统计")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text([ratingCount > 0 ? "\(ratingCount) 人评分" : "",
                              collectionText, platformText, airWeekdayText]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 17))
                            .foregroundColor(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}
