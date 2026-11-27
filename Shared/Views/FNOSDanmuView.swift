//
//  FNOSDanmuView.swift
//  飞牛影视 tvOS —— 弹幕数据层 + 设置面板接线
//
//  v217 两大改造：
//  1) 匹配：完全按 danmu_api 官方逻辑——构造标准文件名 `剧名.S01E02.1080p.WEB-DL.mkv`
//     交给 POST /api/v2/match，服务端 extractTitleSeasonEpisode 解析季/集后做精确匹配。
//     旧版自造「剧名 第N集 / S01E02 / EPn」逐个试、并盲取 matches.first，是错配根因。
//  2) 渲染：换用 Shared/DanmakuKit/FNOSDanmakuRender.swift 的 CATextLayer 图层引擎
//     （每帧只改 position、GPU 合成），替掉 SwiftUI TimelineView 每帧重建的卡顿方案。
//
//  ⚠️🚨 sync 铁律：FNOSDanmuEngine.sync(mediaTime:) 里 anchorMediaTime = mediaTime
//  是 v130 灾难回归后真机验证的唯一正确做法，v217 一行未动。新渲染引擎的时间源
//  就是 engine.mediaTime(at:)（同一 anchor 外推），不是另起一套时钟。
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - 弹幕数据模型

struct FNOSDanmuComment {
    /// 视频内时间（秒）
    let time: Double
    let text: String
    /// 1~3=滚动 4=底部 5=顶部（dandanplay 约定）
    let mode: Int
    let color: Color
    /// dandanplay p 字段的原始十进制 RGB（新渲染引擎直接用）
    let rgb: UInt32
}

// MARK: - 服务端 JSON（danmu_api / dandanplay 兼容协议）

private struct FNOSDanmuMatchResult: Decodable {
    let isMatched: Bool?
    let matches: [FNOSDanmuEpisodeRef]?
}

private struct FNOSDanmuSearchResult: Decodable {
    let animes: [FNOSDanmuAnime]?
}

struct FNOSDanmuAnime: Decodable {
    let animeId: Int
    let animeTitle: String?
    let episodes: [FNOSDanmuEpisodeRef]?
}

struct FNOSDanmuEpisodeRef: Decodable {
    let episodeId: Int
    let animeId: Int?
    let animeTitle: String?
    let episodeTitle: String?
    /// danmu_api search/episodes 直接给出的集号（有就优先用它校验）
    let episodeNumber: Int?
}

private struct FNOSDanmuCommentEnvelope: Decodable {
    let count: Int?
    let comments: [FNOSDanmuRawComment]?
}

private struct FNOSDanmuRawComment: Decodable {
    let cid: Int
    let p: String?
    let m: String?
}

// MARK: - 渲染时钟桥接（复用引擎 anchor 外推，不碰 sync）

/// 把 FNOSDanmuEngine 的 anchor 外推时间暴露给图层引擎。
/// 每帧读同一个外推值 → 播放/暂停/倍速/seek 全部自然生效。
@MainActor
final class FNOSDanmuRenderClock: FNOSDanmakuClock {
    weak var engine: FNOSDanmuEngine?
    init(engine: FNOSDanmuEngine) { self.engine = engine }
    var danmakuTime: TimeInterval {
        guard let engine else { return 0 }
        return engine.mediaTime(at: Date())
    }
}

// MARK: - 弹幕引擎（匹配 / 拉取 / 时间轴锚点）

@MainActor
final class FNOSDanmuEngine: ObservableObject {

    /// 用户自建弹幕服务（含 Key）
    static let defaultBaseURL = "http://192.168.10.120:9321/199780jjj"

    @Published var status: Status = .idle
    @Published var commentCount = 0
    /// 新渲染引擎的时间轴（一次构造，换集才重建）
    @Published private(set) var timeline: FNOSDanmakuTimeline?

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private var comments: [FNOSDanmuComment] = []
    private var nextIndex = 0
    private let maxLanePool = 20
    private var laneLastEntry: [Double] = []
    private var nextSeq = 0
    private(set) var active: [ActiveComment] = []
    private var lastSyncMediaTime: Double = 0
    private let travelDuration: Double = 30
    private let laneGap: Double = 3.5
    private let fixedDuration: Double = 5

    struct ActiveComment: Identifiable {
        let comment: FNOSDanmuComment
        let lane: Int
        let seq: Int
        var id: Int { seq }
    }

