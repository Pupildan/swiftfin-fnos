//
// FNOSTMDBDetailView.swift
// v113: TMDB 条目详情页 — 数据全从 TMDB 抓取，风格与媒体库详情页一致
//

import SwiftUI

struct FNOSTMDBDetail: Identifiable {
    let id: Int
    let title: String
    let overview: String
    let backdropURL: URL?
    let posterURL: URL?
    let releaseDate: String?
    let voteAverage: Double
    let mediaType: String
    var cast: [TMDBCastMember] = []
    var genres: [String] = []

    struct TMDBCastMember: Identifiable {
        let id: Int
        let name: String
        let character: String
        let profileURL: URL?
    }
}

struct FNOSTMDBDetailView: View {
    let item: FNOSTMDBItem
    let apiKey: String
    /// v120：MoviePilot 入库（未配置则隐藏按钮）
    var mpBase: String = ""
    var mpKey: String = ""
    /// v120：飞牛库内探测闭包（主视图注入，返回 true = 已在库）
    var inLibraryCheck: ((FNOSTMDBItem) async -> Bool)? = nil
    let onDismiss: () -> Void

    @State private var detail: FNOSTMDBDetail?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    // MARK: v123 富数据状态
    @State private var videos: [FNOSTMDBClient.TMDBVideo] = []
    @State private var similar: [FNOSTMDBItem] = []
    @State private var logoURL: URL?
    @State private var tagline: String = ""
    @State private var runtimeText: String = ""
    @State private var statusText: String = ""
    @State private var languageText: String = ""
    @State private var voteCount: Int = 0
    @State private var contentRating: String = ""
    @State private var director: String = ""
    @State private var companies: [String] = []
    @State private var productionRows: [(String, String)] = []
    @State private var trailer: FNOSTMDBClient.TMDBVideo?   // 全屏播放的预告（Identifiable）
    @State private var similarDetailItem: FNOSTMDBItem?  // 相似推荐点击进详情
    /// v180: 人物弹窗（主要演员点击查看，TMDB 附官方简介）
    @State private var popupPerson: FNOSPersonInfo?
    /// v125：Hero 海报取色（详情页背景高斯模糊用）
    @State private var themeColor: Color?

