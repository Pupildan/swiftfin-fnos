//
// FNOSPlayerView.swift
// 飞牛影视播放器 —— KSPlayer 裸播放视图 + 自绘 Apple TV+ 式控制条。
//
// 设计要点：
// - 裸 KSVideoPlayer(UIViewRepresentable) + 完全自绘控制层；
// - 快进/快退/播放暂停三个主按钮相对进度条居中；倍速/弹幕/设置/音轨靠右；
// - 选中背景 = tvOS26 液态玻璃 .clear（圆形，比按钮略大，底部压暗保证可读）；
// - 进度条可聚焦：左右键步进预览（连按加速 10s→180s），停手 1 秒提交；
// - 遥控器转盘/触摸滑动 = UIPanGestureRecognizer 桥接，直接连续拖动进度；
// - 倍速 0.5/1.0/1.5/2.0 循环，弹幕时钟跟随倍速；
// - 3 秒无操作自动隐藏控制条；MENU 退出播放。
//

import AVFoundation
import CoreMedia
import KSPlayer
import SwiftUI
import UIKit

/// AVURLAsset 请求头 Key（ObjC 常量未暴露给 Swift，按官方字符串手动声明）
private let fnosAVHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

// MARK: - 播放源扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// PlaybackInfo 响应（Jellyfin/Emby 标准：POST Items/{id}/PlaybackInfo）
    struct FNOSPlaybackInfo: Decodable {
        let MediaSources: [FNOSPlaybackMediaSource]?

        struct FNOSPlaybackMediaSource: Decodable {
            let Id: String?
            let Container: String?
            let Path: String?
            let RunTimeTicks: Int64?
            let Name: String?
        }
    }

    /// 条目详情（宽松解析：飞牛各版本字段不完全一致，用 JSONSerialization 容错）。
    struct FNOSItemDetail {
        var mediaSourceID: String?
        var container: String?
        var runTimeTicks: Int64?
        var backdropTags: [String]?
        var people: [FNOSPerson] = []
        /// 视频流信息（判定杜比视界/HDR：VideoRangeType 形如 DOVI / DOVIWithHDR10 / HDR10 / SDR）
        var videoRangeType: String?
        var videoRange: String?
        var videoCodec: String?
        var videoProfile: String?
        var bitDepth: Int?
        /// 原始响应里出现过的键名（诊断用：确认 People 等字段服务端到底给不给）
        var rawKeys: [String] = []
        /// People 字段原始内容片段（诊断用）
        var peopleRaw: String = ""
    }

    struct FNOSPerson {
        let id: String?
        let name: String
        let role: String?
        let type: String?
        let imageTag: String?
    }

    /// GET Users/{uid}/Items/{itemId}
    /// 实测：这个端点会返回 MediaSources / People / RunTimeTicks（之前能播放正是靠它）。
    /// 解析一律走 JSONSerialization 手动取值，避免模型字段不匹配导致整体解码失败。
    func fetchItemDetail(itemID: String, userID: String) async throws -> FNOSItemDetail {
        // 显式声明需要的字段，尽量让服务端返回完整的 People / MediaSources
        let fields = "People,MediaSources,MediaStreams,Overview,Genres,OfficialRating,RunTimeTicks,ProductionYear,BackdropImageTags"
        let data = try await get(
            path: "Users/\(userID)/Items/\(itemID)",
            query: ["Fields": fields]
        )

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️条目详情非 JSON 对象: \(raw)")
            throw FNOSDirectError("条目详情格式异常")
        }

        var detail = FNOSItemDetail()
        detail.rawKeys = Array(root.keys).sorted()
        detail.runTimeTicks = (root["RunTimeTicks"] as? NSNumber)?.int64Value
        detail.backdropTags = root["BackdropImageTags"] as? [String]

        if let sources = root["MediaSources"] as? [[String: Any]], let first = sources.first {
            detail.mediaSourceID = (first["Id"] as? String) ?? (first["id"] as? String)
            detail.container = (first["Container"] as? String) ?? (first["container"] as? String)
            if let ticks = (first["RunTimeTicks"] as? NSNumber)?.int64Value, ticks > 0 {
                detail.runTimeTicks = ticks
            }
            if let streams = first["MediaStreams"] as? [[String: Any]],
               let video = streams.first(where: { (($0["Type"] as? String) ?? "").lowercased() == "video" })
            {
                detail.videoRangeType = video["VideoRangeType"] as? String
                detail.videoRange = video["VideoRange"] as? String
                detail.videoCodec = video["Codec"] as? String
                detail.videoProfile = video["Profile"] as? String
                detail.bitDepth = (video["BitDepth"] as? NSNumber)?.intValue
            }
            let depthText = detail.bitDepth.map { String($0) + "bit" } ?? ""
            let vCodec = detail.videoCodec ?? "?"
            let vProfile = detail.videoProfile ?? ""
            let vRange = detail.videoRange ?? "?"
            let vRangeType = detail.videoRangeType ?? "?"
            print("FNOS✅ 条目详情 \(itemID) → 媒体源 \(detail.mediaSourceID ?? "nil") 容器 \(detail.container ?? "?") 视频 \(vCodec) \(vProfile) range=\(vRange)/\(vRangeType) \(depthText)")
        } else {
            print("FNOS⚠️ 条目详情 \(itemID) 无 MediaSources")
        }

        if let peopleDict = root["People"] {
            detail.peopleRaw = String(describing: peopleDict).prefix(80).description
        } else {
            detail.peopleRaw = "nil(无该键)"
        }

        if let people = root["People"] as? [[String: Any]] {
            detail.people = Self.parsePeople(people)
            print("FNOSℹ️ 演员/制作 \(detail.people.count) 人（Items/{id}）")
        }

        // People 键存在但为空：换 Items/{id} 路径 + UserId 再试一次
        if detail.people.isEmpty {
            if let altData = try? await get(
                path: "Items/\(itemID)",
                query: ["UserId": userID, "Fields": "People"]
            ),
                let altRoot = try? JSONSerialization.jsonObject(with: altData) as? [String: Any]
            {
                if let people = altRoot["People"] as? [[String: Any]] {
                    detail.people = Self.parsePeople(people)
                    print("FNOSℹ️ 演员(备用端点 Items/{id}) \(detail.people.count) 人")
                } else {
                    print("FNOS⚠️ 演员备用端点无 People 键")
                    detail.peopleRaw += " | 备用: 无People键"
                }
            }
        }

        return detail
    }

    static func parsePeople(_ people: [[String: Any]]) -> [FNOSPerson] {
        people.compactMap { dict in
            guard let name = dict["Name"] as? String, !name.isEmpty else { return nil }
            return FNOSPerson(
                id: dict["Id"] as? String,
                name: name,
                role: dict["Role"] as? String,
                type: dict["Type"] as? String,
                imageTag: dict["PrimaryImageTag"] as? String
            )
        }
    }

    /// 播放源信息（含视频色彩信息，用于杜比视界/HDR 分流）
    struct FNOSPlaybackSourceInfo {
        let mediaSourceID: String
        let container: String?
        let videoRangeType: String?
        let videoRange: String?
        let videoCodec: String?
        let videoProfile: String?
        let bitDepth: Int?
    }

    /// 条目播放源（fnOS 硬性要求：stream 的 MediaSourceId 必须传真实值，空值一律 400）
    func playbackSource(itemID: String, userID: String) async throws -> FNOSPlaybackSourceInfo {
        let detail = try await fetchItemDetail(itemID: itemID, userID: userID)
        guard let id = detail.mediaSourceID, !id.isEmpty else {
            throw FNOSDirectError("该条目没有可用的媒体源")
        }
        return FNOSPlaybackSourceInfo(
            mediaSourceID: id,
            container: detail.container,
            videoRangeType: detail.videoRangeType,
            videoRange: detail.videoRange,
            videoCodec: detail.videoCodec,
            videoProfile: detail.videoProfile,
            bitDepth: detail.bitDepth
        )
    }

    /// 演员头像 URL
    func personImageURL(personID: String, tag: String?, maxWidth: Int = 300) -> URL? {
        guard let tag, !tag.isEmpty else { return nil }
        return try? url(
            path: "Items/\(personID)/Images/Primary",
            query: ["maxWidth": String(maxWidth), "quality": "85", "tag": tag]
        )
    }

    /// 播放直链（static=true 原始流；容器可能是 MKV，由 KSPlayer 引擎分流处理）
    func streamURL(itemID: String, mediaSourceID: String) -> URL? {
        do {
            return try url(
                path: "Videos/\(itemID)/stream",
                query: [
                    "static": "true",
                    "MediaSourceId": mediaSourceID,
                    "api_key": token,
                ]
            )
        } catch {
            print("FNOS❗️播放 URL 构造失败 \(itemID): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 液态玻璃辅助（tvOS26，选中才挂；.clear 更透明，底部压暗保证可读）

extension View {
    /// 选中背景：纯色半透明 + 自定义放大动画（阻断焦点引擎对材质的识别，无系统默认高亮底色）
    func fnosGlass(_ active: Bool, in shape: some Shape) -> some View {
        self
            .background(active ? Color.black.opacity(0.4) : Color.clear, in: shape)
            .scaleEffect(active ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

// MARK: - 转盘/触摸滑动桥接（SwiftUI 无公开 scroll wheel API，走 UIKit 手势）

final class FNOSPanBridge: NSObject, UIGestureRecognizerDelegate {
    static let shared = FNOSPanBridge()
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    /// v196: 弹层打开时返回 false 让位——否则 KS 视频层手势会抢走滑动手势，
    /// 导致弹幕设置滑块在 KS 上滑不动（MPV 无此竞争所以体验正常）。
    var shouldBegin: () -> Bool = { true }

    @objc func handle(_ gesture: UIPanGestureRecognizer) {
        onPan?(gesture)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin()
    }
}

// MARK: - v190/v192 弹幕设置面板滑动桥（触摸板/转盘滑动连续调节聚焦滑块）

/// 面板背景宿主（本身不吃触摸）：把手势挂在内容根视图上，滑动增量直接回调给面板绑定——
/// v192 修正: 旧版把增量写 UserDefaults 再靠 @AppStorage 回读，滑块填充/数值不即时跟随（用户实测
/// 「滑很多次才动一点点」）；现在宿主持有回调闭包（闭包直接改 @AppStorage 属性），滑块随滑动即时进退。
/// v206: 去掉 private——FNOSSkipSettingsSheet（独立文件）也复用这块滑动桥。
struct FNOSPanelPanHostView: UIViewRepresentable {
    /// 是否允许接管滑动（弹幕设置弹窗显示且焦点在某个滑块行上）
    let isEnabled: () -> Bool
    /// 滑动增量回调（points，按事件消费；正=向右）
    let onPanDelta: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var hostView: UIView?
        var isEnabled: () -> Bool = { false }
        var onPanDelta: (CGFloat) -> Void = { _ in }

        func attach() {
            guard let host = hostView else { return }
            var root = host
            while let superview = root.superview, !(superview is UIWindow) {
                root = superview
            }
            if root.gestureRecognizers?.contains(where: {
                ($0 as? UIPanGestureRecognizer)?.name == "fnos.danmu.panel.pan"
            }) == true {
                return
            }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.name = "fnos.danmu.panel.pan"
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            root.addGestureRecognizer(recognizer)
        }

        @objc func handle(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .changed else { return }
            let dx = gesture.translation(in: gesture.view).x
            gesture.setTranslation(.zero, in: gesture.view)
            onPanDelta(dx)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled(), let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            // 仅水平意图才接管；垂直滑动留给焦点引擎在行间移动
            return abs(translation.x) > abs(translation.y)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        // 视图入树后再爬根挂手势（此时 superview 链才完整）
        DispatchQueue.main.async { context.coordinator.attach() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPanDelta = onPanDelta
    }
}

// MARK: - 播放容器

struct FNOSPlayerContainerView: View {

    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String
    /// 单集所属剧名（弹幕按剧名+集数匹配；item.SeriesName 缺失时用这个兜底）
    var seriesName: String? = nil
    /// 同剧全部分集（进度条下方换集条；电影为空即不显示）
    /// v212: 继续播放入口等未传分集时，容器按剧集级 guid 自拉兜底（fetchedEpisodes）
    var episodes: [FNOSItem] = []
    /// 点击换集回调（由详情页重建播放目标实现切集）
    var onSelectEpisode: ((FNOSItem) -> Void)? = nil
    /// 所属剧 Id（v87：剧集续播位置记录用）
    var seriesID: String? = nil
    /// 继续播放起点（0~1 比例，来自服务端多端同步进度；nil = 从头播）
    var startFraction: Double? = nil
    /// 继续播放起点（秒，v91 直通——详情页本地记录不再经 RunTimeTicks 换算）
    var startSeconds: Double? = nil
    /// v96 原生直通条目（直播频道）：play/info(guid) → media/range 直链，走 mpv
    var nativeItemGUID: String? = nil

    @Environment(\.dismiss)
    private var dismiss

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var danmuEngine = FNOSDanmuEngine()

    @State private var showDanmu = true
    @State private var streamURL: URL?
    @State private var containerInfo: String?
    /// 视频色彩信息（杜比视界/HDR 分流用）
    @State private var videoRangeType: String?
    @State private var videoCodec: String?
    @State private var videoBitDepth: Int?
    /// 杜比视界/HDR10 兼容输出开关（首页设置可关，用于 A/B 对比）
    @AppStorage("fnos.play.hdr10Compat") private var hdr10Compat = true
    /// 解码后视频轨真实的色彩范围（飞牛兼容层的 VideoRangeType 常报 SDR，不可信，以播放器轨道为准）
    @State private var streamDynamicRange: String?
    @State private var notice = "准备播放…"
    @State private var didSetup = false

    // MARK: mpv 引擎（实验）—— 解决杜比视界 P5 偏色
    /// 设置里可强制所有片源走 mpv（默认 false：KS 优先）
    @AppStorage("fnos.play.engineMPV") private var useMPVEngine = false
    /// 自动分流：KSPlayer 处理不了的片源（杜比视界 / AV1）自动切 mpv
    @AppStorage("fnos.play.autoEngine") private var autoEngine = true
    /// 本条目是否强制走 mpv（探测到 P5/P7 或解码轨实测命中）
    @State private var forceMPV = false
    /// 已探测出"这片子 KS 能正确解"（P8/HDR10/SDR），解码轨实测就不再触发切换
    @State private var ksProfileConfirmed = false
    /// 探测只跑一次
    @State private var probeStarted = false
    /// 元数据/探测漏掉、播放中才发现是杜比视界时，记住已切过一次，避免来回跳
    @State private var didAutoSwitch = false
    /// 引擎切换时把播放进度带过去（无感续播）
    @State private var handoffPosition: Double = 0
    /// 继续播放 seek 只做一次（首个时间回调触发，不猜引擎状态枚举）
    @State private var didResumeSeek = false
    // v86 播放进度上报：10s 节流；mpv 记最后位置供 stopped 上报
    @State private var lastReportAt: Date = .distantPast
    @State private var lastMPVPosition: Double = 0
    // v94 原生上报上下文（飞牛 play/record 需要 media_guid + 原生 item_guid）
    @State private var reporterNative: FNOSNativeClient?
    @State private var reporterMediaGUID: String?
    @State private var reporterItemGUID: String?
    // v206: 剧集级 parent_guid（跳过片头片尾配置挂这里；resolveReporter 解析时带回）
    @State private var reporterParentGUID: String?
    // v87 续播：本地进度为可靠主链路；记录 > 30s 时弹「从头/继续」选择（3s 自动续播）
    @State private var pendingResumeTarget: Double?
    @State private var resumeAutoTask: Task<Void, Never>?
    @State private var lastLocalSaveAt: Date = .distantPast
    /// v88：转盘手势本会话已挂载标记（防同会话重复挂；跨会话由 onPan 清空重挂解决）
    @State private var panAttached = false
    /// v212: 继续播放入口等未传分集时容器自拉的兜底分集（详情页入口外部传入优先）
    @State private var fetchedEpisodes: [FNOSItem] = []
    @State private var didFetchEpisodes = false

    /// v212: 选集条数据源——外部传入优先，否则用容器自拉的兜底分集
    private var allEpisodes: [FNOSItem] { episodes.isEmpty ? fetchedEpisodes : episodes }

    /// 剧集自动连播：当前集在本列表里的下一集
    private var nextEpisode: FNOSItem? {
        guard item.type == "Episode",
              let idx = allEpisodes.firstIndex(where: { $0.Id == item.Id }),
              idx + 1 < allEpisodes.count else { return nil }
        return allEpisodes[idx + 1]
    }

    /// 10s 节流的进度上报（v94：飞牛原生 play/record，兼容层 Sessions 是空壳已定案）。
    /// v96：直播频道不记录（直播无续播语义）。
    private func throttledProgressReport(_ seconds: Double) {
        guard item.type != "LiveChannel" else { return }
        guard Date().timeIntervalSince(lastReportAt) > 10 else { return }
        lastReportAt = Date()
        guard let native = reporterNative, let mg = reporterMediaGUID, let ig = reporterItemGUID else { return }
        Task { _ = await native.playRecord(mediaGUID: mg, itemGUID: ig, ts: seconds) }
    }

    /// v94：解析原生上报上下文（标题搜条目 → item_guid → play/info → media_guid），
    /// 成功后立即上报起播位置。失败只留诊断，不影响播放与本地续播。
    @MainActor
    private func resolveReporter() async {
        guard reporterNative == nil else { return }
        // v96：直播频道不记录观看进度（无续播语义）
        if nativeItemGUID != nil || item.type == "LiveChannel" { return }
        guard let credentials = FNOSAuthStore.shared.credentials,
              let nativeToken = credentials.nativeToken, !nativeToken.isEmpty else {
            FNOSDiag.shared.add("上报: 无原生 token（不同步）", dedupeKey: "rep.tok")
            return
        }
        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        let isEp = item.type == "Episode"
        guard let range = await native.mediaRange(
            itemTitle: isEp ? nil : item.Name,
            seriesTitle: isEp ? (item.SeriesName ?? seriesName) : nil,
            episodeNumber: isEp ? item.IndexNumber : nil
        ) else {
            FNOSDiag.shared.add("上报: 原生条目未匹配（不同步）", dedupeKey: "rep.none.\(item.Id)")
            return
        }
        reporterNative = native
        reporterMediaGUID = range.mediaGUID
        reporterItemGUID = range.itemGUID
        // v206: 存剧集级 parent_guid（片头片尾设置面板推服务端用）
        reporterParentGUID = range.parentGUID
        // v184: 带回服务器跳过配置（片头结束点/片尾开始点）
        skipOpening = range.skipOpening
        skipEnding = range.skipEnding
        // v185 诊断: 跳过配置解析结果（自动跳过片头片尾排查）
        FNOSDiag.shared.add("play_config 解析: intro=\(range.skipOpening.map { "\(Int($0))s" } ?? "无") ending=\(range.skipEnding.map { "\(Int($0))s" } ?? "无")", dedupeKey: "rep.skip")
        let startTS = resumeStartSeconds ?? 0
        _ = await native.playRecord(mediaGUID: range.mediaGUID, itemGUID: range.itemGUID, ts: startTS)
        FNOSDiag.shared.add("上报: 起播 ts=\(Int(startTS))（原生协议）")
    }

    /// 探测到的片源摘要（显示在控制条上）
    @State private var sourceSummary: String?
    /// mpv 用的原生直链解析结果（含整季分集，供播放器内换集）
    @State private var mpvRange: FNOSNativeClient.MediaRange?
    @State private var mpvClient: FNOSNativeClient?
    @State private var mpvToken: String?
    /// v184: 自动跳过片头/片尾（服务器 play_config 数据，各单次触发）
    @State private var skipOpening: Double?
    @State private var skipEnding: Double?
    @State private var introSkipped = false
    @State private var endingSkipped = false
    /// 解析失败 → 自动退回 KSPlayer，避免停在黑屏
    @State private var mpvFailed = false
    @State private var mpvNotice = "准备 mpv…"

    // 控制条状态
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var scrubActive = false
    @State private var scrubValue: Double = 0
    @State private var scrubStep: Double = 10
    @State private var scrubLevel = 0
    @State private var lastScrubMove: Date?
    @State private var isSheetPresented = false
    @State private var audioSheetPresented = false
    /// v185: 内嵌字幕轨选择弹层
    @State private var subtitleSheetPresented = false
    /// v206: 片头片尾跳过设置弹层（独立按钮，与弹幕设置同款玻璃面板）
    @State private var skipSettingsPresented = false
    /// v206: 设置面板防抖推服务端的任务（0.5s 内连续改值只发一次，Web 端同语义）
    @State private var skipPushTask: Task<Void, Never>?
    /// v207: 片头片尾面板实时位置/总时长（面板打开期间由进度回调更新，用户规格=定位当前播放位置）
    @State private var skipPanelPos: Double = 0
    @State private var skipPanelDur: Double = 0
    @FocusState private var focus: Control?
    // 换集条：默认不展开（一上来就渲染 24 张缩略图会跟弹幕争内存，拖动进度条容易闪退）
    @State private var showEpisodeStrip = false
    @FocusState private var focusedChip: String?
    /// v190: KS 内嵌字幕当前文本（纯文本 + 软件默认字体渲染，不要描边/阴影——
    /// 用户实测：字幕自带的 ASS 描边样式渲染出来是线条骨架字，弃用原样式）
    @State private var embeddedSubtitleText = ""

    private enum Control: Hashable {
        case rewind, playPause, forward, rate, danmu, danmuSettings, audio, subtitle, scrubber
        case skipSettings
        case resumeStartOver, resumeContinue
    }

    private let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        // v200: 容器必须用 ZStack 而不是 Group——Group 会把修饰符分发给每个子视图，
        // 导致下面的 onAppear/onDisappear 在内核切换（KS↔MPV）时各自触发：
        // MPV onAppear(true) 先、KS onDisappear(false) 后 → 最终 false → MPV 播放中进系统屏保。
        // ZStack 让修饰符归属容器本身，只在播放器开/关时各触发一次。
        ZStack {
            if useMPVEngine || forceMPV || nativeItemGUID != nil {
                mpvLayer
            } else {
                ksLayer
            }
        }
        // 无感探测：KS 正常起播，同时后台问一次飞牛"这片子是什么格式"，
        // 只有 P5/P7（KS 必然偏色）才在几百毫秒内切到 mpv 并带进度续播。
        .overlay(alignment: .bottom) {
            // v190: 内嵌字幕渲染层（KS 路径）——软件默认字体直出纯文本，无描边/无阴影；
            // SwiftUI Text 自适配内容尺寸，overlay 贴底对齐（v189 居中 bug 不会复发）
            if !embeddedSubtitleText.isEmpty {
                Text(embeddedSubtitleText)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 160)
                    .padding(.bottom, 150)
                    .allowsHitTesting(false)
            }
        }
        .task {
            // v214: 继续播放选集排查全景快照（引擎路径/外部数据/字段完整性一次看清）
            FNOSDiag.shared.add("播放器容器: type=\(item.type ?? "nil") nativeGUID=\(nativeItemGUID != nil) 外部episodes=\(episodes.isEmpty ? "无" : "\(episodes.count)") SeriesId=\(item.SeriesId?.prefix(8) ?? "nil") SeriesName=\(item.SeriesName ?? "nil")")
            await fetchEpisodesIfNeeded()
        }
        .task { await probeProfile() }
        // v94：原生上报上下文解析 + 起播上报（多端同步写通道）
        .task { await resolveReporter() }
        // v197: 屏保所有权归容器——整个播放会话（KS/MPV 及引擎自动切换）期间一律禁止屏保。
        // 之前内核切换时 KS 的 onDisappear 把 isIdleTimerDisabled 重置 false、MPV 的 onAppear 又设 true，
        // 顺序不定 → MPV 播放中会进系统屏保（用户实测）。容器统一持有，内核只设 true、不再设 false。
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: 片源格式探测（无感切换的核心）

    /// 判定用的是真实档位，不是元数据：
    /// - 兼容层 `color_range_type` 恒为 null、`VideoRangeType` 也拿不到 → 只能问原生 `/stream`
    /// - `dv_profile = 5`（IPTPQc2，无 HDR10 基线层）→ KS 必偏色 → 切 mpv
    /// - `dv_profile = 8`（如《阿凡达：火与烬》compat_id=1）→ 自带 HDR10 基线层，KS 解出来就是对的 → 留 KS
    @MainActor
    /// 继续播放起点（秒）：v91 秒数直通优先；比例路径在条目 RunTimeTicks
    /// 缺失/单位出格（plausibleSeconds 判 nil）时按标准 100ns 兜底估算
    private var resumeStartSeconds: Double? {
        if let startSeconds { return startSeconds }
        guard let startFraction else { return nil }
        if let seconds = FNOSItem.plausibleSeconds(
            ticks: item.RunTimeTicks,
            isEpisode: item.type == "Episode"
        ) {
            return startFraction * seconds
        }
        if let ticks = item.RunTimeTicks, ticks > 0 {
            return startFraction * Double(ticks) / 10_000_000
        }
        return nil
    }

    private func probeProfile() async {
        guard !probeStarted else { return }
        probeStarted = true
        guard !useMPVEngine, autoEngine else { return }

        guard let credentials = FNOSAuthStore.shared.credentials,
              let nativeToken = credentials.nativeToken, !nativeToken.isEmpty
        else {
            print("FNOSℹ️无原生 token，跳过片源格式探测")
            return
        }

        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        let series = item.SeriesName ?? seriesName
        guard let range = await native.mediaRange(
            itemTitle: item.Name,
            seriesTitle: series,
            episodeNumber: item.IndexNumber
        ) else { return }

        guard let traits = await native.videoTraits(mediaGUID: range.mediaGUID) else {
            print("FNOS⚠️片源格式探测失败，交给解码轨实测兜底")
            return
        }

        sourceSummary = traits.summary
        print("FNOSℹ️片源格式 \(traits.summary) needsMPV=\(traits.needsMPV)")

        guard traits.needsMPV else {
            ksProfileConfirmed = true
            return
        }

        // 已经在播的话，把当前进度带过去
        handoffPosition = Double(coordinator.timemodel.currentTime)
        mpvToken = nativeToken
        mpvClient = native
        mpvRange = range
        print("FNOSℹ️\(traits.summary) → 自动切换 mpv，续播 @\(String(format: "%.1f", handoffPosition))s")
        forceMPV = true
    }

    // MARK: mpv 引擎入口

    @ViewBuilder
    private var mpvLayer: some View {
        if let mpvRange, let mpvClient, let mpvToken {
            FNOSMPVPlayerView(
                item: item,
                title: item.Name ?? seriesName ?? "",
                authToken: mpvToken,
                native: mpvClient,
                range: mpvRange,
                // v210: 兼容层 client+全分集 → mpv 选集卡真实缩略图/标题/简介（零额外请求）
                compatClient: client,
                compatEpisodes: allEpisodes,
                initialSeek: handoffPosition > 1 ? handoffPosition : resumeStartSeconds,
                skipOpening: mpvRange.skipOpening,
                skipEnding: mpvRange.skipEnding,
                autoSelected: !useMPVEngine,
                onProgress: { position, duration in
                    lastMPVPosition = position
                    throttledProgressReport(position)
                    // v92：本地进度存完整条目 + 剧集观看位置（mpv 侧补齐）
                    FNOSProgressStore.save(
                        itemID: item.Id,
                        seconds: position,
                        item: item,
                        runtimeSeconds: duration > 0 ? duration : nil
                    )
                    if item.type == "Episode", let sid = seriesID {
                        FNOSProgressStore.saveSeriesProgress(
                            seriesID: sid,
                            episodeItemID: item.Id,
                            episodeNumber: item.IndexNumber ?? 0,
                            seconds: position
                        )
                    }
                },
                // v119：mpv 引擎播放结束 —— 与 KS 的 .playedToTheEnd 同一条链路
                //（清进度 → 延迟 1.2s 开下一集，也让「看完」提示有时间出现）
                onFinished: {
                    danmuEngine.setRate(0)
                    FNOSProgressStore.clear(itemID: item.Id)
                    if let next = nextEpisode {
                        print("FNOSℹ️[mpv] 自动连播 → \(next.Name ?? "?")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            onSelectEpisode?(next)
                        }
                    }
                }
            ) {
                if let native = reporterNative, let mg = reporterMediaGUID, let ig = reporterItemGUID {
                    Task { _ = await native.playRecord(mediaGUID: mg, itemGUID: ig, ts: lastMPVPosition) }
                }
                dismiss()
            }
        } else if mpvFailed {
            // 原生直链解析失败：不卡黑屏，直接回退到已跑通的 KSPlayer 链路
            ksLayer
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(mpvNotice)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .task {
                await prepareMPV()
            }
            .onExitCommand {
                dismiss()
            }
        }
    }

    /// 解析原生直链：剧名 + 集数 → 季 → 集 → play/info → media/range
    @MainActor
    private func prepareMPV() async {
        // v90：mpv 路径的续播诊断（此前只有 KS prepare 有，剧集走 mpv 时无痕）
        if let resume = resumeStartSeconds, resume > 5 {
            FNOSDiag.shared.add("续播(mpv): 记录 \(Int(resume))s → initialSeek")
        } else {
            FNOSDiag.shared.add("续播(mpv): 无起始进度（从头播放）", dedupeKey: "resume.mpv.none.\(item.Id)")
        }
        guard let credentials = FNOSAuthStore.shared.credentials else {
            mpvNotice = "未登录"
            mpvFailed = true
            return
        }
        guard let nativeToken = credentials.nativeToken, !nativeToken.isEmpty else {
            mpvNotice = "缺少飞牛原生 token，请在设置里重新登录"
            mpvFailed = true
            return
        }

        let native = FNOSNativeClient(baseURL: credentials.serverURL, token: nativeToken)
        let series = item.SeriesName ?? seriesName

        // v96：原生直通条目（直播频道）按 guid 直接换直链（协议实测：play/info 对频道 guid 返回 media_guid）
        if let nativeGUID = nativeItemGUID {
            guard let range = await native.mediaRange(itemGUID: nativeGUID) else {
                mpvNotice = "直播流解析失败"
                mpvFailed = true
                return
            }
            mpvToken = nativeToken
            mpvClient = native
            mpvRange = range
            return
        }

        guard let range = await native.mediaRange(
            itemTitle: item.Name,
            seriesTitle: series,
            episodeNumber: item.IndexNumber
        ) else {
            print("FNOS⚠️ mpv 直链解析失败，回退 KSPlayer")
            mpvFailed = true
            return
        }

        mpvToken = nativeToken
        mpvClient = native
        mpvRange = range
    }

    // MARK: - KSPlayer 引擎（原稳定链路）

    private var ksLayer: some View {
        ZStack(alignment: .bottom) {
            if let streamURL {
                playerView(url: streamURL)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(notice)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 弹幕层：关闭时仅隐藏图层，时钟随播放器继续走，重开无缝衔接
            if showDanmu {
                FNOSDanmuView(engine: danmuEngine)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if controlsVisible, streamURL != nil {
                controlBar
                    .transition(.opacity)
            }

            // v87 续播选择弹窗：底部悬浮，3s 未确认自动续播
            if let target = pendingResumeTarget {
                resumeChoiceOverlay(target: target)
                    .zIndex(6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onExitCommand {
            dismiss()
        }
        .onPlayPauseCommand {
            togglePlayPause()
        }
        .task {
            await prepare()
        }
        .onDisappear {
            hideTask?.cancel()
            scrubCommitTask?.cancel()
            resumeAutoTask?.cancel()
            danmuEngine.setRate(0)
            // v88：清全局转盘桥，下一会话重挂新闭包（否则写进已销毁会话的状态）
            FNOSPanBridge.shared.onPan = nil
            // v94：KS 侧停止上报（飞牛原生 play/record → 多端可见）
            if let native = reporterNative, let mg = reporterMediaGUID, let ig = reporterItemGUID {
                Task { _ = await native.playRecord(mediaGUID: mg, itemGUID: ig, ts: Double(coordinator.timemodel.currentTime)) }
            }
            // v119：离开播放器恢复系统屏保策略
            // v197: 屏保开关改由播放器容器统一持有（整个会话内禁屏保），此处不再置 false——
            // 否则 DoVi 自动切到 mpv 时会把 isIdleTimerDisabled 重置 false，MPV 播放中进系统屏保
        }
        // v189/v190: 三弹窗播放器内 overlay——玻璃直接折射播放画面（.sheet 系统压暗+死灰板已否决）。
        // v190: 面板缩小并锚定在控制条功能按钮上方（不在屏幕正中），出现/消失带过渡动画
        .overlay(alignment: .bottomTrailing) {
            if isSheetPresented {
                Group {
                    if subtitleSheetPresented {
                        // v185: 内嵌字幕轨选择（与音轨同款交互）；v186 标题区分
                        // v191: 映射到中性 FNOSTrackOption（KS/MPV 共用同一款玻璃弹窗）
                        FNOSAudioTracksSheet(
                            title: "字幕切换",
                            tracks: subtitleTracks.map {
                                FNOSTrackOption(id: $0.trackID, title: $0.description, isCurrent: $0.isEnabled)
                            },
                            onClose: { closeSheet() }
                        ) { option in
                            if let track = subtitleTracks.first(where: { $0.trackID == option.id }) {
                                coordinator.playerLayer?.player.select(track: track)
                            }
                            closeSheet()
                        }
                    } else if audioSheetPresented {
                        FNOSAudioTracksSheet(
                            title: "音轨切换",
                            tracks: audioTracks.map {
                                FNOSTrackOption(id: $0.trackID, title: $0.description, isCurrent: $0.isEnabled)
                            },
                            onClose: { closeSheet() }
                        ) { option in
                            if let track = audioTracks.first(where: { $0.trackID == option.id }) {
                                coordinator.playerLayer?.player.select(track: track)
                            }
                            closeSheet()
                        }
                    } else if skipSettingsPresented {
                        // v207: 片头片尾设置（实时位置 + 取当前位置 + ±1s 微调；改值即时生效 + 防抖同步服务端）
                        FNOSSkipSettingsSheet(
                            opening: skipOpening,
                            ending: skipEnding,
                            currentPosition: skipPanelPos,
                            totalDuration: skipPanelDur,
                            canSync: reporterParentGUID?.isEmpty == false && reporterNative != nil,
                            onClose: { closeSheet() },
                            onChange: { op, ed in commitSkipSettings(opening: op, ending: ed) },
                            onCapture: { isIntro in
                                // 捕捉 = 标记此处，本次播放不再自动跳（下次播放起效）
                                if isIntro { introSkipped = true } else { endingSkipped = true }
                                FNOSDiag.shared.add("跳过捕捉: \(isIntro ? "片头" : "片尾") → pos=\(Int(skipPanelPos))s")
                            }
                        )
                    } else {
                        FNOSDanmuSettingsSheet(onClose: { closeSheet() })
                    }
                }
                .padding(.trailing, 90)
                .padding(.bottom, 170)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// v189: overlay 弹窗关闭（原 .sheet onDismiss 逻辑平移；v190 带过渡动画）
    private func closeSheet() {
        withAnimation(.easeInOut(duration: 0.2)) {
            audioSheetPresented = false
            subtitleSheetPresented = false
            skipSettingsPresented = false
            isSheetPresented = false
        }
        DispatchQueue.main.async {
            focus = .playPause
        }
        revealControls()
    }

    /// v206: 片头片尾改值 → 本端立即生效 + 0.5s 防抖推服务端（Web 端同语义自动保存）。
    /// 未解析出 parent_guid（上报链路失败/直播/电影无父级）时只留诊断，不影响本地生效。
    private func commitSkipSettings(opening: Double?, ending: Double?) {
        skipOpening = opening
        skipEnding = ending
        guard let parent = reporterParentGUID, !parent.isEmpty else {
            FNOSDiag.shared.add("跳过设置: 无 parent_guid，仅本端生效", dedupeKey: "skip.push.no")
            return
        }
        skipPushTask?.cancel()
        skipPushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let ok = await reporterNative?.setSkipConfig(
                parentGUID: parent,
                skipOpening: Int(opening?.rounded() ?? 0),
                skipEnding: Int(ending?.rounded() ?? 0)
            ) ?? false
            FNOSDiag.shared.add("跳过设置推送: \(ok ? "成功" : "失败") intro=\(Int(opening ?? 0))s ending=\(Int(ending ?? 0))s → \(parent.prefix(8))…")
        }
    }

    // MARK: 裸播放视图（无 KSPlayer 内置控制）+ 转盘滑动桥接

    private func playerView(url: URL) -> some View {
        KSVideoPlayer(coordinator: coordinator, url: url, options: makeOptions())
            .onPlay { currentTime, _ in
                // 继续播放：无弹窗时首次时间回调静默 seek（两 KS 引擎通用）；
                // 有弹窗（记录 > 30s）时等用户选择 / 3s 自动续播，不抢跑
                if !didResumeSeek, pendingResumeTarget == nil,
                   let target = resumeStartSeconds, target > 5 {
                    didResumeSeek = true
                    coordinator.seek(time: target)
                    print("FNOSℹ️继续播放: seek → \(Int(target))s")
                }
                // v87 本地进度（续播主链路）+ 剧集观看位置（5s 节流落盘；v92 存完整条目供首页合并）
                // v96：直播频道不写本地续播记录
                if item.type != "LiveChannel",
                   Date().timeIntervalSince(lastLocalSaveAt) > 5 {
                    lastLocalSaveAt = Date()
                    let total = Double(coordinator.timemodel.totalTime)
                    FNOSProgressStore.save(
                        itemID: item.Id,
                        seconds: currentTime,
                        item: item,
                        runtimeSeconds: total > 0 ? total : nil
                    )
                    if item.type == "Episode", let sid = seriesID {
                        FNOSProgressStore.saveSeriesProgress(
                            seriesID: sid,
                            episodeItemID: item.Id,
                            episodeNumber: item.IndexNumber ?? 0,
                            seconds: currentTime
                        )
                    }
                }
                // v207: 片头片尾面板打开期间实时刷新当前位置（用户规格=定位当前播放位置）
                if skipSettingsPresented {
                    skipPanelPos = currentTime
                    skipPanelDur = Double(coordinator.timemodel.totalTime)
                }
                // v184: 自动跳过片头/片尾（服务器 play_config 数据，各单次触发）
                // v208: seek 一律切主线程执行（KS 回调在后台线程，播放中直接调 seek 有内部状态
                //       竞态风险=v207「跳过后选集/进度失效」的头号嫌疑）+ 触发/后置状态留 9999 日志
                if let so = skipOpening, !introSkipped, currentTime > 0.5, currentTime < so - 0.5 {
                    introSkipped = true
                    let snapTotal = Double(coordinator.timemodel.totalTime)
                    FNOSDiag.shared.add("自动跳过片头触发: so=\(Int(so)) cur=\(Int(currentTime)) total=\(Int(snapTotal))")
                    Task { @MainActor in
                        coordinator.seek(time: so)
                        FNOSDiag.shared.add("自动跳过片头 seek 提交 → \(Int(so))s（主线程）")
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        FNOSDiag.shared.add("跳过seek后1.2s: cur=\(Int(coordinator.timemodel.currentTime)) total=\(Int(coordinator.timemodel.totalTime))")
                    }
                }
                // v206: skip_ending 是「距结尾秒数」（Web 端语义），开始点 = 总时长 - se
                if let se = skipEnding, !endingSkipped, se > 0 {
                    let total = Double(coordinator.timemodel.totalTime)
                    let endingStart = total - se
                    if total > 2, endingStart > total * 0.1, currentTime >= endingStart, currentTime < total - 2 {
                        endingSkipped = true
                        FNOSDiag.shared.add("自动跳过片尾触发: se=\(Int(se)) cur=\(Int(currentTime)) total=\(Int(total))")
                        Task { @MainActor in
                            coordinator.seek(time: total - 1.5)
                            FNOSDiag.shared.add("自动跳过片尾 seek 提交 → \(Int(total - 1.5))s（主线程）")
                        }
                    }
                }
                // v190: 渲染 KSPlayer 内嵌字幕（裸播放视图不含 KSPlayer 字幕 UI，需自行显示）。
                // 只取纯文本、软件默认字体渲染——原文的描边/字体样式全部弃用（线条骨架字）
                let subText = coordinator.subtitleModel.parts
                    .compactMap { $0.text?.string }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if embeddedSubtitleText != subText { embeddedSubtitleText = subText }
                throttledProgressReport(currentTime)
                danmuEngine.sync(mediaTime: currentTime)
            }
            .onStateChanged { _, state in
                // 开播后读取解码轨真实色彩范围（服务端 VideoRangeType 不可信）
                if streamDynamicRange == nil {
                    Task { @MainActor in probeStreamRange() }
                }
                switch state {
                case .playedToTheEnd:
                    danmuEngine.setRate(0)
                    // v87：看完清进度；剧集自动连播下一集（经详情页「关播→重开」既有链路）
                    FNOSProgressStore.clear(itemID: item.Id)
                    if let next = nextEpisode {
                        print("FNOSℹ️自动连播 → \(next.Name ?? "?")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            onSelectEpisode?(next)
                        }
                    }
                case .paused, .error:
                    danmuEngine.setRate(0)
                default:
                    danmuEngine.setRate(Double(coordinator.playbackRate))
                }
            }
            .ignoresSafeArea()
            .focusable(!controlsVisible && !isSheetPresented)
            .onMoveCommand { _ in
                // 控制条隐藏时：任意方向键唤出控制条
                revealControls()
            }
            .onTapGesture {
                revealControls()
            }
            .onAppear {
                // v119：播放期间禁止系统屏保/休眠
                UIApplication.shared.isIdleTimerDisabled = true
                attachPanRecognizer()
            }
    }

    /// 读取解码后视频轨的真实色彩范围；实测为杜比视界时把显示模式改回 HDR10。
    /// 免费版 KSPlayer 不解 DoVi 的 IPTPQc2，若让电视按「杜比视界」显示模式去解一路普通 PQ 画面就会紫绿。
    @MainActor
    private func probeStreamRange() {
        guard let player = coordinator.playerLayer?.player,
              let video = player.tracks(mediaType: .video).first
        else { return }

        let label: String
        switch video.dynamicRange {
        case .dolbyVision: label = "杜比视界"
        case .hdr10: label = "HDR10"
        case .hlg: label = "HLG"
        default: label = "SDR"
        }
        streamDynamicRange = label
        print("FNOSℹ️解码轨实测色彩: \(label) \(video.nominalFrameRate)fps")

        guard video.dynamicRange == .dolbyVision else { return }

        // 先按 HDR10 请求显示模式：即使随后切换 mpv 失败而留在 KS，也不至于进杜比视界模式乱解
        if hdr10Compat {
            applyHDR10DisplayCriteria(refreshRate: video.nominalFrameRate)
        }

        // 元数据没报杜比视界（兼容层常见漏报），播起来才从解码轨发现：
        // 无感切到 mpv，并把当前进度带过去续播。只切一次，避免来回跳。
        if autoEngine, !useMPVEngine, !forceMPV, !ksProfileConfirmed, !didAutoSwitch {
            didAutoSwitch = true
            let position = Double(coordinator.timemodel.currentTime)
            handoffPosition = position
            print("FNOSℹ️实测杜比视界 → 自动切换 mpv，续播 @\(String(format: "%.1f", position))s")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                forceMPV = true
            }
        }
    }

    /// 把 tvOS 的显示模式请求改成 HDR10（2），避免电视进杜比视界模式解错信号
    @MainActor
    private func applyHDR10DisplayCriteria(refreshRate: Float) {
        guard let window = UIApplication.shared.windows.first else { return }
        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayCriteriaMatchingEnabled else { return }
        let rate = refreshRate > 0 ? refreshRate : 24
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: rate,
            videoDynamicRange: 2
        )
        print("FNOSℹ️显示模式请求改为 HDR10 @\(rate)fps")
    }

    /// 在 KSPlayer 的 UIView 上挂 UIPanGestureRecognizer：遥控器转盘/触摸滑动 → 连续拖动进度
    private func attachPanRecognizer() {
        // v88 修复：桥是全局单例、闭包捕获【本会话】的 State 存储——旧会话遗留的
        // onPan 会让第二次播放的转盘/滑动写进已销毁的状态（表现为拖动进度条失效）。
        // 每次进入播放器都重挂：清旧闭包 → 新 videoView 上挂新手势；panAttached 防同会话重复挂。
        guard !panAttached else { return }
        panAttached = true
        FNOSPanBridge.shared.onPan = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let videoView = coordinator.playerLayer?.player.view else {
                print("FNOS❗️挂滑动手势失败: 找不到播放器视图")
                return
            }
            let recognizer = UIPanGestureRecognizer(target: FNOSPanBridge.shared, action: #selector(FNOSPanBridge.handle(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = FNOSPanBridge.shared
            videoView.addGestureRecognizer(recognizer)
            print("FNOSℹ️滑动手势已挂载")

            FNOSPanBridge.shared.onPan = { gesture in
                // 门控：只有进度条聚焦时滑动才拖进度，否则转盘滑动用于移动焦点
                switch gesture.state {
                case .began:
                    if focus == .scrubber {
                        scrubActive = true
                        scrubValue = Double(coordinator.timemodel.currentTime)
                    } else if !controlsVisible {
                        revealControls()
                    }
                case .changed:
                    guard focus == .scrubber, scrubActive else { return }
                    let translation = gesture.translation(in: gesture.view)
                    gesture.setTranslation(.zero, in: gesture.view)
                    // 滑动灵敏度：1px ≈ 0.2s（转盘快速滚动可快速拖动）
                    let delta = Double(translation.x) * 0.2
                    let total = Double(max(coordinator.timemodel.totalTime, 1))
                    scrubValue = min(max(scrubValue + delta, 0), total)
                    scheduleScrubCommit()
                case .ended, .cancelled:
                    if focus == .scrubber {
                        commitScrubIfNeeded()
                    }
                default:
                    break
                }
            }
            // v196: 弹层打开时让位给面板滑动桥（否则 KS 视频层手势会抢走滑动手势，
            // 导致弹幕设置滑块在 KS 上滑不动；MPV 无此竞争所以体验正常）
            FNOSPanBridge.shared.shouldBegin = { !isSheetPresented }
        }
    }

    // MARK: 自绘控制条

    private var controlBar: some View {
        VStack(spacing: 20) {
            // 片名 + 状态（左）
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.Name ?? "播放")
                        .font(.headline)
                        .lineLimit(1)
                    if !notice.isEmpty {
                        Text(notice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let sourceSummary {
                        Text("片源 \(sourceSummary) · KSPlayer")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                Spacer()
            }

            // 主按钮（快进/快退/播放暂停）相对进度条居中；功能按钮靠右
            HStack(spacing: 22) {
                controlButton(.rewind, icon: "gobackward.15") {
                    coordinator.skip(interval: -15)
                }
                controlButton(.playPause, icon: isPlaying ? "pause.fill" : "play.fill", primary: true) {
                    togglePlayPause()
                }
                controlButton(.forward, icon: "goforward.15") {
                    coordinator.skip(interval: 15)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: 14) {
                    rateButton
                    controlButton(.danmu, icon: "text.bubble") {
                        showDanmu.toggle()
                    }
                    .opacity(showDanmu ? 1 : 0.35)
                    controlButton(.danmuSettings, icon: "slider.horizontal.3") {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            audioSheetPresented = false
                            subtitleSheetPresented = false
                            skipSettingsPresented = false
                            isSheetPresented = true
                        }
                    }
                    // v206: 片头片尾设置按钮（与弹幕设置同款功能键列）
                    controlButton(.skipSettings, icon: "tv.inset.filled") {
                        // v208: 打开瞬间立即同步真实位置（v207 靠下一个 onPlay tick 更新，
                        // 打开瞬间显示 00:00/旧值 → 用户立刻按确认就捕捉到错位置=「时间读取不准确」）
                        skipPanelPos = Double(coordinator.timemodel.currentTime)
                        skipPanelDur = Double(coordinator.timemodel.totalTime)
                        withAnimation(.easeInOut(duration: 0.22)) {
                            audioSheetPresented = false
                            subtitleSheetPresented = false
                            skipSettingsPresented = true
                            isSheetPresented = true
                        }
                        // v207: 面板打开时的链路快照（9999 日志可查，服务端值/parent_guid/类型一次看清）
                        FNOSDiag.shared.add("跳过面板打开: intro=\(skipOpening.map { "\(Int($0))s" } ?? "关") ending=\(skipEnding.map { "\(Int($0))s" } ?? "关") parent=\(reporterParentGUID?.isEmpty == false) type=\(item.type) pos=\(Int(skipPanelPos))s")
                    }
                    if !audioTracks.isEmpty {
                        controlButton(.audio, icon: "waveform") {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                subtitleSheetPresented = false
                                skipSettingsPresented = false
                                audioSheetPresented = true
                                isSheetPresented = true
                            }
                        }
                    }
                    // v185: 内嵌字幕轨切换（与音轨同款 sheet）
                    if !subtitleTracks.isEmpty {
                        controlButton(.subtitle, icon: "character.textbox") {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                audioSheetPresented = false
                                skipSettingsPresented = false
                                subtitleSheetPresented = true
                                isSheetPresented = true
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)

            // 进度条（可聚焦拖动/快滑）+ 时间
            HStack(spacing: 14) {
                Text(timeString(displayTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
                scrubber
                Text(timeString(Double(coordinator.timemodel.totalTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
            }

            // 换集条：只有「焦点在进度条 + 再按一次下键」才展开
                if !allEpisodes.isEmpty && showEpisodeStrip {
                episodeStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 48)
        .padding(.top, 24)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onChange(of: focus) { newValue in
            if newValue != .scrubber {
                commitScrubIfNeeded()
                // 焦点离开进度条、又不在换集条上 → 把换集条收起来
                if focusedChip == nil { showEpisodeStrip = false }
            }
            scheduleHide()
        }
        .onChange(of: focusedChip) { newValue in
            // 焦点进入换集条 → 取消自动隐藏；离开 → 重新计时
            if newValue == nil {
                scheduleHide()
            } else {
                hideTask?.cancel()
            }
        }
    }

    /// 进度条下方的换集条：缩略图横排，当前集描边高亮，点选即切集（v187: 回滚 v186 网格面板）
    private var episodeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(allEpisodes) { ep in
                        let isCurrent = ep.Id == item.Id
                        let isFocused = focusedChip == ep.Id
                        Button {
                            guard !isCurrent else {
                                print("FNOSℹ️换集: 已是当前集，忽略")
                                return
                            }
                            print("FNOSℹ️换集点击 → 第 \(ep.IndexNumber ?? 0) 集《\(ep.Name ?? "?")》 id=\(ep.Id)")
                            onSelectEpisode?(ep)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FNOSAsyncImage(
                                    url: client.episodeStillURL(item: ep, maxWidth: 640),
                                    headers: client.mediaHeaders,
                                    contentMode: .fill
                                )
                                .frame(width: 424, height: 238)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white, lineWidth: isCurrent ? 2.5 : 0)
                                )

                                // v188: 集数 + 标题
                                HStack(spacing: 10) {
                                    Text("第 \(ep.IndexNumber ?? 0) 集")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(isCurrent ? .white : .white.opacity(0.75))
                                    Text(ep.Name ?? "")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                // v188: 简介（最多两行，固定占位等高）
                                Text(ep.Overview ?? "")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.62))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .padding(10)
                            .frame(width: 424, height: 324, alignment: .top)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isFocused ? Color.white.opacity(0.26) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                            )
                            .scaleEffect(isFocused ? 1.05 : 1.0)
                            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 10, y: 4)
                            .animation(.easeOut(duration: 0.12), value: isFocused)
                        }
                        .buttonStyle(FNOSBareButtonStyle())
                        .focusEffectDisabled()
                        .focused($focusedChip, equals: ep.Id)
                        .onMoveCommand { direction in
                            // 上键收起换集条并回进度条
                            if direction == .up {
                                showEpisodeStrip = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    focus = .scrubber
                                }
                            }
                        }
                        .id(ep.Id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 348)
            .onAppear {
                proxy.scrollTo(item.Id, anchor: .center)
            }
        }
        .onChange(of: focusedChip) { _ in
            revealControls()
        }
    }

    /// 可聚焦进度条：选中后左右键步进预览，连按自动加速
    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, geo.size.width * displayFraction))
            }
            .frame(height: focus == .scrubber ? 14 : 6)
            .animation(.easeOut(duration: 0.15), value: focus == .scrubber)
            .contentShape(Rectangle())
        }
        .frame(height: 40)
        .focusable(true)
        .focused($focus, equals: .scrubber)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                scrub(by: -1)
            case .right:
                scrub(by: 1)
            case .down:
                // 第一次按↓：展开换集条并把焦点交给当前集
                guard !allEpisodes.isEmpty else {
                    FNOSDiag.shared.add("KS选集条展不开: allEpisodes 为空（外部=\(episodes.isEmpty ? "无" : "有") fetched=\(fetchedEpisodes.count)）")
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showEpisodeStrip = true
                }
                FNOSDiag.shared.add("KS选集条展开: \(allEpisodes.count) 集")
                let target = allEpisodes.first(where: { $0.Id == item.Id })?.Id ?? allEpisodes.first?.Id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    focusedChip = target
                }
            default:
                break
            }
        }
    }

    /// 与 Hero 三个按钮同一套外观（FNOSFocusButtonLabel）：
    /// 未聚焦 = 黑 35% 胶囊 + 白图标；聚焦 = 纯白胶囊 + 黑图标 + 1.06 放大。
    /// 关键点：用 FNOSBareButtonStyle 而不是 .plain —— tvOS 的 .plain 在 ScrollView /
    /// 播放器叠层里仍会画系统白色圆角焦点板（就是之前那个大白方块）。
    private func controlButton(
        _ control: Control,
        icon: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            FNOSFocusButtonLabel(isFocused: focus == control, isPrimary: primary) {
                Image(systemName: icon)
                    .font(.system(size: primary ? 26 : 23, weight: .semibold))
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: control)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            // 下键明确落到进度条：换集条插入后焦点引擎可能跳过 scrubber
            if direction == .down { focus = .scrubber }
        }
    }

    /// 倍速按钮：0.5 → 1.0 → 1.5 → 2.0 循环
    private var rateButton: some View {
        Button {
            cycleRate()
        } label: {
            FNOSFocusButtonLabel(isFocused: focus == .rate, isPrimary: true) {
                Text(String(format: "%.1fx", coordinator.playbackRate))
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
            }
        }
        .buttonStyle(FNOSBareButtonStyle())
        .focused($focus, equals: .rate)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .down { focus = .scrubber }
        }
    }

    private func cycleRate() {
        let index = rateOptions.firstIndex(of: coordinator.playbackRate) ?? 1
        let next = rateOptions[(index + 1) % rateOptions.count]
        coordinator.playbackRate = next
        danmuEngine.setRate(Double(next))
        print("FNOSℹ️倍速: \(next)")
        revealControls()
    }

    // MARK: 快滑/拖动逻辑

    /// 当前展示时间：拖动预览优先，否则真实时间
    private var displayTime: Double {
        if scrubActive {
            return scrubValue
        }
        return Double(coordinator.timemodel.currentTime)
    }

    private var displayFraction: Double {
        let total = Double(max(coordinator.timemodel.totalTime, 1))
        return min(max(displayTime / total, 0), 1)
    }

    /// 方向键步进：0.2 秒内连续触发加速一档（10s→30s→60s→120s），停顿重置 10s。
    /// 拖动期间仅实时更新进度条位置与时间文本，停止后由 scheduleScrubCommit 执行一次 seek。
    private func scrub(by direction: Double) {
        let now = Date()
        if let last = lastScrubMove, now.timeIntervalSince(last) < 0.2 {
            scrubLevel = min(scrubLevel + 1, Self.scrubLadder.count - 1)
        } else {
            scrubLevel = 0
        }
        lastScrubMove = now
        scrubStep = Self.scrubLadder[scrubLevel]

        let total = Double(max(coordinator.timemodel.totalTime, 1))
        let base = scrubActive ? scrubValue : Double(coordinator.timemodel.currentTime)
        scrubActive = true
        scrubValue = min(max(base + direction * scrubStep, 0), total)
        scheduleScrubCommit()
        // 拖进度时不让控制条到点自动消失（否则拖到一半整条连 scrubber 一起没了）
        revealControls()
    }

    private static let scrubLadder: [Double] = [10, 30, 60, 120]

    private func scheduleScrubCommit() {
        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commitScrubIfNeeded()
        }
    }

    private func commitScrubIfNeeded() {
        guard scrubActive else { return }
        scrubActive = false
        coordinator.seek(time: scrubValue)
        print("FNOSℹ️进度提交: \(Int(scrubValue))s")
    }

    // MARK: 续播选择弹窗（v87：记录 > 30s 时底部弹出，3s 未确认自动续播）

    private func resumeChoiceOverlay(target: Double) -> some View {
        VStack(spacing: 14) {
            Text("检测到播放记录 · 已看到 \(timeString(target))")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 26) {
                Button {
                    cancelResumeChoice(startOver: true)
                } label: {
                    Text("从头开始")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focused($focus, equals: .resumeStartOver)

                Button {
                    resumeNow(target)
                } label: {
                    Text("继续播放")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                .buttonStyle(FNOSBareButtonStyle())
                .focused($focus, equals: .resumeContinue)
            }
            Text("3 秒后自动继续播放")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.82)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 150)
        .onAppear {
            // 默认焦点落「继续播放」（未确认即自动续播的语义一致）
            focus = .resumeContinue
            revealControls()
            resumeAutoTask?.cancel()
            resumeAutoTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                resumeNow(target)
            }
        }
    }

    /// 继续播放：seek 到记录位置，关闭弹窗
    private func resumeNow(_ target: Double) {
        resumeAutoTask?.cancel()
        didResumeSeek = true
        pendingResumeTarget = nil
        coordinator.seek(time: target)
        focus = .playPause
        revealControls()
        print("FNOSℹ️续播确认: → \(Int(target))s")
    }

    /// 从头开始：清本地记录（当前从 0 播着，无需 seek），关闭弹窗
    private func cancelResumeChoice(startOver: Bool) {
        resumeAutoTask?.cancel()
        didResumeSeek = true
        pendingResumeTarget = nil
        if startOver {
            FNOSProgressStore.clear(itemID: item.Id)
        }
        focus = .playPause
        revealControls()
    }

    // MARK: 状态助手

    private var isPlaying: Bool {
        coordinator.state.isPlaying
    }

    private var audioTracks: [MediaPlayerTrack] {
        coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
    }

    /// v185: 内嵌字幕轨（MKV 内封 ASS/SRT 等，KSPlayer 解码）
    private var subtitleTracks: [MediaPlayerTrack] {
        coordinator.playerLayer?.player.tracks(mediaType: .subtitle) ?? []
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }

    private func togglePlayPause() {
        if isPlaying {
            coordinator.playerLayer?.pause()
        } else {
            coordinator.playerLayer?.play()
        }
        revealControls()
    }

    /// 任意操作 → 显示控制条并重置 3 秒隐藏计时
    private func revealControls() {
        hideTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = true
            }
            DispatchQueue.main.async {
                focus = .playPause
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        guard !isSheetPresented else { return }
        // 焦点停在换集条上 / 正在拖进度时保持控制条常显：否则 3 秒后整条一起消失，用户点不到
        guard focusedChip == nil, !scrubActive else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                controlsVisible = false
                showEpisodeStrip = false
            }
            focus = nil
        }
    }

    // MARK: 准备（真实 MediaSourceId → 直链 → 弹幕）

    /// v212: 继续播放入口等未传分集时容器自拉兜底（端点与详情页 loadEpisodes 同款：
    /// 全剧集 Shows/{seriesId}/Episodes → 通用条目查询 Users/{uid}/Items?ParentId 兜底）。
    /// 失败静默（选集条继续隐藏，不影响播放）。
    /// v214: 全链路 FNOSDiag 日志 + SeriesId 缺失时先补查单集元数据（海报墙/Resume 查询
    /// Fields 未带 SeriesId → 条目 SeriesId=nil → 拿单集 Id 查 Shows/Episodes 必失败）。
    @MainActor
    private func fetchEpisodesIfNeeded() async {
        guard item.type == "Episode", episodes.isEmpty, !didFetchEpisodes else { return }
        didFetchEpisodes = true
        FNOSDiag.shared.add("分集自拉启动: id=\(item.Id.prefix(8)) SeriesId=\(item.SeriesId?.prefix(8) ?? "nil") SeriesName=\(item.SeriesName ?? "nil")")

        // SeriesId 缺失（Resume/海报墙查询 Fields 未带）→ 补查一次单集元数据
        var seriesId = item.SeriesId
        if (seriesId ?? "").isEmpty {
            do {
                let data = try await client.get(
                    path: "Users/\(userID)/Items",
                    query: ["Ids": item.Id, "Fields": "SeriesId,SeriesName"]
                )
                if let full = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items.first {
                    seriesId = full.SeriesId
                }
                FNOSDiag.shared.add("分集自拉补查 SeriesId: \(seriesId?.prefix(8) ?? "仍为 nil")")
            } catch {
                FNOSDiag.shared.add("分集自拉补查失败: \(error.localizedDescription)")
            }
        }
        guard let sid = seriesId, !sid.isEmpty else {
            FNOSDiag.shared.add("分集自拉放弃: SeriesId 无法确定（KS/compat 选集条将不可用）")
            return
        }

        let fields = "Overview,RunTimeTicks,OfficialRating,ParentIndexNumber,IndexNumber,PremiereDate,SeriesName"

        var all: [FNOSItem] = []
        // 端点 B：全剧集（带 UserId）
        do {
            let data = try await client.get(
                path: "Shows/\(sid)/Episodes",
                query: ["UserId": userID, "Fields": fields]
            )
            all = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
            FNOSDiag.shared.add("分集自拉(Shows/Episodes): \(all.count) 集")
        } catch {
            FNOSDiag.shared.add("分集自拉(Shows/Episodes)失败: \(error.localizedDescription)")
        }

        // 端点 C：通用条目查询兜底
        if all.isEmpty {
            do {
                let data = try await client.get(
                    path: "Users/\(userID)/Items",
                    query: [
                        "ParentId": sid,
                        "Recursive": "true",
                        "Limit": "500",
                        "SortBy": "ParentIndexNumber,IndexNumber",
                        "SortOrder": "Ascending",
                        "Fields": fields,
                    ]
                )
                all = try JSONDecoder().decode(FNOSItemsEnvelope.self, from: data).Items
                FNOSDiag.shared.add("分集自拉(Items 兜底): \(all.count) 集")
            } catch {
                FNOSDiag.shared.add("分集自拉(Items 兜底)失败: \(error.localizedDescription)")
            }
        }

        // 集号排序（与详情页一致：按季+集升序）
        if !all.isEmpty {
            all.sort { ($0.ParentIndexNumber ?? 0, $0.IndexNumber ?? 0) < ($1.ParentIndexNumber ?? 0, $1.IndexNumber ?? 0) }
            fetchedEpisodes = all
            FNOSDiag.shared.add("分集自拉完成: \(all.count) 集 → allEpisodes（KS 选集条/MPV 封面数据源）")
        }
    }

    private func prepare() async {
        guard !didSetup else { return }
        didSetup = true

        // 1) 取真实 MediaSourceId（fnOS 硬性要求）
        let source: FNOSDirectClient.FNOSPlaybackSourceInfo
        do {
            source = try await client.playbackSource(itemID: item.Id, userID: userID)
        } catch {
            print("FNOS❗️获取播放源失败: \(error)")
            notice = "❗️获取播放源失败: \(error.localizedDescription)"
            return
        }

        // 2) 构造直链
        guard let url = client.streamURL(itemID: item.Id, mediaSourceID: source.mediaSourceID) else {
            notice = "❗️播放地址构造失败"
            return
        }
        streamURL = url
        containerInfo = source.container
        videoRangeType = source.videoRangeType
        videoCodec = source.videoCodec
        videoBitDepth = source.bitDepth
        notice = ""

        // v87 续播选择：本地/服务端记录 > 30s → 底部弹「从头开始/继续播放」（3s 未确认自动续播）；
        // ≤30s 的小进度不弹窗，由 onPlay 的静默 seek 直接续
        if let resume = resumeStartSeconds, resume > 30 {
            pendingResumeTarget = resume
            FNOSDiag.shared.add("续播: 记录 \(Int(resume))s → 弹选择窗")
        } else if let resume = resumeStartSeconds {
            FNOSDiag.shared.add("续播: 记录 \(Int(resume))s → 静默续播")
        } else {
            // v89：链路诊断——出现这行说明 startFraction 没传到播放器（查调用链）
            FNOSDiag.shared.add("续播: 无起始进度（从头播放；若刚从记录进入则是 startFraction 断链）", dedupeKey: "resume.none.\(item.Id)")
        }

        // 3) 弹幕（真实服务端；剧集按「剧名 + 集数」匹配，电影按标题匹配）
        danmuEngine.setRate(1)
        let title = item.Name ?? "视频"
        let isEpisode = item.type == "Episode"
        let episodeNumber: Int? = isEpisode ? item.IndexNumber : nil
        let serieTitleResolved: String? = isEpisode
            ? ((item.SeriesName?.isEmpty == false ? item.SeriesName : seriesName))
            : nil
        notice = "弹幕匹配中…"
        await danmuEngine.load(title: title, seriesTitle: serieTitleResolved, episodeNumber: episodeNumber)
        switch danmuEngine.status {
        case .ready:
            notice = "弹幕 \(danmuEngine.commentCount) 条" + formatBadge
        case .failed(let message):
            notice = "弹幕失败: \(message)"
        default:
            notice = ""
        }
        revealControls()
    }

    // MARK: 色彩判定

    /// 杜比视界（Jellyfin 的 VideoRangeType：DOVI / DOVIWithHDR10 / DOVIWithEL / DOVIWithHDR10Plus…）
    private var isDolbyVision: Bool {
        if streamDynamicRange == "杜比视界" { return true }
        return (videoRangeType ?? "").uppercased().contains("DOVI")
    }

    private var isHDRContent: Bool {
        if let measured = streamDynamicRange {
            return measured != "SDR"
        }
        let t = (videoRangeType ?? "").uppercased()
        return t.contains("DOVI") || t.contains("HDR") || t.contains("HLG")
    }

    /// 控制条上的格式标记（识别结果一眼可见，便于确认分流是否生效）
    private var formatBadge: String {
        let t = (videoRangeType ?? "").uppercased()
        // 优先用解码后轨道实测（服务端元数据常把 DV 报成 SDR）
        var label: String
        if let measured = streamDynamicRange {
            label = measured
        } else if t.isEmpty {
            return ""
        } else if t.contains("DOVI") {
            label = t.contains("HDR10") ? "杜比视界 P8" : "杜比视界 P5"
        } else if t.contains("HLG") {
            label = "HLG"
        } else if t.contains("HDR") {
            label = "HDR10"
        } else {
            label = "SDR"
        }
        if let depth = videoBitDepth, depth > 8 {
            label += " \(depth)bit"
        }
        if isDolbyVision || isHDRContent {
            label += hdr10Compat ? " · HDR10 输出" : " · 直通"
        }
        return " · " + label
    }

    // MARK: 引擎分流（.mkv → FFmpeg；.mp4/.m3u8 → AVPlayer）

    private func makeOptions() -> KSOptions {
        let container = (containerInfo ?? "").lowercased()
        let isMKV = container.contains("matroska") || container.contains("mkv")

        KSOptions.firstPlayerType = isMKV ? KSMEPlayer.self : KSAVPlayer.self
        print("FNOSℹ️播放引擎: \(isMKV ? "FFmpeg (KSMEPlayer)" : "AVPlayer (KSAVPlayer)") · 容器: \(container.isEmpty ? "未知" : container) · \(formatBadge)")

        // 杜比视界：KSPlayer 免费版不做 DoVi(IPTPQc2)→RGB 的色彩转换，
        // 但 isDovi=true 会让 tvOS 把电视切到「杜比视界」显示模式，
        // 电视于是按 DV 去解一路普通 HDR10/PQ 画面 → 紫绿偏色。
        // 这里改为按 HDR10 请求显示模式，把 PQ 层交给电视自己色调映射（对 P7/P8 这类 HDR10 兼容层是正确的）。
        let options: KSOptions = (isDolbyVision && hdr10Compat) ? FNOSPlayerOptions() : KSOptions()
        if isHDRContent, hdr10Compat {
            options.destinationDynamicRange = .hdr10
        }

        // 鉴权头：fnOS 播放流必须带 X-Emby-Authorization（实测仅 api_key 会 400）
        // AVPlayer 引擎：通过 avOptions 注入 AVURLAsset 请求头
        options.avOptions[fnosAVHTTPHeaderFieldsKey] = client.mediaHeaders
        // FFmpeg 引擎：http 协议的 headers 选项（\r\n 分隔）
        let headerString = client.mediaHeaders
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        options.formatContextOptions["headers"] = headerString

        return options
    }
}

