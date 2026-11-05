//
// FNOSPipedPlayer.swift
// v123: Piped API 拉流播放 YouTube 视频（预告片/花絮）
// 通道：api.piped.private.coffee（主）→ 备用实例轮询 → 返回 LBRY HLS / MP4 给 AVPlayer
//

import AVFoundation
import SwiftUI

/// Piped 实例（按可用性排序，实测 private.coffee 可用）
private let pipedInstances = [
    "https://api.piped.private.coffee",
    "https://pipedapi.drgns.space",
    "https://pipedapi.kavin.rocks",
]

/// Piped 视频流结果
struct FNOSPipedStream {
    let title: String
    let duration: Int       // 秒
    let hlsURL: URL?        // LBRY HLS 自适应流（AVPlayer 可播）
    let mp4URL: URL?        // 渐进式 MP4 兜底
    let thumbnailURL: URL?

    /// 优先 HLS，退 MP4
    var bestURL: URL? { hlsURL ?? mp4URL }
}

/// Piped 拉流客户端
enum FNOSPipedClient {

    /// 拉 YouTube 视频流信息（多实例轮询，全挂返回 nil）
    static func stream(for videoKey: String) async -> FNOSPipedStream? {
        for base in pipedInstances {
            guard let url = URL(string: "\(base)/streams/\(videoKey)") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let title = json["title"] as? String ?? ""
                let duration = json["duration"] as? Int ?? 0
                let thumb = json["thumbnailUrl"] as? String

                // 遍历 videoStreams，找 HLS（application/x-mpegurl）和渐进 MP4
                var hls: URL?
                var mp4: URL?
                if let streams = json["videoStreams"] as? [[String: Any]] {
                    for s in streams {
                        guard let u = s["url"] as? String, let streamURL = URL(string: u) else { continue }
                        let mime = s["mimeType"] as? String ?? ""
                        let format = s["format"] as? String ?? ""
                        // LBRY HLS（.m3u8）优先
                        if mime.contains("mpegurl") || format.contains("HLS") || u.hasSuffix(".m3u8") {
                            if hls == nil { hls = streamURL }
                        } else if mime.contains("mp4"), hls == nil || mp4 == nil {
                            // 渐进 MP4 兜底（优先非 LBRY 的标清 itag=18，但 LBRY MP4 也行）
                            if mp4 == nil { mp4 = streamURL }
                        }
                    }
                }

                // 顶层 hls/dash 字段（有时有）
                if hls == nil, let h = json["hls"] as? String, !h.isEmpty { hls = URL(string: h) }
                if mp4 == nil, let d = json["dash"] as? String, !d.isEmpty { mp4 = URL(string: d) }

                let thumbURL = thumb.flatMap { URL(string: $0) }
                let stream = FNOSPipedStream(
                    title: title, duration: duration,
                    hlsURL: hls, mp4URL: mp4, thumbnailURL: thumbURL
                )
                // 有任一可播 URL 即成功
                if stream.bestURL != nil { return stream }
            } catch {
                print("FNOS⚠️Piped 实例失败 \(base): \(error.localizedDescription)")
                continue
            }
        }
        return nil
    }
}

/// Piped 拉流播放器（AVPlayer 全屏，预告片/花絮用）
struct FNOSPipedPlayerView: View {
    let videoKey: String
    let title: String
    let onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                FNOSPreviewPlayerView(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text("加载视频流…")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.8))
                }
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.6))
                    Text(errorMessage)
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Text("按菜单键返回")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(40)
            }

            // 顶部返回按钮 + 标题
            VStack {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.card)
                    Spacer()
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.horizontal, 40)
                .padding(.top, 30)
                Spacer()
            }
        }
        .onExitCommand { onDismiss() }
        .task { await loadAndPlay() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadAndPlay() async {
        guard player == nil else { return }
        let stream = await FNOSPipedClient.stream(for: videoKey)
        guard let stream, let playURL = stream.bestURL else {
            isLoading = false
            errorMessage = "视频流加载失败\n（Piped 实例不可用或网络受限）"
            return
        }
        let item = AVPlayerItem(url: playURL)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        isLoading = false
        avPlayer.play()
        print("FNOS▶️Piped 播放: \(stream.title) hls=\(stream.hlsURL != nil) mp4=\(stream.mp4URL != nil)")
    }
}
