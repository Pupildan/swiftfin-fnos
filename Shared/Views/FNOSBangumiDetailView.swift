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
    /// v125：Hero 海报取色（详情页背景高斯模糊用）
    @State private var themeColor: Color?
    /// v167: 短评列表（bangumi.tv 评论页 HTML 解析，Hero 弹幕用）
    @State private var reviewTexts: [String] = []
    /// v173: 短评富数据（作者+正文，评论区卡片 + 弹窗用）
    @State private var bgmComments: [FNOSBangumiClient.BangumiComment] = []
    /// v173: 当前弹窗展示的短评
    @State private var popupComment: FNOSBangumiClient.BangumiComment?

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
                // 背景：Hero 海报取色 → 渐变 → 高斯模糊（v125），压暗保证白字可读
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
                                // v176: 撤 .focusable()——内部按钮焦点进不去（同豆瓣 v172 根因）
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v173: 短评区（1:1 复刻豆瓣评论，置于相关条目之下）
                        if !bgmComments.isEmpty {
                            bgmCommentsSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                #if os(tvOS)
                                .focusSection()
                                #endif
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
        // v173: 短评富数据并行拉取（Hero 弹幕 + 评论区共用同一批）
        .task {
            let rich = await FNOSBangumiClient.comments(id: item.id)
            bgmComments = rich
            reviewTexts = rich.map { String($0.content.prefix(60)) }
        }
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
        // v173: 短评弹窗（焦点落卡→确认键→屏幕居中弹窗完整显示，与豆瓣 1:1 同款）
        .fullScreenCover(item: $popupComment) { comment in
            FNOSReviewPopupSheet(
                author: comment.author,
                ratingText: nil,
                content: comment.content,
                onClose: { popupComment = nil }
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

    // MARK: - Hero（严格按参考图排版：左下徽章→标题→类型·平台+评分→简介→日期·集数→按钮；右下主要角色）

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let backdrop = detail?.backdropURL ?? item.imageURL {
                FNOSAsyncImage(url: backdrop, headers: [:])
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

            // v167: 番剧短评弹幕（顶部带，纯展示不参与焦点）
            if !reviewTexts.isEmpty {
                FNOSReviewDanmaku(texts: reviewTexts)
            }

            // 左下信息区
            VStack(alignment: .leading, spacing: 14) {
                // 徽章胶囊（放送平台 / 番剧）
                Text(platformText.isEmpty ? "番剧" : platformText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.white.opacity(0.18))
                            .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                    )

                Text(detail?.nameCN.isEmpty == false ? detail!.nameCN : item.displayTitle)
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(2)
                    .foregroundColor(.white)

                // 类型 · 平台 + 评分
                HStack(spacing: 12) {
                    Text("番剧")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.55), lineWidth: 1))
                    if let score = detail?.score, score > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").foregroundColor(.yellow)
                            Text(String(format: "%.1f", score))
                        }
                    }
                    if !airWeekdayText.isEmpty {
                        Text(airWeekdayText)
                    }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.85))

                // 简介（两行）
                if let summary = detail?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                // 格式徽章行：日期 · 集数
                HStack(spacing: 12) {
                    if let airDate = detail?.airDate ?? item.airDate, airDate.count >= 4 {
                        Text(String(airDate.prefix(4)) + " 年")
                    }
                    if let eps = detail?.epsCount, eps > 0 {
                        Text("\(eps) 话")
                    }
                    if ratingCount > 0 { Text("\(ratingCount) 人评分") }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.7))

                // v121：加入影视库按钮（状态机，POST 带 bangumiid，MP 经 Bangumi 源识别——逻辑未改）
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
                        // v127：苹果液态玻璃半透明（替换原先 inLibrary 的绿底）
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            // 右下：主要角色（参考图的 主演 位置）
            if !heroCharNames.isEmpty {
                Text("主要角色 \(heroCharNames)")
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

    /// 主要角色前 3 名（右下展示用）
    private var heroCharNames: String {
        (detail?.characters.prefix(3).compactMap { $0.name }.joined(separator: ", ")) ?? ""
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // v125：简介已移入 Hero，此处不再重复

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

            // v125：Hero 海报取色（详情页背景高斯模糊）
            themeColor = await FNOSDominantColor.color(for: backdropURL, headers: [:])
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

    /// v173: 短评区（1:1 复刻豆瓣评论：标题+总条数 / 卡片折叠 3 行+液态玻璃 / 确认键弹窗）
    private var bgmCommentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("评论")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                Text("\(bgmComments.count) 条")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 20) {
                ForEach(bgmComments) { comment in
                    Button {
                        popupComment = comment
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(comment.author)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                            Text(comment.content)
                                .font(.system(size: 15))
                                .foregroundColor(.white)
                                .lineSpacing(5)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // v175: 卡底增加透明度（深色页上液态玻璃偏深，改轻透填充）
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.card)
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