// MARK: - 播放选项（杜比视界 → HDR10 显示模式）

/// KSPlayer 免费版不解 DoVi 的 IPTPQc2 色彩空间，但 `updateVideo(isDovi: true)` 会把电视切到
/// 「杜比视界」显示模式，导致电视按 DV 去解一路普通 PQ 画面 → 紫绿偏色。
/// 这里把 DoVi 内容统一按 HDR10 请求显示模式，让电视自己做色调映射。
/// （P7/P8 这类带 HDR10 兼容层的片源效果正确；P5 因底层是 IPT 数据，仍需 mpv/libplacebo 才能完全还原）
final class FNOSPlayerOptions: KSOptions {

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        super.updateVideo(refreshRate: refreshRate, isDovi: false, formatDescription: formatDescription)
    }
}

// MARK: - 弹幕设置面板

// MARK: - v190 内嵌字幕：纯文本 + 软件默认字体（原 ASS 样式描边渲染为线条骨架字，用户令弃用）

struct FNOSDanmuSettingsSheet: View {

    @AppStorage("fnos.danmu.fontSize") private var fontSize: Double = 26
    @AppStorage("fnos.danmu.opacity") private var opacity: Double = 1
    @AppStorage("fnos.danmu.speed") private var speed: Double = 1
    /// v190: 弹幕显示区域（屏高比例；引擎泳道数与渲染层共用此值）
    @AppStorage("fnos.danmu.area") private var area: Double = 0.3
    /// v190: 隐藏底部固定弹幕（即时生效）
    @AppStorage("fnos.danmu.hideBottom") private var hideBottom = false

