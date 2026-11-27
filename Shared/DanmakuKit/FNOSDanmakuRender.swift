//
//  FNOSDanmakuRender.swift
//  飞牛影视 tvOS —— 弹幕图层渲染引擎
//
//  来源：本机 FNOSKit/Danmaku（对标 B 站 iOS / DanmakuKit 的成熟图层方案），
//  2026-11-27 移植进 tvOS target。为什么换掉旧的 TimelineView + Text.offset：
//  旧方案每帧由 SwiftUI 重建整棵 Text 视图树（ForEach + 布局 + 差分），
//  同屏几十条就是几十次视图重建 → 肉眼可见的停顿。
//
//  本引擎的性能设计：
//  - 每条弹幕一个 CATextLayer，生成时一次性光栅化，之后每帧只改 position.x；
//  - CATransaction.setDisableActions(true) 关掉隐式动画，主线程零绘制；
//  - CADisplayLink preferredFrameRateRange 显式请求 60~120Hz（设备自动钳制）；
//  - 时间源是 FNOSDanmuEngine 的 anchor 外推时钟（sync 铁律原封不动）；
//  - 开关弹幕只切容器 opacity，时间轴永不暂停 → 关掉再开会无缝接续。
//
//  轨道几何遵守项目死规则：顶部基准 110pt + offsetY，底部 260pt 字幕保护区。
//

import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

// MARK: - 模型

enum FNOSDanmakuLaneKind {
    case scroll
    case top
    case bottom
}

struct FNOSDanmakuItem {
    let time: Double
    let text: String
    let kind: FNOSDanmakuLaneKind
    /// dandanplay p 字段里的十进制 RGB（16777215 = 白）
    let rgb: UInt32
}

/// 一集弹幕的不可变时间轴。class 身份用于 SwiftUI 侧判断「是否换集」。
final class FNOSDanmakuTimeline {
    let items: [FNOSDanmakuItem]

    init(items: [FNOSDanmakuItem]) {
        self.items = items.sorted { $0.time < $1.time }
    }

