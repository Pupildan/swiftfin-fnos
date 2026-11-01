import SwiftUI
import AVFoundation
import QuartzCore

// MARK: - 宿主 UIView

/// 弹幕宿主视图：提供一个纯容器 CALayer，全部弹幕以 CATextLayer 子层存在。
/// 视图本身不参与 hit testing（不挡遥控器焦点）。
public final class DanmakuHostView: UIView {

    private let danmakuContainer = CALayer()
    private(set) public var engine: DanmakuEngine!

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        danmakuContainer.masksToBounds = false
        danmakuContainer.isOpaque = false
        layer.addSublayer(danmakuContainer)
        engine = DanmakuEngine(container: danmakuContainer)
        engine.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        danmakuContainer.frame = bounds
        CATransaction.commit()
        engine.layoutChanged()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.displayScale > 0 {
            engine.contentsScale = traitCollection.displayScale
        }
    }

    /// 替换数据源（换集）。立即按当前播放时间定位。
    public func setTimeline(_ timeline: DanmakuTimeline?) {
        if let timeline {
            engine.load(timeline: timeline)
        } else {
            engine.unload()
        }
    }

    /// 开关弹幕：仅容器 opacity 动画，时间轴永不暂停
    public func setVisible(_ visible: Bool) {
        engine.setVisible(visible)
    }
}

// MARK: - SwiftUI 桥接

/// SwiftUI 弹幕层。叠在播放器视图之上（ZStack 最上层）：
///
/// ```swift
/// // 帧级同步：用平滑时钟包装播放器（消除 AVPlayer 音频时钟 ~20ms 的量化抖动；
/// // 弹幕层与视频层同走渲染服务的 vsync 提交管线，呈现误差 ≤ 1 帧）
/// let clock = AVPlayerSmoothedClock(player: player)
/// ZStack {
///     PlayerLayerView(player: player)
///     DanmakuOverlay(player: clock, timeline: timeline, isVisible: danmuOn)
///     if showPanel { DanmakuControlPanel(isVisible: $danmuOn, style: $style) }
/// }
/// ```
///
/// **事件穿透保证**：宿主 UIView `isUserInteractionEnabled = false`（UIKit 层），
/// CALayer 不参与命中测试与 tvOS 焦点引擎——遥控器事件与焦点永远穿透弹幕层，
/// 直达播放器/控制面板。VLC 时钟适配见 `SmoothedClock.swift` 尾部示例。
///
/// - `timeline` 以 class 引用传递：只有引用变化（新的一集）才会重载数据，
///   SwiftUI 的普通视图刷新不会触发重排/重载。
/// - `isVisible` 变化只触发 opacity 动画；引擎的 displayLink 与
///   时间轴读取永远运行——这是"关闭再打开瞬间无缝衔接"的机制。
public struct DanmakuOverlay: UIViewRepresentable {

    /// 弹幕时间源（必传播放器；VLC 等其他播放器可实现 DanmakuClock 后传入）
    public let player: DanmakuClock
    /// 弹幕时间轴（nil = 清空）。class 身份稳定，避免 SwiftUI 刷新导致重载
    public let timeline: DanmakuTimeline?
    /// 视觉显隐开关（不影响时间轴）
    public let isVisible: Bool
    public var style: DanmakuStyle

    public init(player: DanmakuClock,
                timeline: DanmakuTimeline?,
                isVisible: Bool,
                style: DanmakuStyle = .appleTV4K()) {
        self.player = player
        self.timeline = timeline
        self.isVisible = isVisible
        self.style = style
    }

    public func makeUIView(context: Context) -> DanmakuHostView {
        let view = DanmakuHostView(frame: .zero)
        view.engine.clock = player
        if let timeline {
            view.setTimeline(timeline)
        }
        view.setVisible(isVisible)
        context.coordinator.lastTimeline = timeline
        context.coordinator.lastVisible = isVisible
        return view
    }

    public func updateUIView(_ uiView: DanmakuHostView, context: Context) {
        let coordinator = context.coordinator

        // 仅在时间轴引用变化时重载（换集 / 手动重新匹配）
        if coordinator.lastTimeline !== timeline {
            coordinator.lastTimeline = timeline
            uiView.setTimeline(timeline)
        }
        // 显隐：只切 opacity
        if coordinator.lastVisible != isVisible {
            coordinator.lastVisible = isVisible
            uiView.setVisible(isVisible)
        }
        // 样式变化（字号/速度/透明度等）
        if coordinator.lastStyle.fontSize != style.fontSize
            || coordinator.lastStyle.scrollDuration != style.scrollDuration
            || coordinator.lastStyle.opacity != style.opacity {
            coordinator.lastStyle = style
            uiView.engine.updateStyle(style)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(timeline: timeline, visible: isVisible, style: style)
    }

    public final class Coordinator {
        var lastTimeline: DanmakuTimeline?
        var lastVisible: Bool
        var lastStyle: DanmakuStyle

        init(timeline: DanmakuTimeline?, visible: Bool, style: DanmakuStyle) {
            self.lastTimeline = timeline
            self.lastVisible = visible
            self.lastStyle = style
        }
    }
}
