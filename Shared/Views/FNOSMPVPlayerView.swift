import Foundation
import MPVUI
import SwiftUI

// MARK: - MPV 引擎播放页（实验）
//
// 为什么需要它：KSPlayer 免费版不解 DoVi 的 IPTPQc2 色彩空间，P5 片源必然紫绿。
// MPVUI 的 gpu-next（libplacebo）能做 DoVi → BT.709/HDR10 的 reshape + tonemap，
// PC 端已用同一套 libplacebo 管线实测：同一份字节能出正确颜色。
//
// 关键配置（缺一不可）：
// - `videoOutput: .metal`：默认值是 `.sampleBuffer`，那条路是 AVFoundation 自己转色彩，
//   会绕过 gpu-next 的着色器与 tone mapping，换了 mpv 也照样偏色。
// - `additionalOptions["http-header-fields"]`：原生 media/range 只需要 Authorization 头，
//   值里没有逗号（mpv 这个选项是按逗号切分的多值，含逗号的 X-Emby-Authorization 会切坏）。
//
// 本页是「引擎验证页」：只有画面 + 进度 + 播放/暂停 + 快退快进，弹幕/换集条暂不接入。

@MainActor
struct FNOSMPVPlayerView: View {

    let url: URL
    let title: String
    let authToken: String
    var onExit: () -> Void

    @State private var player: MPVPlayer?
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                MPVVideoPlayer(player: player)
                    .ignoresSafeArea()

                overlay(player)
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在启动 mpv…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear { player?.stop() }
        .onExitCommand { onExit() }
        .onPlayPauseCommand { togglePlayPause() }
        .onMoveCommand { direction in seek(direction) }
        .focusable()
    }

    // MARK: - 控件层

    private func overlay(_ player: MPVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text("MPV 引擎（实验）· \(rangeBadge(player))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if player.isPaused {
                    Text("已暂停")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)

            Spacer()

            VStack(spacing: 10) {
                progressBar(player)
                HStack {
                    Text(timeText(seconds(player.position)))
                    Spacer()
                    Text(timeText(seconds(player.duration)))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 56)
        }
    }

    private func progressBar(_ player: MPVPlayer) -> some View {
        let total = max(seconds(player.duration), 1)
        let fraction = min(max(seconds(player.position) / total, 0), 1)

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    // MARK: - 行为

    private func startIfNeeded() {
        guard !started else { return }
        started = true

        let configuration = MPVPlayerConfiguration(
            additionalOptions: ["http-header-fields": "Authorization: \(authToken)"],
            autoPlay: true,
            logLevel: .warning,
            videoOutput: .metal
        )

        let player = MPVPlayer(configuration: configuration)
        self.player = player
        player.load(url)
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.isPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    private func seek(_ direction: MoveCommandDirection) {
        guard let player else { return }
        switch direction {
        case .left:
            player.seek(by: .seconds(-10))
        case .right:
            player.seek(by: .seconds(10))
        default:
            break
        }
    }

    // MARK: - 工具

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 杜比视界状态（MPVUI 自己判定的：源 profile / 是否原生输出 / 是否走了有损转换）
    private func rangeBadge(_ player: MPVPlayer) -> String {
        String(describing: player.dolbyVisionStatus)
    }
}