    /// 第一个 time >= t 的下标（seek 时二分定位）
    func lowerBound(_ t: Double) -> Int {
        var lo = 0
        var hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - 样式（设置面板的 @AppStorage 全部映射到这里）

struct FNOSDanmakuStyle: Equatable {
    var fontSize: CGFloat = 26
    var strokeWidth: CGFloat = 2.5
    var opacity: Float = 1
    /// 横穿屏幕耗时（秒）。由设置面板 speed 换算：scrollDuration = 12 / speed
    var scrollDuration: Double = 12
    var fixedDuration: Double = 5
    /// 显示区域（屏高比例）
    var areaRatio: CGFloat = 0.3
    /// 垂直偏移（pt）
    var offsetY: CGFloat = 0
    var lineHeightFactor: CGFloat = 1.4
    var laneMargin: CGFloat = 16
    var maxOnScreen: Int = 300
    var hideBottom: Bool = false

    /// 顶部基准线（与旧渲染层完全一致，避免换引擎后整片弹幕上移）
    var laneTop: CGFloat { 110 + offsetY }
}

// MARK: - 时钟协议（由 FNOSDanmuEngine 的 anchor 外推实现）

protocol FNOSDanmakuClock: AnyObject {
    var danmakuTime: TimeInterval { get }
}

// MARK: - 渲染引擎

final class FNOSDanmakuRenderEngine {

    weak var clock: FNOSDanmakuClock?
    private let container: CALayer
    private var style: FNOSDanmakuStyle

    private var timeline: FNOSDanmakuTimeline?
    private var spawnIndex = 0

    private final class Active {
        let layer: CATextLayer
        let item: FNOSDanmakuItem
        let lane: Int
        let width: CGFloat
        let speed: CGFloat
        let spawnTime: Double
        let expireTime: Double

        init(layer: CATextLayer, item: FNOSDanmakuItem, lane: Int, width: CGFloat,
             speed: CGFloat, spawnTime: Double, expireTime: Double) {
            self.layer = layer
            self.item = item
            self.lane = lane
            self.width = width
            self.speed = speed
            self.spawnTime = spawnTime
            self.expireTime = expireTime
        }
    }

    private var activeScroll: [Active] = []
    private var activeFixed: [Active] = []
    /// 该轨道下一次可容纳新弹幕的时刻（同速弹幕右缘间距恒定，O(轨道数) 分配）
    private var laneReadyAt: [Double] = []
    private var fixedBusyUntil: [Double] = []

    private var displayLink: CADisplayLink?
    private var lastTime: Double = 0
    private var isVisible = true
    var contentsScale: CGFloat = 2

    init(container: CALayer, style: FNOSDanmakuStyle = FNOSDanmakuStyle()) {
        self.container = container
        self.style = style
        rebuildLaneCapacity()
        startDisplayLink()
    }

    deinit { displayLink?.invalidate() }

    // MARK: 生命周期

    func load(timeline: FNOSDanmakuTimeline?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clearAll()
        CATransaction.commit()
        self.timeline = timeline
        spawnIndex = timeline.map { $0.lowerBound(currentTime() + 0.001) } ?? 0
        lastTime = currentTime()
    }

    func updateStyle(_ newStyle: FNOSDanmakuStyle) {
        let hideBottomChanged = newStyle.hideBottom != style.hideBottom
        style = newStyle
        container.opacity = isVisible ? style.opacity : 0
        if hideBottomChanged {
            // 隐藏底部开关切换：撤掉在屏的底部弹幕，滚动弹幕不动
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for danmaku in activeFixed where danmaku.item.kind == .bottom {
                danmaku.layer.removeFromSuperlayer()
            }
            activeFixed.removeAll { $0.item.kind == .bottom }
            CATransaction.commit()
        }
        layoutChanged()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        container.opacity = visible ? style.opacity : 0
        CATransaction.commit()
    }

    func layoutChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildLaneCapacity()
        for danmaku in activeScroll {
            danmaku.layer.position.y = laneCenterY(danmaku.lane)
        }
        for danmaku in activeFixed {
            danmaku.layer.position.y = fixedCenterY(danmaku.item.kind)
        }
        CATransaction.commit()
    }

    // MARK: 帧循环

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
        // .common：拖进度条（手势追踪）期间也不掉帧
        link.add(to: .main, forMode: .common)
        if #available(tvOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 120)
        }
        displayLink = link
    }

    fileprivate func tick() {
        guard let timeline else { return }
        let t = currentTime()
        // seek / 跳集 / 卡顿：|Δt| > 0.8s → 清屏 + 二分定位
        if abs(t - lastTime) > 0.8 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clearAll()
            CATransaction.commit()
            spawnIndex = timeline.lowerBound(t)
            lastTime = t
            return
        }
        lastTime = t

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // 单帧生成上限，极端密集时分帧入场，避免单帧尖峰
        var budget = 80
        let screenWidth = container.bounds.width
        while spawnIndex < timeline.items.count, budget > 0 {
            let item = timeline.items[spawnIndex]
            if item.time > t { break }
            spawnIndex += 1
            budget -= 1
            if t - item.time > style.scrollDuration { continue }
            switch item.kind {
            case .scroll: spawnScroll(item, at: t, screenWidth: screenWidth)
            case .top, .bottom: spawnFixed(item, at: t)
            }
        }
        updateScrollPositions(at: t)
        removeExpiredFixed(at: t)
    }

    // MARK: 生成

    private func spawnScroll(_ item: FNOSDanmakuItem, at t: Double, screenWidth: CGFloat) {
        guard activeScroll.count + activeFixed.count < style.maxOnScreen else { return }
        let width = measureWidth(of: item)
        let speed = (screenWidth + width) / CGFloat(style.scrollDuration)
        guard let lane = availableLane(at: t) else { return }
        // 下一条要等本条尾部完全进入屏幕并留出 margin
        laneReadyAt[lane] = t + Double((width + style.laneMargin) / speed)

        let layer = makeTextLayer(for: item)
        layer.bounds.size = CGSize(width: width, height: laneHeight)
        let x = screenWidth + width / 2 - speed * CGFloat(t - item.time)
        layer.position = CGPoint(x: x, y: laneCenterY(lane))
        container.addSublayer(layer)
        activeScroll.append(Active(layer: layer, item: item, lane: lane, width: width,
                                   speed: speed, spawnTime: item.time, expireTime: .infinity))
    }

    private func spawnFixed(_ item: FNOSDanmakuItem, at t: Double) {
        guard !(item.kind == .bottom && style.hideBottom) else { return }
        guard activeScroll.count + activeFixed.count < style.maxOnScreen else { return }
        guard let lane = fixedBusyUntil.firstIndex(where: { t >= $0 }) else { return }
        fixedBusyUntil[lane] = t + style.fixedDuration

        let width = measureWidth(of: item)
        let layer = makeTextLayer(for: item)
        layer.bounds.size = CGSize(width: width, height: laneHeight)
        layer.position = CGPoint(x: container.bounds.width / 2, y: fixedCenterY(item.kind))
        container.addSublayer(layer)
        activeFixed.append(Active(layer: layer, item: item, lane: lane, width: width,
                                  speed: 0, spawnTime: t, expireTime: t + style.fixedDuration))
    }

    private func availableLane(at t: Double) -> Int? {
        for lane in laneReadyAt.indices where t >= laneReadyAt[lane] { return lane }
        return nil
    }

    private func updateScrollPositions(at t: Double) {
        let screenWidth = container.bounds.width
        var write = 0
        for danmaku in activeScroll {
            let elapsed = CGFloat(t - danmaku.spawnTime)
            let x = screenWidth + danmaku.width / 2 - danmaku.speed * elapsed
            if x + danmaku.width / 2 < 0 {
                danmaku.layer.removeFromSuperlayer()
                continue
            }
            danmaku.layer.position.x = x
            activeScroll[write] = danmaku
            write += 1
        }
        if write != activeScroll.count { activeScroll.removeSubrange(write...) }
    }

    private func removeExpiredFixed(at t: Double) {
        var write = 0
        for danmaku in activeFixed {
            if t >= danmaku.expireTime {
                danmaku.layer.removeFromSuperlayer()
                continue
            }
            activeFixed[write] = danmaku
            write += 1
        }
        if write != activeFixed.count { activeFixed.removeSubrange(write...) }
    }

    // MARK: 图层

    private func makeTextLayer(for item: FNOSDanmakuItem) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = attributedString(for: item)
        layer.contentsScale = contentsScale
        layer.isOpaque = false
        layer.masksToBounds = false
        layer.alignmentMode = .left
        layer.truncationMode = .none
        return layer
    }

    private func attributedString(for item: FNOSDanmakuItem) -> NSAttributedString {
        let font = UIFont.boldSystemFont(ofSize: style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let color = UIColor(red: CGFloat((item.rgb >> 16) & 0xFF) / 255,
                            green: CGFloat((item.rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(item.rgb & 0xFF) / 255, alpha: 1)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]
        if style.strokeWidth > 0 {
            attrs[.strokeWidth] = -style.strokeWidth       // 负宽度 = 填充 + 描边
            attrs[.strokeColor] = UIColor.black.withAlphaComponent(0.85)
        }
        return NSAttributedString(string: item.text, attributes: attrs)
    }

    private func measureWidth(of item: FNOSDanmakuItem) -> CGFloat {
        ceil(attributedString(for: item).size().width) + style.strokeWidth
    }

    // MARK: 轨道几何（顶部 110 + offsetY、底部 260 字幕保护区）

    private var laneHeight: CGFloat { style.fontSize * style.lineHeightFactor }

    private var laneBottom: CGFloat {
        min(container.bounds.height * style.areaRatio, container.bounds.height - 260)
    }

    private func rebuildLaneCapacity() {
        let count = max(1, min(20, Int((laneBottom - style.laneTop) / laneHeight)))
        laneReadyAt = Array(repeating: 0, count: count)
        fixedBusyUntil = Array(repeating: 0, count: max(1, count))
    }

    private func laneCenterY(_ lane: Int) -> CGFloat {
        style.laneTop + (CGFloat(lane) + 0.5) * laneHeight
    }

    private func fixedCenterY(_ kind: FNOSDanmakuLaneKind) -> CGFloat {
        if kind == .top { return style.laneTop + laneHeight / 2 }
        // 底部固定弹幕上移到字幕保护区之上（与旧渲染层 height-290 一致）
        return min(max(container.bounds.height - 290 + style.offsetY, style.laneTop),
                   container.bounds.height - 260)
    }

    private func clearAll() {
        for danmaku in activeScroll + activeFixed { danmaku.layer.removeFromSuperlayer() }
        activeScroll.removeAll(keepingCapacity: true)
        activeFixed.removeAll(keepingCapacity: true)
        rebuildLaneCapacity()
    }

    private func currentTime() -> TimeInterval { clock?.danmakuTime ?? lastTime }
}

// MARK: - 弱代理（打破 CADisplayLink 与引擎的强引用环）

private final class WeakProxy: NSObject {
    private weak var target: FNOSDanmakuRenderEngine?
    init(_ target: FNOSDanmakuRenderEngine) {
        self.target = target
        super.init()
    }
    @objc func tick() { target?.tick() }
}

// MARK: - 宿主 UIView + SwiftUI 桥接

final class FNOSDanmakuHostView: UIView {
    private let danmakuContainer = CALayer()
    private(set) var engine: FNOSDanmakuRenderEngine!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // 不参与 hit-testing / tvOS 焦点引擎
        backgroundColor = .clear
        layer.masksToBounds = false
        danmakuContainer.masksToBounds = false
        danmakuContainer.isOpaque = false
        layer.addSublayer(danmakuContainer)
        engine = FNOSDanmakuRenderEngine(container: danmakuContainer)
        engine.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        danmakuContainer.frame = bounds
        CATransaction.commit()
        engine.layoutChanged()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.displayScale > 0 { engine.contentsScale = traitCollection.displayScale }
    }
}

