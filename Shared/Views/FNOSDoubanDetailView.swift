//
// FNOSDoubanDetailView.swift
// v131: 豆瓣条目详情页（照搬热门影视/TMDB 详情页布局，数据用豆瓣 frodo 私有 API）
// Hero（海报 backdrop + 左下文字 + 右下主演导演）+ 内容行（简介/主演头像/评论）+ 入库按钮（按标题）
//

import SwiftUI

struct FNOSDoubanDetailView: View {
    let item: FNOSDoubanItem
    let onDismiss: () -> Void
    /// v131：MoviePilot 入库（未配置则隐藏按钮）
    var mpBase: String = ""
    var mpKey: String = ""
    /// v131：飞牛库内探测闭包（主视图注入，返回 true = 已在库）
    var inLibraryCheck: ((FNOSDoubanItem) async -> Bool)? = nil

    @State private var themeColor: Color?
    @State private var frodo: FNOSDoubanClient.FNOSDoubanFrodoDetail?
    @State private var celebrities: [FNOSDoubanClient.FNOSDoubanCelebrity] = []
    @State private var reviews: [FNOSDoubanClient.FNOSDoubanReview] = []
    /// v170: 评论弹窗（焦点落卡→确认键→屏幕居中弹窗完整显示）
    @State private var popupReview: FNOSDoubanClient.FNOSDoubanReview?
    /// v174: 弹窗内影评全文（列表 abstract 是摘要截断，弹窗打开后拉 /review/{rid} 全文）
    @State private var popupFullContent: String = ""
    /// v176: 全文缓存（按影评 id）——重开弹窗即时显示，不再"返回再进才出全文"
    @State private var fullContentCache: [String: String] = [:]
    /// v180: 人物弹窗（演员头像点击查看）
    @State private var popupPerson: FNOSPersonInfo?
    /// v181: 内容区焦点定位（演员/相似推荐逐项聚焦，自绘描边替代 .card 灰底）
    @FocusState private var focusedItemID: String?
    /// v167: Hero 横屏高清剧照（frodo photos）；nil 时竖版海报垫底兜底
    @State private var landscapeURL: URL?
    /// v168: 相似推荐 + 点按进详情（与 TMDB similar 同款递归）
    @State private var recItems: [FNOSDoubanClient.FNOSDoubanRec] = []
    @State private var recDetailItem: FNOSDoubanItem?
    @Environment(\.dismiss) private var dismiss

    /// 入库按钮状态机（与 TMDB/番剧详情页同构）
    private enum LibState {
        case idle, checking, subscribed, inLibrary, adding
    }
    @State private var libState: LibState = .idle
    @State private var mpMessage: String = ""