    /// v189: overlay 承载无 dismiss 环境，关闭由宿主回调
    let onClose: () -> Void

    /// v189: overlay 在 tvOS 不保证焦点自动移入（v173 教训）——appear 后程序化落首个控件
    @FocusState private var focusedControl: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("弹幕设置")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            sliderRow(id: "size", title: "字号", value: $fontSize, range: 16...44, step: 1) {
                "\(Int($0)) px"
            }
            sliderRow(id: "opacity", title: "不透明度", value: $opacity, range: 0.2...1.0, step: 0.025) {
                "\(Int(($0 * 100).rounded())) %"
            }
            sliderRow(id: "speed", title: "速度", value: $speed, range: 0.5...2.5, step: 0.05) {
                String(format: "%.2fx", $0)
            }
            // v190: 显示区域上限 75%——底部 260pt 是字幕保护区（不准显示弹幕，用户死规则）
            sliderRow(id: "area", title: "显示区域", value: $area, range: 0.25...0.75, step: 0.025) {
                "\(Int(($0 * 100).rounded())) % 屏"
            }

            // v190: 隐藏底部弹幕开关（即时生效，控制引擎丢弃底部固定弹幕）
            Button {
                hideBottom.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: hideBottom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                    Text("隐藏底部弹幕")
                        .font(.system(size: 16))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
            }
            .buttonStyle(.glass)
            .focused($focusedControl, equals: "hideBottom")
        }
        .padding(26)
        .frame(width: 680)
        // v189: iOS 26 官方液态玻璃面板——overlay 层级下直接对播放画面折射
        // v190: 面板随内容自适应（宿主 overlay 锚定在功能按钮上方，不再全屏居中）
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            // v190/v192: 触摸板/转盘滑动桥——滑动增量直接回调面板绑定（滑块即时跟随）
            FNOSPanelPanHostView(
                isEnabled: { sliderID(from: focusedControl) != nil },
                onPanDelta: { dx in
                    func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
                    let d = Double(dx)
                    // v196: 灵敏度较 v193 减半（用户实测步进太快）——一次满幅滑动≈走完量程
                    switch focusedControl {
                    case "size":    fontSize = clamp(fontSize + d * 0.15, 16, 44)
                    case "opacity": opacity = clamp(opacity + d * 0.003, 0.2, 1.0)
                    case "speed":   speed = clamp(speed + d * 0.0025, 0.5, 2.5)
                    case "area":    area = clamp(area + d * 0.0015, 0.25, 0.75)
                    default: break
                    }
                }
            )
        )
        // Menu 键关闭（焦点在面板内时路由到此处；FNOSReviewPopupSheet 同款模式）
        .onExitCommand(perform: onClose)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if focusedControl == nil { focusedControl = "size" }
            }
        }
    }

    /// v194: 连按/连滑加速（0.2s 内连续触发翻倍，最多 ×4；停顿回落到基础步长）
    @State private var sliderAccel: Double = 1
    @State private var lastSliderMove: Date? = nil

    /// v190: 仅四个滑块可被滑动调节；开关行不吃滑动手势
    private func sliderID(from control: String?) -> String? {
        guard let control, ["size", "opacity", "speed", "area"].contains(control) else { return nil }
        return control
    }

    /// v190: 无极滑块行（液态玻璃风格）。tvOS 系统 Slider 焦点行为不可靠（历史老坑），
    /// 复用播放器进度条同款自绘模式：focusable + onMoveCommand 左右步进，长按连发即无极调节。
    private func sliderRow(
        id: String,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: @escaping (Double) -> String
    ) -> some View {
        let isFocused = focusedControl == id
        let span = range.upperBound - range.lowerBound
        let fraction = min(max((value.wrappedValue - range.lowerBound) / span, 0), 1)
        let knob: CGFloat = isFocused ? 24 : 18
        return HStack(spacing: 18) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .frame(height: 8)
                    Capsule()
                        .fill(.white.opacity(isFocused ? 1.0 : 0.7))
                        .frame(width: max(8, geo.size.width * fraction), height: 8)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .offset(x: max(0, min(geo.size.width - knob, geo.size.width * fraction - knob / 2)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 38)
            .contentShape(Rectangle())
            .focusable(true)
            .focused($focusedControl, equals: id)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                // v194: 连按/连滑加速——0.2s 内连续触发翻倍（最多 ×4），停顿回落到基础步长
                let now = Date()
                let rapid = lastSliderMove.map { now.timeIntervalSince($0) < 0.2 } ?? false
                sliderAccel = rapid ? min(sliderAccel * 2, 2) : 1
                lastSliderMove = now
                let effective = step * sliderAccel
                switch direction {
                case .left:
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - effective)
                case .right:
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + effective)
                default:
                    break   // 上下交给焦点引擎在行间移动
                }
            }
            Text(display(value.wrappedValue))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(width: 110, alignment: .trailing)
        }
    }
}

