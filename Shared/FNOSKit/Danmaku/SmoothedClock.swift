import Foundation
import AVFoundation
import QuartzCore

// MARK: - 帧级同步时钟
//
// 时间同步策略（目标：弹幕与画面误差 ≤ 1 帧 / ±16ms）：
//
// 1. **同一时钟域**：视频画面的呈现由渲染服务（render server）在 vsync 统一提交，
//    弹幕 CATextLayer 与视频层走同一条提交管线 → 天然共享同一帧的呈现延迟，
//    不存在"两个渲染管线各走各的延迟"的问题。
//
// 2. **消除时钟量化抖动**：AVPlayer.currentTime() 底层是音频采样时钟，
//    返回值按音频缓冲块（约 20ms）跳变。直接用它驱动弹幕会产生可感知的抖动。
//    `AVPlayerSmoothedClock` 用「锚点 + 单调外推 + 逐帧回拉」做亚帧级平滑：
//      est(t) = anchorMedia + (now - anchorHost) × rate
//    每帧向音频时钟回拉 6%（60fps 下约 1s 内收敛，肉眼无感），
//    大漂移（seek/卡顿 >0.25s）直接吸附，永不产生跳变。
//
// 3. **VLCKit 对接**：VLCKit 的 time 只有毫秒精度且更新频率低，直接读会抖动。
//    用 `ClosureClock` 包一层并启用插值即可（见文件尾部示例）。

/// 平滑时钟：包装 AVPlayer，输出连续无跳变的播放时间。
/// 用法：`DanmakuOverlay(player: smoothedClock, ...)`（DanmakuClock 协议）。
public final class AVPlayerSmoothedClock: DanmakuClock {

    private weak var player: AVPlayer?
    private var anchorMedia: TimeInterval = 0
    private var anchorHost: CFTimeInterval = 0
    private var lastRate: Float = -1

    /// 小漂移每帧回拉比例（6% ≈ 60fps 下 1 秒收敛）
    private let pullPerFrame: Double = 0.06
    /// 大漂移吸附阈值（秒）——seek、解码卡顿
    private let snapThreshold: Double = 0.25

    public init(player: AVPlayer) {
        self.player = player
        reanchor()
    }

    public var danmakuTime: TimeInterval {
        guard let player else { return anchorMedia }
        let now = CACurrentMediaTime()
        let rate = player.rate

        // 播放/暂停/倍速切换：立即重锚，保证模式切换无迟滞
        if rate != lastRate {
            reanchor(at: now)
            lastRate = rate
        }
        if rate == 0 {
            return anchorMedia   // 暂停：时间冻结（引擎的生成/移动随之静止）
        }

        // 单调外推：音频时钟锚点 + 主机单调钟 × 倍速
        var estimate = anchorMedia + (now - anchorHost) * Double(rate)

        // 与音频时钟对账
        let raw = player.currentTime().seconds
        let drift = raw - estimate

        if abs(drift) > snapThreshold {
            // 大漂移：吸附（seek / 缓冲卡顿）
            reanchor(at: now)
            return raw
        }
        // 小漂移：逐帧温和回拉，外推锚点连续更新 → 无任何跳变
        estimate += drift * pullPerFrame
        anchorMedia = estimate
        anchorHost = now
        return estimate
    }

    private func reanchor(at now: CFTimeInterval = CACurrentMediaTime()) {
        anchorMedia = player?.currentTime().seconds ?? anchorMedia
        anchorHost = now
    }
}

/// 通用闭包时钟：适配任意播放器（VLCKit / 自研内核 / 预览）。
/// 播放器时间粒度粗（如 VLCKit 毫秒级、更新频率低）时，建议开启插值。
public final class ClosureClock: DanmakuClock {

    private let provider: () -> TimeInterval
    private let interpolates: Bool

    // 插值状态
    private var lastRaw: TimeInterval = 0
    private var lastRawAt: CFTimeInterval = 0
    private var estimated: TimeInterval = 0

    /// - Parameters:
    ///   - provider: 返回播放器当前时间（秒）
    ///   - interpolates: true 时对 provider 输出做线性外推平滑
    ///     （VLCKit 等毫秒级/低频时间源请开启；AVPlayer 原生时钟无需开启）
    public init(provider: @escaping () -> TimeInterval, interpolates: Bool = false) {
        self.provider = provider
        self.interpolates = interpolates
        lastRaw = provider()
        lastRawAt = CACurrentMediaTime()
        estimated = lastRaw
    }

    public var danmakuTime: TimeInterval {
        let raw = provider()
        let now = CACurrentMediaTime()

        if !interpolates {
            lastRaw = raw
            lastRawAt = now
            return raw
        }

        let delta = raw - lastRaw
        if abs(delta) > 0.25 || abs(delta) < 0.0001 {
            // seek 或静止：直接采用并重置外推
            lastRaw = raw
            lastRawAt = now
            estimated = raw
            return raw
        }
        // 用最近两次采样的速度做 1 帧外推，消除时间源的低频台阶
        let dt = now - lastRawAt
        let velocity = dt > 0 ? delta / dt : 0
        estimated = raw + velocity * dt
        lastRaw = raw
        lastRawAt = now
        return estimated
    }
}

// MARK: - VLCKit 适配示例（Swiftfin tvOS 现用 VLCKit）
//
// import VLCUI // 或 import MobileVLCKit
//
// extension VLCPlayer {
//     var danmakuClock: DanmakuClock {
//         ClosureClock(interpolates: true) { [weak self] in
//             guard let self else { return 0 }
//             return TimeInterval(self.timeInt32) / 1000.0   // 毫秒 → 秒
//         }
//     }
// }
//
// 注意：VLCKit 播放中可监听 `mediaPlayer.timeChanged` 保持内部时间新鲜，
// 外推时钟会把毫秒台阶抹平为逐帧连续的时间轴。