struct FNOSDanmakuOverlay: UIViewRepresentable {
    let clock: FNOSDanmakuClock
    let timeline: FNOSDanmakuTimeline?
    let style: FNOSDanmakuStyle
    let isVisible: Bool

    func makeUIView(context: Context) -> FNOSDanmakuHostView {
        let view = FNOSDanmakuHostView(frame: .zero)
        view.engine.clock = clock
        view.engine.updateStyle(style)
        view.setTimeline(timeline)
        view.setVisible(isVisible)
        context.coordinator.lastTimeline = timeline
        context.coordinator.lastStyle = style
        context.coordinator.lastVisible = isVisible
        return view
    }

    func updateUIView(_ uiView: FNOSDanmakuHostView, context: Context) {
        let c = context.coordinator
        uiView.engine.clock = clock
        // 只有时间轴引用变化（换集/重新匹配）才重载
        if c.lastTimeline !== timeline {
            c.lastTimeline = timeline
            uiView.setTimeline(timeline)
        }
        if c.lastStyle != style {
            c.lastStyle = style
            uiView.engine.updateStyle(style)
        }
        if c.lastVisible != isVisible {
            c.lastVisible = isVisible
            uiView.setVisible(isVisible)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(timeline: timeline, style: style, visible: isVisible) }

    final class Coordinator {
        var lastTimeline: FNOSDanmakuTimeline?
        var lastStyle: FNOSDanmakuStyle
        var lastVisible: Bool
        init(timeline: FNOSDanmakuTimeline?, style: FNOSDanmakuStyle, visible: Bool) {
            self.lastTimeline = timeline
            self.lastStyle = style
            self.lastVisible = visible
        }
    }
}

private extension FNOSDanmakuHostView {
    func setTimeline(_ timeline: FNOSDanmakuTimeline?) { engine.load(timeline: timeline) }
    func setVisible(_ visible: Bool) { engine.setVisible(visible) }
}