    /// 同步锚点：媒体时间 ↔ 墙钟时间 ↔ 倍速
    private var anchorMediaTime: Double = 0
    private var anchorWallTime: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var anchorRate: Double = 1

    init() { laneLastEntry = Array(repeating: -999, count: maxLanePool) }

    // MARK: 服务端加载

    /// - Parameters:
    ///   - title: 单集标题（电影直接用它匹配）
    ///   - seriesTitle: 剧名（剧集匹配的权威字段）
    ///   - seasonNumber: 季号（danmu_api 官方 S##E## 文件名需要）
    ///   - episodeNumber: 集号
    ///   - year: 发行年份（官方用于消歧同名剧）
    func load(
        title: String,
        seriesTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        year: Int? = nil
    ) async {
        status = .loading

        do {
            let episodeID: Int
            let isSeries = (seriesTitle?.isEmpty == false) && episodeNumber != nil
            if isSeries {
                episodeID = try await matchEpisodeID(
                    seriesTitle: seriesTitle!,
                    seasonNumber: seasonNumber ?? 1,
                    episodeNumber: episodeNumber!,
                    year: year,
                    fallbackTitle: title
                )
            } else {
                episodeID = try await matchEpisodeID(title: title, year: year)
            }
            let fetched = try await fetchComments(episodeID: episodeID)

            comments = fetched.sorted { $0.time < $1.time }
            commentCount = comments.count
            timeline = FNOSDanmakuTimeline(items: fetched.map { comment in
                let kind: FNOSDanmakuLaneKind
                switch comment.mode {
                case 4: kind = .bottom
                case 5: kind = .top
                default: kind = .scroll
                }
                return FNOSDanmakuItem(time: comment.time, text: comment.text,
                                       kind: kind, rgb: comment.rgb)
            })
            nextIndex = 0
            active.removeAll()
            laneLastEntry = Array(repeating: -999, count: maxLanePool)
            anchorMediaTime = 0
            anchorWallTime = Date().timeIntervalSinceReferenceDate
            status = .ready
            print("FNOS✅弹幕: 匹配 episodeId=\(episodeID) 共 \(comments.count) 条")
        } catch {
            print("FNOS❗️弹幕加载失败: \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - 官方匹配（严格对齐 danmu_api / matchAnime）

    /// 构造 danmu_api 官方可解析的标准文件名。
    /// 官方 extractTitleSeasonEpisode 用 `^(.+?)[.\s]+S(\d+)E(\d+)` 解析季集，
    /// 年份用 `(?:\.|\()(19|20)\d{2}` 提取——所以文件名必须是这个形状。
    private static func canonicalFileName(
        title: String, season: Int? = nil, episode: Int? = nil, year: Int? = nil
    ) -> String {
        var name = title
        if let season, let episode {
            name += String(format: ".S%02dE%02d", season, episode)
        }
        if let year { name += ".\(year)" }
        return name + ".1080p.WEB-DL.mkv"
    }

    /// 剧集：一次标准文件名 match → 严格校验返回的剧名/集号；失败再用 search/episodes 精确定位。
    private func matchEpisodeID(
        seriesTitle: String, seasonNumber: Int, episodeNumber: Int,
        year: Int?, fallbackTitle: String
    ) async throws -> Int {
        let fileName = Self.canonicalFileName(
            title: seriesTitle, season: seasonNumber, episode: episodeNumber, year: year
        )
        print("FNOSℹ️弹幕: 官方 match「\(fileName)」")

        // ① 标准文件名直接 match（服务端已经做了剧名+季+集的精确匹配）
        if let hit = try? await matchViaMatchAPI(fileName: fileName),
           Self.isEpisodeConsistent(hit, seriesTitle: seriesTitle, episodeNumber: episodeNumber,
                                    seasonNumber: seasonNumber) {
            return hit.episodeId
        }

        // ② search/episodes：按官方 findEpisodeByNumber 优先级——
        //    集标题中提取的数字 > episodeNumber 字段 > 数组序号；同时校验剧名
        if let id = try? await searchEpisodeID(
            seriesTitle: seriesTitle, seasonNumber: seasonNumber,
            episodeNumber: episodeNumber, year: year
        ) {
            return id
        }

        // ③ 最后才退单集标题（可能是特别篇/电影式命名），仍走官方 match
        print("FNOS⚠️弹幕: 剧名+集号匹配失败，退回单集标题「\(fallbackTitle)」")
        return try await matchEpisodeID(title: fallbackTitle, year: year)
    }

    /// 电影/单集：标准文件名（带年份）→ match → search 兜底。
    private func matchEpisodeID(title: String, year: Int?) async throws -> Int {
        let fileName = Self.canonicalFileName(title: title, year: year)
        if let hit = try? await matchViaMatchAPI(fileName: fileName) {
            return hit.episodeId
        }
        if let id = try? await matchViaSearchAPI(title: title) {
            return id
        }
        throw FNOSDirectError("没有找到匹配的弹幕")
    }

    /// 校验 match 返回的剧集确实是请求的那部剧那一集（防错配核心）。
    private static func isEpisodeConsistent(
        _ ref: FNOSDanmuEpisodeRef, seriesTitle: String, episodeNumber: Int, seasonNumber: Int
    ) -> Bool {
        guard ref.episodeId > 0 else { return false }
        // 剧名：官方返回的 animeTitle 通常带年份/季后缀，做包含匹配即可
        if let anime = ref.animeTitle, !anime.isEmpty,
           !normalized(anime).contains(normalized(seriesTitle)),
           !normalized(seriesTitle).contains(normalized(anime)) {
            print("FNOS⚠️弹幕: 拒绝错配（剧名「\(anime)」≠「\(seriesTitle)」）")
            return false
        }
        // 集号：返回的 episodeTitle 若含数字，必须等于目标集；无数字则信任服务端精确匹配
        if let title = ref.episodeTitle, let extracted = episodeNumberIn(title), extracted != episodeNumber {
            print("FNOS⚠️弹幕: 拒绝错配（集标题「\(title)」= 第\(extracted)集 ≠ 第\(episodeNumber)集）")
            return false
        }
        if let epNum = ref.episodeNumber, epNum != episodeNumber { return false }
        return true
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }

    /// 从集标题提取数字（第N集 / 第N话 / EPN / SxxEyy / 纯数字）
    private static func episodeNumberIn(_ title: String) -> Int? {
        let patterns = ["第\\s*(\\d+)\\s*[集话]", "[EPep]\\s*(\\d+)", "S\\d+E(\\d+)", "#(\\d+)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: title),
                  let value = Int(title[range]) else { continue }
            return value
        }
        return nil
    }

    /// 按剧名搜索所有剧集，再用官方优先级选集（标题数字 > episodeNumber > 序号）。
    private func searchEpisodeID(
        seriesTitle: String, seasonNumber: Int, episodeNumber: Int, year: Int?
    ) async throws -> Int? {
        let encoded = seriesTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seriesTitle
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/search/episodes?anime=\(encoded)") else {
            throw FNOSDirectError("弹幕搜索 URL 非法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuSearchResult.self, from: data)

        // 优先挑剧名一致的 anime（官方 search 会返回多个同名/近似结果）
        let candidates = (decoded.animes ?? []).filter { anime in
            guard let title = anime.animeTitle else { return true }
            return Self.normalized(title).contains(Self.normalized(seriesTitle))
                || Self.normalized(seriesTitle).contains(Self.normalized(title))
        }
        let pool = candidates.isEmpty ? (decoded.animes ?? []) : candidates

        for anime in pool {
            guard let episodes = anime.episodes, !episodes.isEmpty else { continue }
            // 1) 集标题数字精确命中
            if let hit = episodes.first(where: {
                guard let t = $0.episodeTitle else { return false }
                return Self.episodeNumberIn(t) == episodeNumber
            }) {
                print("FNOS✅弹幕 search 命中(标题): \(hit.episodeTitle ?? "?")")
                return hit.episodeId
            }
            // 2) 结构化 episodeNumber 字段
            if let hit = episodes.first(where: { $0.episodeNumber == episodeNumber }) {
                print("FNOS✅弹幕 search 命中(字段): \(hit.episodeTitle ?? "?")")
                return hit.episodeId
            }
            // 3) 数组序号兜底（danmu_api 官方最后一级策略）
            if episodes.count >= episodeNumber {
                let hit = episodes[episodeNumber - 1]
                print("FNOS✅弹幕 search 命中(序号): \(hit.episodeTitle ?? "?")")
                return hit.episodeId
            }
        }
        return nil
    }

    private func matchViaMatchAPI(fileName: String) async throws -> FNOSDanmuEpisodeRef? {
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/match") else {
            throw FNOSDirectError("弹幕 match URL 非法")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fileName": fileName])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuMatchResult.self, from: data)

        if decoded.isMatched == true, let first = decoded.matches?.first {
            print("FNOSℹ️弹幕 match 命中: \(first.animeTitle ?? "?") / \(first.episodeTitle ?? "?")")
            return first
        }
        return nil
    }

    private func matchViaSearchAPI(title: String) async throws -> Int? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/search/episodes?anime=\(encoded)") else {
            throw FNOSDirectError("弹幕搜索 URL 非法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuSearchResult.self, from: data)

        guard let anime = decoded.animes?.first, let episode = anime.episodes?.first else {
            return nil
        }
        print("FNOSℹ️弹幕 search 命中: \(anime.animeTitle ?? "?") / \(episode.episodeTitle ?? "?")")
        return episode.episodeId
    }

    private func fetchComments(episodeID: Int) async throws -> [FNOSDanmuComment] {
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/comment/\(episodeID)?withRelated=true&chConvert=1") else {
            throw FNOSDirectError("弹幕评论 URL 非法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuCommentEnvelope.self, from: data)

        var result: [FNOSDanmuComment] = []
        var colorSamples: [UInt32] = []
        for raw in decoded.comments ?? [] {
            guard let text = raw.m, !text.isEmpty, let p = raw.p else { continue }
            let fields = p.split(separator: ",").map(String.init)
            guard let time = Double(fields.count > 0 ? fields[0] : "") else { continue }
            let mode = Int(fields.count > 1 ? fields[1] : "") ?? 1
            let colorValue = UInt32(fields.count > 2 ? fields[2] : "") ?? 0xFFFFFF
            colorSamples.append(colorValue)
            let color = Color(
                red: Double((colorValue >> 16) & 0xFF) / 255.0,
                green: Double((colorValue >> 8) & 0xFF) / 255.0,
                blue: Double(colorValue & 0xFF) / 255.0
            )
            result.append(FNOSDanmuComment(time: time, text: text, mode: mode,
                                           color: color, rgb: colorValue))
        }
        if !result.isEmpty {
            let whites = colorSamples.filter { $0 == 0xFFFFFF }.count
            let samples = colorSamples.prefix(5).map { String($0, radix: 16) }.joined(separator: "/")
            let opacityPct = Int((UserDefaults.standard.double(forKey: "fnos.danmu.opacity") * 100).rounded())
            FNOSDiagLog.send("弹幕诊断: 共\(result.count)条 白色\(whites)条 样本色[\(samples)] 不透明度\(opacityPct)%")
        }
        return result
    }

    // MARK: 播放器时钟绑定

    /// 倍速/暂停变化时重建锚点。
    /// v217：传入播放器真实时间（KS 的 timemodel / MPV 的 position）作为新锚点，
    /// 消除旧版「用旧倍速外推值重建锚点」造成的切速瞬间弹幕错位。
    /// 不传时保留旧行为（外推），兼容既有调用点。
    func setRate(_ rate: Double, realTime: Double? = nil) {
        let now = Date().timeIntervalSinceReferenceDate
        if let realTime {
            anchorMediaTime = realTime
        } else {
            anchorMediaTime = anchorMediaTime + (now - anchorWallTime) * anchorRate
        }
        anchorWallTime = now
        anchorRate = rate
    }

    /// 播放器周期回调：校准锚点、激活新弹幕、驱逐过期弹幕。
    /// 🚨 sync 铁律：anchorMediaTime = mediaTime 精确等于播放器时间，严禁改动。
    func sync(mediaTime: Double) {
        let wallNow = Date().timeIntervalSinceReferenceDate
        let extrapolated = anchorMediaTime + (wallNow - anchorWallTime) * anchorRate

        if abs(extrapolated - mediaTime) > 1.0 {
            // 拖动进度条：硬跳变 → 清屏并把指针对齐到新时间
            print("FNOSℹ️弹幕: 进度跳变 \(String(format: "%.1f", extrapolated)) → \(String(format: "%.1f", mediaTime))，清屏重对齐")
            reset()
            while nextIndex < comments.count, comments[nextIndex].time < mediaTime - 0.05 {
                nextIndex += 1
            }
        }

        anchorMediaTime = mediaTime
        anchorWallTime = wallNow

        while nextIndex < comments.count, comments[nextIndex].time <= mediaTime {
            let comment = comments[nextIndex]
            nextIndex += 1
            activate(comment, at: mediaTime)
        }
        active.removeAll { mediaTime - $0.comment.time > travelDuration }
        lastSyncMediaTime = mediaTime
    }

    /// 供渲染层按墙钟外推当前媒体时间（绝不依赖系统时间做内容位置）
    func mediaTime(at date: Date) -> Double {
        anchorMediaTime + (date.timeIntervalSinceReferenceDate - anchorWallTime) * anchorRate
    }

    private func reset() {
        active.removeAll()
        nextIndex = 0
        laneLastEntry = Array(repeating: -999, count: maxLanePool)
    }

    private func laneCount() -> Int {
        let stored = UserDefaults.standard.double(forKey: "fnos.danmu.area")
        let area = stored > 0.05 ? min(max(stored, 0.2), 1.0) : 0.3
        let storedFS = UserDefaults.standard.double(forKey: "fnos.danmu.fontSize")
        let laneH = (storedFS > 8 ? storedFS : 26) * 1.4
        let cap = min(1080.0 * area, 1080.0 - 260.0)
        return max(1, min(maxLanePool, Int((cap - 110.0) / laneH)))
    }

    private func activate(_ comment: FNOSDanmuComment, at mediaTime: Double) {
        if comment.mode == 4 || comment.mode == 5 {
            if comment.mode == 4, UserDefaults.standard.bool(forKey: "fnos.danmu.hideBottom") {
                return
            }
            let occupied = active.contains {
                $0.comment.mode == comment.mode && (mediaTime - $0.comment.time) < fixedDuration
            }
            if occupied { return }
            active.append(ActiveComment(comment: comment, lane: -1, seq: nextSeq))
            nextSeq += 1
            return
        }
        for lane in 0..<laneCount() {
            if mediaTime - laneLastEntry[lane] >= laneGap {
                laneLastEntry[lane] = mediaTime
                active.append(ActiveComment(comment: comment, lane: lane, seq: nextSeq))
                nextSeq += 1
                return
            }
        }
    }

    // MARK: 工具

    private static func assertOK(_ response: URLResponse, url: URL, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FNOSDirectError("弹幕非 HTTP 响应: \(url.absoluteString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw FNOSDirectError("弹幕 HTTP \(http.statusCode): \(url.path) → \(raw)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️弹幕 JSON 解析失败: \(error) 原文: \(raw)")
            throw FNOSDirectError("弹幕 JSON 解析失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 弹幕渲染层（图层引擎 + 设置面板 API 全接线）

struct FNOSDanmuView: View {

    @ObservedObject var engine: FNOSDanmuEngine

    // 与 FNOSDanmuSettingsSheet 完全同一组 @AppStorage key —— 面板调节即时生效
    @AppStorage("fnos.danmu.fontSize") private var fontSize: Double = 26
    @AppStorage("fnos.danmu.opacity") private var opacity: Double = 1
    @AppStorage("fnos.danmu.speed") private var speed: Double = 1
    @AppStorage("fnos.danmu.offsetY") private var offsetY: Double = 0
    @AppStorage("fnos.danmu.area") private var area: Double = 0.3
    @AppStorage("fnos.danmu.hideBottom") private var hideBottom = false

    private var style: FNOSDanmakuStyle {
        var s = FNOSDanmakuStyle()
        s.fontSize = CGFloat(fontSize)
        s.opacity = Float(min(max(opacity, 0.2), 1.0))
        // 速度面板用倍率 0.5~2.5：倍率越大横穿越快 = 耗时越短
        s.scrollDuration = 12 / min(max(speed, 0.1), 10)
        s.areaRatio = CGFloat(area > 0.05 ? min(max(area, 0.2), 1.0) : 0.3)
        s.offsetY = CGFloat(offsetY)
        s.hideBottom = hideBottom
        return s
    }

    var body: some View {
        FNOSDanmakuOverlay(
            clock: FNOSDanmuRenderClock(engine: engine),
            timeline: engine.timeline,
            style: style,
            isVisible: true
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
