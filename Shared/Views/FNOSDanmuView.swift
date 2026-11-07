//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
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
    /// 1=滚动 4=底部 5=顶部（dandanplay 约定）
    let mode: Int
    let color: Color
}

// MARK: - 服务端 JSON（dandanplay 兼容 API，已实测响应形状）

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
    let animeTitle: String?
    let episodeTitle: String?
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

// MARK: - 弹幕引擎（时钟绑定 AVPlayer，5 轨道防重叠）

@MainActor
final class FNOSDanmuEngine: ObservableObject {

    /// 用户自建弹幕服务（含 Key）
    static let defaultBaseURL = "http://192.168.10.120:9321/199780jjj"

    private let laneCount = 5
    /// 滚动弹幕全程耗时上限（秒）——按最慢速度 0.5x 估算，快速时绘制端会跳过出屏弹幕
    private let travelDuration: Double = 30
    /// 同轨道两次弹幕的最小间隔（秒）——防重叠核心
    private let laneGap: Double = 3.5
    /// 底部/顶部固定弹幕停留时间（秒）
    private let fixedDuration: Double = 5

    struct ActiveComment: Identifiable {
        let comment: FNOSDanmuComment
        /// 滚动弹幕所在轨道（0..4），固定弹幕为 -1
        let lane: Int
        /// 唯一序号（渲染层 ForEach 稳定身份，纯递增不参与时间逻辑）
        let seq: Int
        var id: Int { seq }
    }

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private var comments: [FNOSDanmuComment] = []
    private var nextIndex = 0
    private var laneLastEntry: [Double]
    /// 激活弹幕唯一序号（渲染层 ForEach 身份用，纯递增）
    private var nextSeq = 0
    /// 正在画面上的弹幕（Canvas 每帧读取）
    private(set) var active: [ActiveComment] = []
    /// 上一次同步到的媒体时间
    private var lastSyncMediaTime: Double = 0

    /// 同步锚点：媒体时间 ↔ 墙钟时间 ↔ 倍速
    private var anchorMediaTime: Double = 0
    private var anchorWallTime: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var anchorRate: Double = 1

    @Published var status: Status = .idle
    @Published var commentCount = 0

    init() {
        laneLastEntry = Array(repeating: -999, count: laneCount)
    }

    // MARK: 服务端加载