    /// v120：入库按钮状态机
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
                        // Hero 区（参考图排版：徽章/标题/logo/类型·分级/简介/年份·时长/按钮 + 右下主演导演）
                        heroSection(size: geo.size)
                        // v132: 演员头像行（infoSection 里的 cast 部分提取到 hero 下方）
                        if let cast = detail?.cast, !cast.isEmpty {
                            castAvatarSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v123: 预告片行
                        if !videos.filter({ $0.isTrailer }).isEmpty {
                            trailerSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v123: 花絮·幕后行
                        if !videos.filter({ $0.isBonus }).isEmpty {
                            bonusSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v123: 相关内容行
                        if !similar.isEmpty {
                            similarSection
                                .padding(.horizontal, 60)
                                .padding(.bottom, 40)
                                .focusable()
                                #if os(tvOS)
                                .focusSection()
                                #endif
                        }
                        // v123: 制作信息卡 + 底部三列
                        if !productionRows.isEmpty {
                            productionSection
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
        // v123: 预告片全屏播放
        .fullScreenCover(item: $trailer) { video in
            FNOSPipedPlayerView(
                videoKey: video.key,
                title: video.name,
                onDismiss: { trailer = nil }
            )
        }
        // v123: 相似推荐进详情
        .fullScreenCover(item: $similarDetailItem) { simItem in
            FNOSTMDBDetailView(
                item: simItem,
                apiKey: apiKey,
                mpBase: mpBase,
                mpKey: mpKey,
                inLibraryCheck: inLibraryCheck,
                onDismiss: { similarDetailItem = nil }
            )
        }
        // v180: 人物弹窗（主要演员点击查看，TMDB 附官方简介）
        .fullScreenCover(item: $popupPerson) { person in
            FNOSPersonPopupSheet(person: person, onClose: { popupPerson = nil })
                .task {
                    // TMDB 人物拉官方简介，拉到后原位替换弹窗内容（id 不变不重播动画）
                    guard person.bio == nil,
                          let pid = Int(person.id.replacingOccurrences(of: "tmdb-cast-", with: "")) else { return }
                    guard let detail = await FNOSTMDBClient.personDetail(id: pid, apiKey: apiKey),
                          let bio = detail["biography"] as? String, !bio.isEmpty else { return }
                    if popupPerson?.id == person.id {
                        popupPerson = FNOSPersonInfo(id: person.id, name: person.name, role: person.role, avatarURL: person.avatarURL, bio: bio)
                    }
                }
        }
    }

    // MARK: - v120 入库状态机

    private func refreshLibState() async {
        guard mpConfigured else { return }
        libState = .checking
        // 1) MoviePilot 订阅态
        let subId = await FNOSMoviePilotClient.lookupSubscribe(
            base: mpBase, apiKey: mpKey, tmdbid: item.id
        )
        // 2) 飞牛库内探测（标题模糊匹配）
        var inLib = false
        if let check = inLibraryCheck {
            inLib = await check(item)
        }
        libState = inLib ? .inLibrary : (subId != nil ? .subscribed : .idle)
    }

    private func addToLibrary() async {
        guard libState == .idle else { return }
        libState = .adding
        let (ok, message) = await FNOSMoviePilotClient.addSubscribe(
            base: mpBase,
            apiKey: mpKey,
            tmdbid: item.id,
            type: item.mediaType,
            name: item.title,
            year: item.year
        )
        if ok {
            mpMessage = ""
            libState = .subscribed
        } else {
            mpMessage = message.isEmpty ? "添加失败" : message
            libState = .idle
        }
    }

    // MARK: - Hero（严格按参考图排版：左下徽章→标题→类型·分级→简介→年份·时长→按钮；右下主演/导演）

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // backdrop 或 poster
            if let backdrop = detail?.backdropURL ?? item.backdropURL {
                FNOSAsyncImage(url: backdrop, headers: [:])
                    .frame(width: size.width, height: size.width * 9 / 16)
                    .clipped()
            }

            // 渐变压暗：左黑右透（护左下文案）+ 下黑上透
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
                // 荣誉/分级徽章胶囊
                if !contentRating.isEmpty {
                    Text(contentRating)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.white.opacity(0.18))
                                .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1))
                        )
                }

                // 标题：有 logo 用品牌 logo 图（参考图即 logo），无则文字标题
                if let logo = logoURL {
                    FNOSAsyncImage(url: logo, headers: [:], contentMode: .fit)
                        .frame(height: 120)
                        .frame(maxWidth: 560, alignment: .leading)
                } else {
                    Text(detail?.title ?? item.title)
                        .font(.system(size: 40, weight: .bold))
                        .lineLimit(2)
                        .foregroundColor(.white)
                }

                // 类型 · 分级 + 评分
                HStack(spacing: 12) {
                    Text(detail?.mediaType == "tv" ? "剧集" : "电影")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.55), lineWidth: 1))
                    if let genres = detail?.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " · "))
                    }
                    if let rating = detail?.voteAverage, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                        }
                    }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.85))

                // 简介（两行）
                if let overview = detail?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                // 格式徽章行：年份 · 片长
                HStack(spacing: 12) {
                    if let year = detailYear { Text(year) }
                    if !runtimeText.isEmpty { Text(runtimeText) }
                    if voteCount > 0 { Text("\(voteCount) 人评价") }
                }
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.7))

                // v120：加入影视库按钮（状态机——逻辑未改）
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
                    // v180: 移除 disabled——按钮是 Hero 唯一焦点锚点，禁用会释放焦点导致下键失效
                    // （action 已有 guard libState == .idle 幂等保护，重复确认不会重复订阅）

                    if !mpMessage.isEmpty {
                        Text(mpMessage)
                            .font(.system(size: 15))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)

            // 右下：主演 / 导演（严格按参考图）
            if !heroCastNames.isEmpty || !director.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !heroCastNames.isEmpty {
                        Text("主演 \(heroCastNames)")
                    }
                    if !director.isEmpty {
                        Text("导演 \(director)")
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

    /// 主演前 3 名（右下展示用）
    private var heroCastNames: String {
        (detail?.cast.prefix(3).compactMap { $0.name }.joined(separator: ", ")) ?? ""
    }

    /// v132: 演员头像行（从 infoSection 提取到 hero 下方）
    @ViewBuilder
    private var castAvatarSection: some View {
        if let cast = detail?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("主要演员")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(cast) { member in
                            // v180: 点击演员查看人物弹窗（TMDB 附官方简介）
                            Button {
                                let bigAvatar = member.profileURL.flatMap {
                                    URL(string: $0.absoluteString.replacingOccurrences(of: "/w185/", with: "/w500/"))
                                }
                                popupPerson = FNOSPersonInfo(
                                    id: "tmdb-cast-\(member.id)",
                                    name: member.name,
                                    role: member.character,
                                    avatarURL: bigAvatar
                                )
                            } label: {
                                VStack(spacing: 8) {
                                    if let profile = member.profileURL {
                                        FNOSAsyncImage(url: profile, headers: [:])
                                            .frame(width: 80, height: 80)
                                            .clipShape(Circle())
                                    } else {
                                        Circle()
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 80, height: 80)
                                    }
                                    Text(member.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineLimit(1)
                                    Text(member.character)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                .frame(width: 80)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
            }
        }
    }

    private var detailYear: String? {
        detail?.releaseDate ?? item.releaseDate
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // v123: 标语
            if !tagline.isEmpty {
                Text(tagline)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(.white.opacity(0.7))
            }
            // 简介
            if let overview = detail?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(6)
            }

            // 类型
            if let genres = detail?.genres, !genres.isEmpty {
                HStack(spacing: 10) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.white.opacity(0.12))
                            )
                    }
                }
            }

            // 演员
            if let cast = detail?.cast, !cast.isEmpty {
                Text("主要演员")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(cast) { member in
                            VStack(spacing: 8) {
                                if let profile = member.profileURL {
                                    FNOSAsyncImage(url: profile, headers: [:])
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 80, height: 80)
                                }
                                Text(member.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                Text(member.character)
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
            let json = try await FNOSTMDBClient.richDetail(
                id: item.id,
                mediaType: item.mediaType,
                apiKey: apiKey
            )

            let overview = json["overview"] as? String ?? item.overview
            let releaseDate = json["release_date"] as? String
                ?? json["first_air_date"] as? String
                ?? item.releaseDate
            let voteAverage = json["vote_average"] as? Double ?? item.voteAverage
            let backdropPath = json["backdrop_path"] as? String
            let posterPath = json["poster_path"] as? String

            // 类型
            let genreList = (json["genres"] as? [[String: Any]])?.compactMap { g in
                g["name"] as? String
            } ?? []

            // 演员
            let credits = json["credits"] as? [String: Any]
            let castList = (credits?["cast"] as? [[String: Any]])?.prefix(10).compactMap { c -> FNOSTMDBDetail.TMDBCastMember? in
                guard let cid = c["id"] as? Int else { return nil }
                let name = c["name"] as? String ?? ""
                let character = c["character"] as? String ?? ""
                let profilePath = c["profile_path"] as? String
                let profileURL = profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") }
                return FNOSTMDBDetail.TMDBCastMember(id: cid, name: name, character: character, profileURL: profileURL)
            } ?? []

            // v123: 导演（credits.crew job=Director）
            let crew = credits?["crew"] as? [[String: Any]] ?? []
            let directors = crew.filter { ($0["job"] as? String) == "Director" }.compactMap { $0["name"] as? String }
            director = directors.joined(separator: " / ")

            // v123: 标语/片长/状态/语言/评分人数
            tagline = json["tagline"] as? String ?? ""
            if let rt = json["runtime"] as? Int, rt > 0 {
                runtimeText = rt >= 60 ? "\(rt / 60) 小时 \(rt % 60) 分钟" : "\(rt) 分钟"
            } else if let erts = json["episode_run_time"] as? [Int], let first = erts.first, first > 0 {
                runtimeText = "\(first) 分钟/集"
            }
            statusText = json["status"] as? String ?? ""
            languageText = json["original_language"] as? String ?? ""
            voteCount = json["vote_count"] as? Int ?? 0

            // v123: 分级（movie=release_dates，tv=content_ratings）
            contentRating = Self.parseContentRating(json: json, mediaType: item.mediaType)

            // v123: 制作公司
            companies = (json["production_companies"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []

            // v123: 组装制作信息卡行
            var rows: [(String, String)] = []
            if !runtimeText.isEmpty { rows.append(("片长", runtimeText)) }
            if !statusText.isEmpty { rows.append(("状态", statusText)) }
            if !contentRating.isEmpty { rows.append(("分级", contentRating)) }
            if !director.isEmpty { rows.append(("导演", director)) }
            if !languageText.isEmpty { rows.append(("原始语言", languageText.uppercased())) }
            if voteCount > 0 { rows.append(("评分人数", "\(voteCount) 人评价")) }
            if !companies.isEmpty { rows.append(("制作公司", companies.prefix(3).joined(separator: " / "))) }
            productionRows = rows

            // v123: 视频/相似/logo
            videos = FNOSTMDBClient.videos(from: json)
            similar = FNOSTMDBClient.similarItems(from: json)
            logoURL = FNOSTMDBClient.logoURL(from: json)

            let backdropURL = backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") }
            let posterURL = posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") }

            detail = FNOSTMDBDetail(
                id: item.id,
                title: item.title,
                overview: overview,
                backdropURL: backdropURL,
                posterURL: posterURL,
                releaseDate: releaseDate,
                voteAverage: voteAverage,
                mediaType: item.mediaType,
                cast: castList,
                genres: genreList
            )
            isLoading = false

            // v125：Hero 海报取色（详情页背景高斯模糊）
            themeColor = await FNOSDominantColor.color(for: backdropURL, headers: [:])
        } catch {
            print("FNOS⚠️TMDB 详情加载失败: \(error.localizedDescription)")
            isLoading = false
        }
    }

    /// 解析分级：movie 走 release_dates，tv 走 content_ratings
    private static func parseContentRating(json: [String: Any], mediaType: String) -> String {
        if mediaType == "tv", let cr = json["content_ratings"] as? [String: Any],
           let results = cr["results"] as? [[String: Any]] {
            // 优先 US，退第一个
            let us = results.first(where: { ($0["iso_3166_1"] as? String) == "US" }) ?? results.first
            return us?["rating"] as? String ?? ""
        }
        if mediaType == "movie", let rd = json["release_dates"] as? [String: Any],
           let results = rd["results"] as? [[String: Any]] {
            let us = results.first(where: { ($0["iso_3166_1"] as? String) == "US" }) ?? results.first
            if let dates = us?["release_dates"] as? [[String: Any]], let first = dates.first {
                return first["certification"] as? String ?? ""
            }
        }
        return ""
    }

    // MARK: - v123 新区块视图

    /// 预告片行
    private var trailerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("预告片")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(videos.filter { $0.isTrailer }) { video in
                        Button {
                            trailer = video
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    if let thumb = video.thumbnailURL {
                                        FNOSAsyncImage(url: thumb, headers: [:])
                                            .frame(width: 280, height: 158)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 280, height: 158)
                                    }
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 44))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                Text(video.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(width: 280, alignment: .leading)
                            }
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    /// v123: 花絮·幕后行（复用 trailer 全屏播放 cover）
    private var bonusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("花絮·幕后")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(videos.filter { $0.isBonus }) { video in
                        Button {
                            trailer = video
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    if let thumb = video.thumbnailURL {
                                        FNOSAsyncImage(url: thumb, headers: [:])
                                            .frame(width: 280, height: 158)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.white.opacity(0.1))
                                            .frame(width: 280, height: 158)
                                    }
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 44))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                Text(video.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(width: 280, alignment: .leading)
                            }
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    /// 相关内容行
    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("相关内容")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(similar) { sim in
                        Button {
                            similarDetailItem = sim
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FNOSAsyncImage(url: sim.posterURL, headers: [:], usePosterCache: true)
                                    .frame(width: 160, height: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(sim.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(2)
                                    .frame(width: 160, alignment: .leading)
                            }
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    /// 制作信息卡
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
}
