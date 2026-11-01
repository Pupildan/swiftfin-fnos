//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import KSPlayer
import SwiftUI

/// AVURLAsset 请求头 Key（ObjC 常量未暴露给 Swift，按官方字符串手动声明）
private let fnosAVHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

// MARK: - 播放源扩展（只读 FNOSDirectClient 公开属性，不修改网络层文件）

extension FNOSDirectClient {

    /// 条目播放源（fnOS 硬性要求：stream 的 MediaSourceId 必须传真实值，空值一律 400）
    func playbackSource(itemID: String, userID: String) async throws -> (mediaSourceID: String, container: String?) {
        let data = try await get(path: "Users/\(userID)/Items/\(itemID)")

        struct Detail: Decodable {
            let MediaSources: [FNOSMediaSource]?
        }
        struct FNOSMediaSource: Decodable {
            let Id: String
            let Container: String?
            let Path: String?
        }

        let detail: Detail
        do {
            detail = try JSONDecoder().decode(Detail.self, from: data)
        } catch {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "(非文本)"
            print("FNOS❗️解析条目详情失败: \(error) 原文: \(raw)")
            throw FNOSDirectError("解析条目详情失败: \(error.localizedDescription)")
        }

        guard let source = detail.MediaSources?.first, !source.Id.isEmpty else {
            throw FNOSDirectError("条目缺少 MediaSources，无法取播放源")
        }
        return (source.Id, source.Container ?? source.Path)
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

// MARK: - 播放容器（KSPlayerView + 引擎分流 + 弹幕）

struct FNOSPlayerContainerView: View {

    let item: FNOSItem
    let client: FNOSDirectClient
    let userID: String

    @Environment(\.dismiss)
    private var dismiss

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var danmuEngine = FNOSDanmuEngine()

    @State private var showDanmu = true
    @State private var streamURL: URL?
    @State private var containerInfo: String?
    @State private var notice = "准备播放…"
    @State private var didSetup = false

    var body: some View {
        ZStack(alignment: .top) {
            if let streamURL {
                // 必须显式传入自建 coordinator：
                // KSVideoPlayerView(url:...) 便捷构造器会内部 new 一个 Coordinator，
                // 外部 @StateObject 永远收不到 onPlay/onStateChanged（弹幕失联的直接原因）
                KSVideoPlayerView(
                    coordinator: coordinator,
                    url: streamURL,
                    options: makeOptions(),
                    title: item.Name ?? "播放"
                )
                .ignoresSafeArea()
                // 覆盖 KSPlayer tvOS 控制条按钮的默认白胶囊样式（重点修复莫名白色圆点）
                .buttonStyle(.plain)
                .tint(.white)
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
            }

            // Liquid Glass 悬浮顶栏
            topBar
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await prepare()
        }
        .onDisappear {
            danmuEngine.setRate(0)
        }
    }

    // MARK: 顶栏（返回 + 片名 + 弹幕开关）

    private var topBar: some View {
        HStack(spacing: 20) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .padding(12)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name ?? "播放")
                    .font(.headline)
                    .lineLimit(1)
                if !notice.isEmpty {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                showDanmu.toggle()
            } label: {
                Label(
                    showDanmu ? "弹幕 开" : "弹幕 关",
                    systemImage: showDanmu ? "text.bubble" : "text.bubble.slash"
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(18)
        .padding(.horizontal, 48)
        .padding(.top, 20)
    }

    // MARK: 准备（真实 MediaSourceId → 直链 → 弹幕）

    private func prepare() async {
        guard !didSetup else { return }
        didSetup = true

        // 弹幕时钟绑定 KSPlayer：时间回调 + 状态回调（暂停冻结外推），绝不用系统时间
        coordinator.onPlay = { currentTime, _ in
            danmuEngine.sync(mediaTime: currentTime)
        }
        coordinator.onStateChanged = { _, state in
            switch state {
            case .paused, .playedToTheEnd, .error:
                danmuEngine.setRate(0)
            default:
                danmuEngine.setRate(1)
            }
        }

        // 1) 取真实 MediaSourceId（此前播放失败的直接原因之一：空值被 fnOS 400 拒绝）
        let source: (mediaSourceID: String, container: String?)
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
        notice = ""

        // 3) 弹幕（真实服务端，按标题匹配）
        danmuEngine.setRate(1)
        let title = item.Name ?? "视频"
        notice = "弹幕匹配中…"
        await danmuEngine.load(title: title)
        switch danmuEngine.status {
        case .ready:
            notice = "弹幕 \(danmuEngine.commentCount) 条"
        case .failed(let message):
            notice = "弹幕失败: \(message)"
        default:
            notice = ""
        }
    }

    // MARK: 引擎分流（.mkv → FFmpeg；.mp4/.m3u8 → AVPlayer）

    private func makeOptions() -> KSOptions {
        let container = (containerInfo ?? "").lowercased()
        let isMKV = container.contains("matroska") || container.contains("mkv")

        KSOptions.firstPlayerType = isMKV ? KSMEPlayer.self : KSAVPlayer.self
        print("FNOSℹ️播放引擎: \(isMKV ? "FFmpeg (KSMEPlayer)" : "AVPlayer (KSAVPlayer)") · 容器: \(container.isEmpty ? "未知" : container)")

        let options = KSOptions()

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
