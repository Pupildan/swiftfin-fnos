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
            frodo = await FNOSDoubanClient.frodoDetail(id: item.id, category: item.category)
            celebrities = await FNOSDoubanClient.frodoCelebrities(id: item.id, category: item.category)
            reviews = await FNOSDoubanClient.frodoReviews(id: item.id, category: item.category)
        }
        .task { await refreshLibState() }
    }

    // MARK: - Hero（海报 backdrop + 左下文字 + 右下主演导演，同热门影视/番剧详情页）

    @ViewBuilder
    private func heroSection(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            // 高清海报作全宽 backdrop
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
        .disabled(libState != .idle)
    }

    // MARK: - 内容行（简介 + 主演头像 + 评论，frodo 数据）

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 32) {
            // 简介（contentSection 不再重复——已搬进 hero）
            // v132：简介已在 hero 里显示，此处只保留主演头像行和评论

            // 主演（圆形头像 + 角色，来自 frodo celebrities）
            if !celebrities.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("主演")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 20) {
                            ForEach(celebrities) { person in
                                VStack(spacing: 8) {
                                    if let avatar = person.avatarURL {
                                        FNOSAsyncImage(url: avatar, headers: ["Referer": "https://movie.douban.com/"])
                                            .frame(width: 80, height: 80)
                                            .clipShape(Circle())
                                    } else {
                                        Circle().fill(Color.white.opacity(0.1)).frame(width: 80, height: 80)
                                    }
                                    Text(person.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineLimit(1)
                                        .frame(width: 90)
                                    if !person.character.isEmpty {
                                        Text(person.character)
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                            .frame(width: 90)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if let f = frodo, !f.castNames.isEmpty {
                // v132：celebrities 接口失败时用 frodoDetail.castNames 文字降级
                VStack(alignment: .leading, spacing: 16) {
                    Text("主演")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text(f.castNames.joined(separator: " / "))
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.8))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 评论（frodo 短评）
            if !reviews.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("评论")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(reviews) { review in
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
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
                        }
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
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
            }
        }
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
