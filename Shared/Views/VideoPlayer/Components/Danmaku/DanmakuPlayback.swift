//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

// MARK: - 时钟（非隔离）

/// 弹幕播放时钟：DanmakuEngine 的 displayLink 在主线程每帧调用 `danmakuTime`，
/// 而 MediaSession 是 MainActor 隔离的 —— 因此这里用「锚点 + 单调外推」：
/// 主线程每次 MediaSession 时间更新时同步锚点，每帧读取时按流逝时间外推。
/// 暂停时冻结在锚点位置。
final class DanmakuPlaybackClock: DanmakuClock, @unchecked Sendable {

    private let lock = NSLock()
    private var anchorSeconds: TimeInterval = 0
    private var anchorDate: Date = .now
    private var rate: Double = 1
    private var isRunning = true

    /// 仅在主线程调用（MediaSession 时间更新时）
    func update(seconds: TimeInterval, rate: Double, isPaused: Bool) {
        lock.lock()
        defer { lock.unlock() }

        anchorSeconds = seconds
        anchorDate = .now
        self.rate = rate
        isRunning = !isPaused
    }

    /// 每帧调用（主线程，displayLink tick）。
    /// 本类非 actor 隔离，天然满足 `DanmakuClock` 的非隔离要求。
    var danmakuTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return anchorSeconds }

        let elapsed = Date.now.timeIntervalSince(anchorDate)
        return anchorSeconds + elapsed * rate
    }
}

// MARK: - 播放器弹幕模型

/// 播放器内的弹幕会话：匹配、加载、开关与样式。
/// 由 `VideoPlayer.ViewState` 持有（`connect(mediaSession:)` 时挂接）。
@MainActor
@Observable
final class DanmakuModel {

    // MARK: 可观察状态

    private(set) var timeline: DanmakuTimeline?
    private(set) var statusText: String?

    var isVisible: Bool {
        didSet { Defaults[.VideoPlayer.Danmaku.isVisible] = isVisible }
    }

    var style: DanmakuStyle {
        didSet { persistStyle() }
    }

    // MARK: 时钟

    let clock = DanmakuPlaybackClock()

    // MARK: 内部状态

    @ObservationIgnored
    private weak var mediaSession: MediaSession?
    @ObservationIgnored
    private var loadedItemID: String?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var isClockObserving = false

    init() {
        isVisible = Defaults[.VideoPlayer.Danmaku.isVisible]

        style = DanmakuStyle(
            fontSize: CGFloat(Defaults[.VideoPlayer.Danmaku.fontSize]),
            scrollDuration: Defaults[.VideoPlayer.Danmaku.scrollDuration],
            opacity: Float(Defaults[.VideoPlayer.Danmaku.opacity])
        )
    }

    // MARK: 挂接（ViewState.connect 时调用）

    func attach(mediaSession: MediaSession) {
        self.mediaSession = mediaSession

        if isClockObserving {
            syncClock()
        } else {
            isClockObserving = true
            syncClock()
            observeClock()
        }
    }

    // MARK: 加载（换集时调用）

    func loadIfNeeded(for item: MediaPlayerItem?) {
        guard let item else { return }

        let itemID = item.baseItem.id ?? item.baseItem.name ?? UUID().uuidString
        guard itemID != loadedItemID else { return }
        loadedItemID = itemID

        loadTask?.cancel()
        timeline = nil

        guard let service = makeService(for: item) else {
            statusText = "未配置弹幕服务地址（设置 → 弹幕服务）"
            return
        }

        let base = item.baseItem
        let fileName = base.path.map { ($0 as NSString).lastPathComponent }
            ?? [base.seriesName ?? base.name, episodeLabel(for: base)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        let title = base.seriesName ?? base.name
        let seasonNumber = base.parentIndexNumber
        let episodeNumber = base.indexNumber

        statusText = "弹幕匹配中…"

        loadTask = Task { [weak self] in
            do {
                let timeline = try await service.fetchTimeline(
                    fileName: fileName,
                    title: title,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )

                guard !Task.isCancelled else { return }
                self?.timeline = timeline
                self?.statusText = "已加载 \(timeline.items.count) 条弹幕（\(timeline.source)）"
            } catch {
                guard !Task.isCancelled else { return }
                self?.timeline = nil
                self?.statusText = "弹幕：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 服务

    private func makeService(for item: MediaPlayerItem) -> DanmuAPIService? {
        let configuredURL = Defaults[.VideoPlayer.Danmaku.serviceURL]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = Defaults[.VideoPlayer.Danmaku.apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseURL: URL?
        if let configuredURL, !configuredURL.isEmpty {
            baseURL = URL(string: configuredURL)
        } else if let host = mediaSession?.userSession.server.effectiveServerURL.host {
            // 默认与媒体服务器同主机，端口 9321（danmu_api 默认）
            baseURL = URL(string: "http://\(host):9321")
        } else {
            baseURL = nil
        }

        guard let baseURL else { return nil }
        return DanmuAPIService(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    private func episodeLabel(for base: BaseItemDto) -> String {
        switch (base.parentIndexNumber, base.indexNumber) {
        case let (season?, episode?):
            return "S\(season)E\(episode)"
        case let (nil, episode?):
            return "第\(episode)集"
        default:
            return ""
        }
    }

    // MARK: 时钟同步（主线程）

    private func observeClock() {
        withObservationTracking { [weak self] in
            guard let mediaSession = self?.mediaSession else { return }
            _ = mediaSession.seconds
            _ = mediaSession.playbackState
            _ = mediaSession.rate
        } onChange: { [weak self] in
            // @Observable 的 onChange 在属性变更线程同步回调；
            // MediaSession 是 MainActor 隔离，变更必然发生在主线程。
            MainActor.assumeIsolated {
                guard let self, self.mediaSession != nil else { return }

                self.syncClock()
                self.observeClock()
            }
        }
    }

    private func syncClock() {
        guard let mediaSession else { return }

        let seconds = mediaSession.seconds
        let interval = TimeInterval(seconds.components.seconds)
            + Double(seconds.components.attoseconds) * 1e-18

        clock.update(
            seconds: interval,
            rate: mediaSession.effectiveRate,
            isPaused: !mediaSession.playbackState.isPlaying
        )
    }

    // MARK: 持久化

    private func persistStyle() {
        Defaults[.VideoPlayer.Danmaku.fontSize] = Double(style.fontSize)
        Defaults[.VideoPlayer.Danmaku.scrollDuration] = Double(style.scrollDuration)
        Defaults[.VideoPlayer.Danmaku.opacity] = Double(style.opacity)
    }
}

// MARK: - 弹幕设置面板（播放器 Supplement）

struct DanmakuSettingsSupplement: VideoPlayerSupplement {

    let id = "DanmakuSettings"
    let displayTitle = "弹幕设置"

    @Bindable
    var model: DanmakuModel

    @Default(.VideoPlayer.Danmaku.serviceURL)
    private var serviceURL

    @Default(.VideoPlayer.Danmaku.apiKey)
    private var apiKey

    var body: some View {
        VStack(spacing: 16) {
            if let statusText = model.statusText {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            DanmakuControlPanel(
                isVisible: $model.isVisible,
                style: $model.style
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("弹幕服务（danmu_api）")
                    .font(.headline)

                TextField("留空 = 媒体服务器同主机 :9321", text: $serviceURL)
                    .font(.callout)

                TextField("API Key（部署时设置的 KEY）", text: $apiKey)
                    .font(.callout)

                Text("修改后从下一集开始生效；当前集可换集重进刷新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
        }
        .padding()
    }
}