    private var mpConfigured: Bool {
        FNOSMoviePilotClient.configured(base: mpBase, apiKey: mpKey)
    }

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
                        heroSection(size: geo.size)
                        // v167: 内容区严格按 TMDB 版式拆段——主要演员 / 评论 / 制作信息，
                        // 每段独立 focusable(+focusSection)，与 FNOSTMDBDetailView 同构
                        if !celebrities.isEmpty || !(frodo?.castNames.isEmpty ?? true) {
                        celebSection
                            .padding(.horizontal, 60)
                            .padding(.bottom, 40)
                            // v181: 分区内含 Button——外层 .focusable() 会挡住焦点进入内部按钮（确认无反应）
                            #if os(tvOS)
                            .focusSection()
                            #endif
                        }
                        if !reviews.isEmpty {
                            reviewsSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                // v172: 撤掉外层 .focusable()——它把整段当成一个焦点目标，
                                // 焦点跳过所有评论卡直接进下一节。卡片自身是 Button 原生可聚焦，
                                // 外层只留 focusSection 引导引擎进入本节（海报墙同款模式）。
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v168: 相似推荐行（TMDB 相关内容同位）
                        if !recItems.isEmpty {
                            similarSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                // v181: 分区内含 Button——撤外层 .focusable() 让焦点进入内部卡片
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        if !productionRows.isEmpty {
                            productionSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 60)
                                .focusable()
                        }
                        // frodo 拿不到时的降级来源卡
                        if frodo == nil {
                            sourceFallbackSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 60)
                                .focusable()
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onExitCommand { onDismiss() }
        .task {
            themeColor = await FNOSDominantColor.color(for: item.coverURL, headers: ["Referer": "https://movie.douban.com/"])
            frodo = await FNOSDoubanClient.frodoDetail(id: item.id, category: item.category)
            celebrities = await FNOSDoubanClient.frodoCelebrities(id: item.id, category: item.category)
            reviews = await FNOSDoubanClient.frodoReviews(id: item.id, category: item.category)
        }
        // v167: 横屏剧照独立并行拉取（不阻塞详情渲染，到位后叠到竖版海报上层）
        .task { landscapeURL = await FNOSDoubanClient.frodoLandscapeURL(id: item.id, category: item.category) }
        // v168: 相似推荐独立并行拉取（frodo /recommendations）
        .task { recItems = await FNOSDoubanClient.frodoRecommendations(id: item.id, category: item.category) }
        .task { await refreshLibState() }
        // v168: 相似推荐进详情（与 TMDB similar 同款递归 fullScreenCover）
        .fullScreenCover(item: $recDetailItem) { rec in
            FNOSDoubanDetailView(
                item: rec,
                onDismiss: { recDetailItem = nil },
                mpBase: mpBase,
                mpKey: mpKey,
                inLibraryCheck: inLibraryCheck
            )
        }
        // v176: 评论弹窗（焦点落卡→确认键→居中弹窗；全文缓存，重开即时显示）
        .fullScreenCover(item: $popupReview) { review in
            FNOSReviewPopupSheet(
                author: review.author,
                ratingText: review.rating.map { String(format: "%.0f", $0) },
                content: popupFullContent.isEmpty ? review.content : popupFullContent,
                onClose: { popupReview = nil }
            )
            .task {
                // 已缓存 → 即时显示全文；否则拉 /review/{rid} 全文并缓存
                popupFullContent = fullContentCache[review.id] ?? ""
                guard popupFullContent.isEmpty else { return }
                let full = await FNOSDoubanClient.frodoReviewContent(id: item.id, reviewId: review.id)
                if !full.isEmpty {
                    popupFullContent = full
                    fullContentCache[review.id] = full
                }
            }
        }
        // v180: 人物弹窗（演员头像点击查看）
        .fullScreenCover(item: $popupPerson) { person in
            FNOSPersonPopupSheet(person: person, onClose: { popupPerson = nil })
                // v182: 拉豆瓣人物完整信息（frodo extra.info 键值对：性别/生日/出生地/英文名等）
                .task {
                    guard person.infoLines.isEmpty else { return }
                    let cid = person.id.replacingOccurrences(of: "douban-cel-", with: "")
                    let lines = await FNOSDoubanClient.frodoCelebrityDetail(id: cid)
                    if !lines.isEmpty, popupPerson?.id == person.id {
                        popupPerson = FNOSPersonInfo(id: person.id, name: person.name, role: person.role, avatarURL: person.avatarURL, infoLines: lines)
                    }
                }
        }
    }