// MARK: - 音轨/字幕选择面板（v189: overlay 承载 + 官方液态玻璃）

/// v191: KS/MPV 共用的轨道选项中性模型（KS=MediaPlayerTrack / mpv=MPVMediaTrack 都映射到它）
struct FNOSTrackOption: Identifiable, Hashable {
    let id: Int32
    let title: String
    let isCurrent: Bool
}

struct FNOSAudioTracksSheet: View {

    /// v186: 弹层标题（音轨切换 / 字幕切换）
    let title: String
    let tracks: [FNOSTrackOption]
    /// v189: overlay 承载无 dismiss 环境，关闭由宿主回调
    let onClose: () -> Void
    let onSelect: (FNOSTrackOption) -> Void

    /// v189: overlay 在 tvOS 不保证焦点自动移入（v173 教训）——appear 后程序化落当前轨
    @FocusState private var focusedRow: Int32?
    @FocusState private var focusedDone: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            if tracks.isEmpty {
                Text("没有可切换的选项")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(tracks) { track in
                            Button {
                                onSelect(track)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: track.isCurrent ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 17))
                                    Text(track.title)
                                        .font(.system(size: 16))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                            }
                            // v189: 官方液态玻璃按钮（tvOS 26），焦点态由系统渲染
                            .buttonStyle(.glass)
                            .focused($focusedRow, equals: track.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: 420)
            }

            Button {
                onClose()
            } label: {
                Text("完成")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 180, height: 46)
            }
            .buttonStyle(.glassProminent)
            .focused($focusedDone)
        }
        .padding(26)
        .frame(width: 600)
        // v189: iOS 26 官方液态玻璃面板——overlay 层级下直接对播放画面折射
        // v190: 面板随内容自适应（宿主 overlay 锚定在功能按钮上方，不再全屏居中）
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Menu 键关闭（焦点在面板内时路由到此处；FNOSReviewPopupSheet 同款模式）
        .onExitCommand(perform: onClose)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !tracks.isEmpty {
                    if focusedRow == nil {
                        focusedRow = tracks.first(where: { $0.isCurrent })?.id ?? tracks.first?.id
                    }
                } else {
                    focusedDone = true
                }
            }
        }
    }
}