    func load(title: String, seriesTitle: String? = nil, episodeNumber: Int? = nil) async {
        status = .loading

        do {
            let episodeID: Int
            if let seriesTitle, !seriesTitle.isEmpty, let episodeNumber {
                // 剧集：剧名 + 集数匹配（单集标题在弹幕库里几乎不存在）
                print("FNOSℹ️弹幕: 剧集匹配「\(seriesTitle)」第 \(episodeNumber) 集")
                episodeID = try await matchEpisodeID(
                    seriesTitle: seriesTitle,
                    episodeNumber: episodeNumber,
                    fallbackTitle: title
                )
            } else {
                print("FNOSℹ️弹幕: 开始匹配「\(title)」")
                episodeID = try await matchEpisodeID(title: title)
            }
            let fetched = try await fetchComments(episodeID: episodeID)

            comments = fetched.sorted { $0.time < $1.time }
            commentCount = comments.count
            nextIndex = 0
            active.removeAll()
            laneLastEntry = Array(repeating: -999, count: laneCount)
            anchorMediaTime = 0
            anchorWallTime = Date().timeIntervalSinceReferenceDate
            status = .ready
            print("FNOS✅弹幕: 共 \(comments.count) 条")
        } catch {
            print("FNOS❗️弹幕加载失败: \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    /// 剧集匹配：match 接口按「剧名+集数」多命名尝试 → search 按集号挑选 → 退单集标题
    private func matchEpisodeID(seriesTitle: String, episodeNumber: Int, fallbackTitle: String) async throws -> Int {
        let padded = String(format: "%02d", episodeNumber)
        let candidates = [
            "\(seriesTitle) 第\(episodeNumber)集",
            "\(seriesTitle) S01E\(padded)",
            "\(seriesTitle) EP\(episodeNumber)",
            "\(seriesTitle) \(padded)",
        ]
        for candidate in candidates {
            if let id = try? await matchViaMatchAPI(title: candidate) {
                return id
            }
        }

        if let id = try await searchEpisodeID(seriesTitle: seriesTitle, episodeNumber: episodeNumber) {
            return id
        }

        print("FNOS⚠️弹幕: 剧名匹配全失败，退回单集标题「\(fallbackTitle)」")
        return try await matchEpisodeID(title: fallbackTitle)
    }

    /// 按剧名搜索，再从结果里按集号挑（匹配"第N集/第N话/EPn/E0n"，失败按序号取第 n 条）
    private func searchEpisodeID(seriesTitle: String, episodeNumber: Int) async throws -> Int? {
        let encoded = seriesTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seriesTitle
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/search/episodes?anime=\(encoded)") else {
            throw FNOSDirectError("弹幕搜索 URL 非法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuSearchResult.self, from: data)

        guard let anime = decoded.animes?.first, let episodes = anime.episodes, !episodes.isEmpty else {
            return nil
        }
        print("FNOSℹ️弹幕 search「\(seriesTitle)」候选 \(episodes.count) 集")

        // 1) 标题里含集号
        let markers = ["第\(episodeNumber)集", "第\(episodeNumber)话", "EP\(episodeNumber)", "E\(episodeNumber)", String(format: "%02d", episodeNumber)]
        if let hit = episodes.first(where: { ref in
            guard let t = ref.episodeTitle else { return false }
            return markers.contains { t.localizedCaseInsensitiveContains($0) }
        }) {
            print("FNOS✅弹幕 search 命中(标题): \(hit.episodeTitle ?? "?")")
            return hit.episodeId
        }

        // 2) 标题不含集号时按序号取第 n 条（弹幕库一般按集顺序返回）
        if episodes.count >= episodeNumber {
            let ref = episodes[episodeNumber - 1]
            print("FNOS✅弹幕 search 命中(序号): \(ref.episodeTitle ?? "?")")
            return ref.episodeId
        }
        return nil
    }

    /// 优先精确 match，失败退回 search
    private func matchEpisodeID(title: String) async throws -> Int {
        if let id = try await matchViaMatchAPI(title: title) {
            return id
        }
        if let id = try await matchViaSearchAPI(title: title) {
            return id
        }
        throw FNOSDirectError("没有找到匹配的弹幕")
    }

    private func matchViaMatchAPI(title: String) async throws -> Int? {
        guard let url = URL(string: "\(Self.defaultBaseURL)/api/v2/match") else {
            throw FNOSDirectError("弹幕 match URL 非法")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fileName": title])
        } catch {
            print("FNOS❗️弹幕 match 请求体编码失败: \(error)")
            throw error
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, url: url, data: data)
        let decoded = try Self.decode(FNOSDanmuMatchResult.self, from: data)

        if decoded.isMatched == true, let first = decoded.matches?.first {
            print("FNOSℹ️弹幕 match 命中: \(first.animeTitle ?? "?") / \(first.episodeTitle ?? "?")")
            return first.episodeId
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
        for raw in decoded.comments ?? [] {
            guard let text = raw.m, !text.isEmpty, let p = raw.p else { continue }
            let fields = p.split(separator: ",").map(String.init)
            guard let time = Double(fields.count > 0 ? fields[0] : "") else { continue }
            let mode = Int(fields.count > 1 ? fields[1] : "") ?? 1
            let colorValue = UInt32(fields.count > 2 ? fields[2] : "") ?? 0xFFFFFF
            let color = Color(
                red: Double((colorValue >> 16) & 0xFF) / 255.0,
                green: Double((colorValue >> 8) & 0xFF) / 255.0,
                blue: Double(colorValue & 0xFF) / 255.0
            )
            result.append(FNOSDanmuComment(time: time, text: text, mode: mode, color: color))
        }
        return result
    }

    // MARK: 播放器时钟绑定

    /// 倍速/暂停变化时重建锚点（暂停 → rate 0，外推冻结）
    func setRate(_ rate: Double) {
        anchorMediaTime = mediaTime(at: Date())
        anchorWallTime = Date().timeIntervalSinceReferenceDate
        anchorRate = rate
    }

    /// 播放器周期回调（0.25 秒）：校准锚点、激活新弹幕、驱逐过期弹幕
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

        // 激活到达时间的弹幕
        while nextIndex < comments.count, comments[nextIndex].time <= mediaTime {
            let comment = comments[nextIndex]
            nextIndex += 1
            activate(comment, at: mediaTime)
        }

        // 驱逐已滚出画面的滚动弹幕
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
        laneLastEntry = Array(repeating: -999, count: laneCount)
    }

    // MARK: 5 轨道防重叠分配

    private func activate(_ comment: FNOSDanmuComment, at mediaTime: Double) {
        if comment.mode == 4 || comment.mode == 5 {
            // 底部/顶部固定弹幕：同区同屏最多 1 条
            let occupied = active.contains {
                $0.comment.mode == comment.mode && (mediaTime - $0.comment.time) < fixedDuration
            }
            if occupied {
                print("FNOSℹ️弹幕: 丢弃重叠固定弹幕「\(comment.text)」")
                return
            }
            active.append(ActiveComment(comment: comment, lane: -1, seq: nextSeq))
            nextSeq += 1
            return
        }

        // 滚动弹幕：找一条「上一条已经走远」的轨道
        for lane in 0..<laneCount {
            if mediaTime - laneLastEntry[lane] >= laneGap {
                laneLastEntry[lane] = mediaTime
                active.append(ActiveComment(comment: comment, lane: lane, seq: nextSeq))
                nextSeq += 1
                return
            }
        }
        print("FNOSℹ️弹幕: 轨道已满，丢弃「\(comment.text)」")
    }

    // MARK: 工具（全 do-catch，打印真实报错）

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

// MARK: - 弹幕渲染（Canvas + TimelineView，60fps，不吃焦点）

struct FNOSDanmuView: View {

    @ObservedObject var engine: FNOSDanmuEngine

    @AppStorage("fnos.danmu.fontSize") private var fontSize: Double = 26
    @AppStorage("fnos.danmu.opacity") private var opacity: Double = 1
    @AppStorage("fnos.danmu.speed") private var speed: Double = 1
    @AppStorage("fnos.danmu.offsetY") private var offsetY: Double = 0
    private var laneHeight: CGFloat { CGFloat(fontSize) * 1.4 }
    /// 顶部基准线（垂直位置偏移会叠加在这里）
    private var laneTopInset: CGFloat { 110 + CGFloat(offsetY) }

    var body: some View {
        // v173: 弃 Canvas 每帧全量重绘（闪烁根因），改原生 Text.position ——
        // 每条弹幕一个视图，SwiftUI 只做 transform 合成，滚动期间文本零重绘。
        // 引擎（时间轴/锚点/轨道）零改动，仅渲染层换皮。
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let mediaNow = engine.mediaTime(at: timeline.date)
                ForEach(engine.active) { entry in
                    if let center = screenPosition(for: entry, mediaNow: mediaNow, size: geo.size) {
                        Text(entry.comment.text)
                            .font(.system(size: CGFloat(fontSize), weight: .medium))
                            .foregroundColor(entry.comment.color)
                            .opacity(opacity)
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: center.x, y: center.y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 计算单条弹幕当前屏幕位置（纯几何，与旧 Canvas 版逐行对应）
    private func screenPosition(for entry: ActiveComment, mediaNow: Double, size: CGSize) -> CGPoint? {
        let comment = entry.comment

        if comment.mode == 4 || comment.mode == 5 {
            // 底部 / 顶部固定弹幕
            let elapsed = mediaNow - comment.time
            guard elapsed >= 0, elapsed <= 5 else { return nil }
            let rawY = comment.mode == 4
                ? size.height - 80 + CGFloat(offsetY)
                : laneTopInset
            let y = min(max(rawY, 60), size.height - 60)
            return CGPoint(x: size.width / 2, y: y)
        }

        // 滚动弹幕：右侧进入、匀速向左（speed 为用户设置倍率）
        let textWidth = estimatedWidth(of: comment.text)
        let velocity = (size.width + textWidth) / (12 / max(speed, 0.1))
        let distance = CGFloat(mediaNow - comment.time) * velocity
        let trailingX = size.width - distance
        let centerX = trailingX + textWidth / 2

        guard centerX + textWidth / 2 > 0 else { return nil }
        guard centerX - textWidth / 2 < size.width else { return nil }

        let y = laneTopInset + CGFloat(entry.lane) * laneHeight
        return CGPoint(x: centerX, y: y)
    }

    /// CJK 全角估算：每字符 ≈ 1.0 倍字号
    private func estimatedWidth(of text: String) -> CGFloat {
        CGFloat(text.count) * CGFloat(fontSize)
    }
}