    // MARK: - Hero（海报 backdrop + 左下文字 + 右下主演导演，同热门影视/番剧详情页）

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // v167: 底层竖版海报（aspectFill 中心裁切兜底）+ 上层横屏高清剧照。
            // 横图失败/未到位时海报透出（FNOSAsyncImage 失败态是 6% 白纱，不遮挡），
            // 彻底解决「竖屏海报放大成 16:9」的糊画问题。
            ZStack {
                if let cover = item.coverURL {
                    FNOSAsyncImage(url: cover, headers: ["Referer": "https://movie.douban.com/"], usePosterCache: true)
                        .frame(width: size.width, height: size.width * 9 / 16)
                        .clipped()
                }
                if let land = landscapeURL {
                    FNOSAsyncImage(url: land, headers: ["Referer": "https://movie.douban.com/"])
                        .frame(width: size.width, height: size.width * 9 / 16)
                        .clipped()
                }
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

            // v167: 豆瓣短评弹幕（顶部带，纯展示不参与焦点）；v168 预热 2 道，打开即在屏
            if !reviews.isEmpty {
                FNOSReviewDanmaku(texts: reviews.map { String($0.content.prefix(60)) }, prewarmLanes: 2)
            }

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

                // 评分 + 集数 + 年份
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

                // v132：简介（两行，与 TMDB 详情页 hero 对齐）
                if let f = frodo, !f.summary.isEmpty {
                    Text(f.summary)
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                // 入库按钮（按标题，状态机）
                if mpConfigured {
                    libraryButton
                    if !mpMessage.isEmpty {
                        Text(mpMessage)
                            .font(.system(size: 15))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)

            // 右下：主演 / 导演
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

    // MARK: - 入库按钮（按标题，状态机与 TMDB/番剧详情页同构）

    private var libraryButton: some View {
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
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.card)
        // v180: 移除 disabled——按钮是 Hero 唯一焦点锚点，禁用会释放焦点导致下键失效
        // （action 已有 guard libState == .idle 幂等保护，重复确认不会重复订阅）
    }

    // MARK: - 内容区（v167: 严格按 TMDB 详情页版式——主要演员 / 评论 / 制作信息 卡片）

    /// 主要演员行（与 TMDB castAvatarSection 同构：80pt 圆形头像，间距 20，frame 80）
    @ViewBuilder
    private var celebSection: some View {
        if !celebrities.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("主要演员")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(celebrities) { person in
                            // v180: 点击演员查看人物弹窗；v181 无底样式+聚焦描边（撤 .card 灰底）
                            let isF = focusedItemID == "cel-\(person.id)"
                            Button {
                                popupPerson = FNOSPersonInfo(
                                    id: "douban-cel-\(person.id)",
                                    name: person.name,
                                    role: person.character,
                                    avatarURL: person.avatarURL
                                )
                            } label: {
                                VStack(spacing: 8) {
                                    if let avatar = person.avatarURL {
                                        FNOSAsyncImage(url: avatar, headers: ["Referer": "https://movie.douban.com/"])
                                            .frame(width: 80, height: 80)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color.white.opacity(isF ? 0.9 : 0), lineWidth: 3))
                                    } else {
                                        Circle()
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 80, height: 80)
                                            .overlay(Circle().stroke(Color.white.opacity(isF ? 0.9 : 0), lineWidth: 3))
                                    }
                                    Text(person.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineLimit(1)
                                    if !person.character.isEmpty {
                                        Text(person.character)
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 80)
                                .scaleEffect(isF ? 1.08 : 1.0)
                                .animation(.easeOut(duration: 0.15), value: isF)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .focused($focusedItemID, equals: "cel-\(person.id)")
                        }
                    }
                }
            }
        } else if let f = frodo, !f.castNames.isEmpty {
            // celebrities 接口失败时用 frodoDetail.castNames 文字降级
            VStack(alignment: .leading, spacing: 16) {
                Text("主要演员")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(f.castNames.joined(separator: " / "))
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.8))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 评论（frodo 短评卡片，与 TMDB 行标题同款字体）
    @ViewBuilder
    private var reviewsSection: some View {
        if !reviews.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("评论")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    // v171: 标题后显示总评论数（frodo comment_count）
                    if let f = frodo, f.commentCount > 0 {
                        Text("\(f.commentCount) 条")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(reviews) { review in
                        // v170: 卡片可聚焦（焦点落卡→确认键→居中弹窗完整显示）
                        Button {
                            popupReview = review
                            popupFullContent = fullContentCache[review.id] ?? ""
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Text(review.author)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.9))
                                    if let rating = review.rating {
                                        HStack(spacing: 3) {
                                            Image(systemName: "star.fill").foregroundColor(.yellow)
                                            Text(String(format: "%.0f", rating))
                                                .foregroundColor(.yellow.opacity(0.9))
                                        }
                                        .font(.system(size: 13))
                                    }
                                }
                                Text(review.content)
                                    .font(.system(size: 15))
                                    .foregroundColor(.white)
                                    .lineSpacing(5)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // v175: 卡底增加透明度（液态玻璃在深色页上偏深，改轻透填充）
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    /// 相似推荐行（v168，与 TMDB similarSection 同款：160x240 海报 + 标题，点按进详情）
    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("相似推荐")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(recItems) { rec in
                        // v181: 无底样式+聚焦描边（撤 .card 灰底）
                        let isF = focusedItemID == "rec-\(rec.id)"
                        Button {
                            recDetailItem = FNOSDoubanItem(
                                id: rec.id,
                                title: rec.title,
                                rate: rec.rating.map { String(format: "%.1f", $0) } ?? "",
                                coverURL: rec.posterURL,
                                subjectURL: rec.subjectURL,
                                episodesInfo: "",
                                category: rec.mediaType == "movie" ? "电影" : "电视剧"
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FNOSAsyncImage(url: rec.posterURL, headers: ["Referer": "https://movie.douban.com/"], usePosterCache: true)
                                    .frame(width: 160, height: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(isF ? 0.9 : 0), lineWidth: 3))
                                Text(rec.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(width: 160, alignment: .leading)
                            }
                            .scaleEffect(isF ? 1.05 : 1.0)
                            .animation(.easeOut(duration: 0.15), value: isF)
                        }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .focused($focusedItemID, equals: "rec-\(rec.id)")
                    }
                }
            }
        }
    }

    /// 制作信息卡数据（与 TMDB productionSection 的 label 100pt / value 18pt 行同构）
    private var productionRows: [(String, String)] {
        guard let f = frodo else { return [] }
        var rows: [(String, String)] = []
        if !f.year.isEmpty { rows.append(("年份", f.year)) }
        if !f.genres.isEmpty { rows.append(("类型", f.genres.joined(separator: " / "))) }
        if !f.directors.isEmpty { rows.append(("导演", f.directors.joined(separator: " / "))) }
        if !f.castNames.isEmpty { rows.append(("主演", f.castNames.joined(separator: " / "))) }
        if !f.countries.isEmpty { rows.append(("地区", f.countries.joined(separator: " / "))) }
        if !f.languages.isEmpty { rows.append(("语言", f.languages.joined(separator: " / "))) }
        if !f.durations.isEmpty { rows.append(("片长", f.durations.joined(separator: " / "))) }
        if !f.pubdate.isEmpty { rows.append(("上映", f.pubdate.prefix(2).joined(separator: " / "))) }
        if f.ratingValue > 0 {
            var v = String(format: "%.1f", f.ratingValue)
            if f.ratingCount > 0 { v += "（\(f.ratingCount) 人评价）" }
            rows.append(("豆瓣评分", v))
        }
        if f.commentCount > 0 { rows.append(("短评", "\(f.commentCount) 条")) }
        if !f.originalTitle.isEmpty { rows.append(("原名", f.originalTitle)) }
        rows.append(("数据来源", "豆瓣电影"))
        return rows
    }

    /// 制作信息卡（与 TMDB productionSection 完全同款样式）
    private var productionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("制作信息")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(productionRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 20) {
                        Text(row.0)
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 18))
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

    /// frodo 拿不到时的来源说明降级卡
    private var sourceFallbackSection: some View {
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

    // MARK: - 入库状态机（按标题，与 TMDB/番剧详情页同构）

    private func refreshLibState() async {
        guard mpConfigured else { return }
        libState = .checking
        let sub = await FNOSMoviePilotClient.lookupSubscribeByName(
            base: mpBase, apiKey: mpKey, name: item.title
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
            name: item.title,
            year: nil
        )
        if ok {
            mpMessage = ""
            libState = .subscribed
        } else {
            mpMessage = message.isEmpty ? "添加失败" : message
            libState = .idle
        }
    }
}
