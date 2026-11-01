import Foundation
import QuartzCore
import UIKit

// MARK: - 时间源协议

/// 弹幕时间源。引擎**每一帧**都会同步读取 `time`——这是时间轴永不中断的保证：
/// 播放/暂停/倍速/seek 全部自然生效，无需任何额外状态同步。
public protocol DanmakuClock: AnyObject {
    /// 当前播放时间（秒）
    var danmakuTime: TimeInterval { get }
}

extension AVPlayer: DanmakuClock {
    public var danmakuTime: TimeInterval { currentTime().seconds }
}

// MARK: - 刷新率策略

/// CADisplayLink 刷新率策略
public enum RefreshRatePolicy: Equatable, Sendable {
    /// 跟随显示设备最大刷新率（推荐：弹幕运动由 App 生成，
    /// 刷新率越高滚动越丝滑；60Hz 显示器自动钳制为 60）
    case displayMaximum
    /// 对齐视频帧率（会被显示设备上限钳制，且不低于 24fps）。
    /// 4K120 片源在 120Hz 输出的电视上即实现"帧率匹配"
    case matchVideo(fps: Int)
}

// MARK: - 渲染引擎

/// 弹幕渲染引擎（CADisplayLink + CATextLayer）。
///
/// 性能设计（对标 B 站 iOS / DanmakuKit 的图层方案）：
/// - **每帧只做 position 赋值**：每个弹幕是一个独立 CATextLayer，在生成时一次性
///   完成文本光栅化，之后每帧仅改 `position.x`，合成完全由渲染服务（GPU）完成，
///   主线程零绘制。同屏 200+ 图层对 Core Animation 而言是轻负载。
/// - **CATransaction.setDisableActions(true)**：关闭隐式动画，避免每帧产生
///   动画对象（这是 ForEach + withAnimation 方案掉帧的根源）。
/// - **CADisplayLink preferredFrameRateRange**：显式请求 60~120Hz，ProMotion
///   设备上跟随最大刷新率。
/// - **永不暂停**：显示/隐藏只是容器层 opacity 动画；displayLink 与时间轴
///   读取始终运行。关闭再打开，弹幕在正确的时间点原样接续（图层还在飞）。
/// - **seek 检测**：|Δt| > 0.8s 判定为跳转 → 清屏 + 二分定位到新时间点。
public final class DanmakuEngine {

    // MARK: - 依赖

    /// 时间源（弱引用，通常为 AVPlayer）
    public weak var clock: DanmakuClock?
    /// 承载弹幕图层的容器（由 HostView 提供）
    private let container: CALayer
    private var style: DanmakuStyle

    // MARK: - 数据

    private var timeline: DanmakuTimeline?
    /// 下一条待生成弹幕的下标（单调推进；seek 时二分重定位）
    private var spawnIndex = 0

    // MARK: - 活动弹幕

    private final class ActiveDanmaku {
        let layer: CATextLayer
        let item: DanmakuItem
        let lane: Int
        let width: CGFloat
        let speed: CGFloat      // 仅滚动弹幕使用
        let spawnTime: TimeInterval
        /// 固定弹幕的消失时刻
        let expireTime: TimeInterval

        init(layer: CATextLayer, item: DanmakuItem, lane: Int, width: CGFloat,
             speed: CGFloat, spawnTime: TimeInterval, expireTime: TimeInterval) {
            self.layer = layer
            self.item = item
            self.lane = lane
            self.width = width
            self.speed = speed
            self.spawnTime = spawnTime
            self.expireTime = expireTime
        }
    }

    private var activeScroll: [ActiveDanmaku] = []
    private var activeFixed: [ActiveDanmaku] = []

    // MARK: - 轨道状态

    /// 滚动轨道：该轨道何时能再容纳新弹幕（前一弹幕尾部离开右侧安全距离的时刻）
    private var scrollLaneReadyAt: [TimeInterval] = []
    /// 固定轨道：占用到期时刻
    private var topLaneBusyUntil: [TimeInterval] = []
    private var bottomLaneBusyUntil: [TimeInterval] = []

    // MARK: - 帧驱动

    private var displayLink: CADisplayLink?
    private var lastTime: TimeInterval = 0
    private var isVisible = true
    /// 刷新率策略（默认跟随显示设备最大值）
    public var refreshRatePolicy: RefreshRatePolicy = .displayMaximum

    /// 当前同屏弹幕数（调试/HUD 用）
    public var activeCount: Int { activeScroll.count + activeFixed.count }

    /// 文本图层光栅化倍率（由宿主视图按 displayScale 设置）
    public var contentsScale: CGFloat = 2

    // MARK: - 生命周期

    public init(container: CALayer, style: DanmakuStyle = .appleTV4K()) {
        self.container = container
        self.style = style
        rebuildLaneCapacity()
        startDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    /// 视图尺寸变化（旋转/布局）后调用
    public func layoutChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildLaneCapacity()
        // 已在屏的弹幕按新轨道高度重新摆放纵向位置
        for danmaku in activeScroll {
            danmaku.layer.position.y = laneCenterY(danmaku.lane)
        }
        for danmaku in activeFixed {
            danmaku.layer.position.y = fixedLaneCenterY(danmaku.item.kind, index: danmaku.lane)
        }
        CATransaction.commit()
    }

    public func updateStyle(_ newStyle: DanmakuStyle) {
        style = newStyle
        container.opacity = isVisible ? style.opacity : 0
        layoutChanged()
    }

    // MARK: - 数据装载

    /// 装载/替换弹幕时间轴。立即按当前播放时间定位（无缝衔接，不重新加载）。
    public func load(timeline: DanmakuTimeline) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clearAll()
        CATransaction.commit()

        self.timeline = timeline
        spawnIndex = timeline.lowerBound(currentTime() + 0.001)
        lastTime = currentTime()
    }

    /// 清空全部弹幕（换集时用）
    public func unload() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clearAll()
        CATransaction.commit()
        timeline = nil
        spawnIndex = 0
    }

    // MARK: - 可见性开关（纯视觉，时间轴不动）

    /// 开关弹幕：**只**做容器层 opacity 动画。
    /// displayLink 与时间轴读取持续运行，因此：
    /// - 关闭期间弹幕照常推进、到点消失；
    /// - 再次打开时看到的正是"此刻应该在屏幕上"的弹幕，无重载、无时间错乱。
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        CATransaction.begin()
        CATransaction.setAnimationDuration(style.toggleAnimationDuration)
        container.opacity = visible ? style.opacity : 0
        CATransaction.commit()
    }

    // MARK: - seek

    /// 外部主动通知 seek（引擎同时也有基于 Δt 的自动检测，双保险）
    public func seek(to time: TimeInterval) {
        guard let timeline else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clearAll()
        CATransaction.commit()

        spawnIndex = timeline.lowerBound(time)
        lastTime = time
    }

    // MARK: - 帧循环

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
        // .common：即使在手势追踪（遥控器滑动进度条）期间也不掉帧
        link.add(to: .main, forMode: .common)
        applyFrameRate(to: link)
        displayLink = link
    }

    /// 设置刷新率策略（可随时切换，例如检测到 4K120 片源后调用）
    public func setRefreshRatePolicy(_ policy: RefreshRatePolicy) {
        refreshRatePolicy = policy
        if let link = displayLink {
            applyFrameRate(to: link)
        }
    }

    /// 把 CADisplayLink 的 preferredFrameRateRange 对齐到策略目标：
    /// 上限永远取显示设备硬件最大值（maximumPreferredFramesPerSecond），
    /// preferred 按策略选择——设备不支持时系统自动钳制，无需人工干预。
    private func applyFrameRate(to link: CADisplayLink) {
        let displayMax = Int(link.maximumPreferredFramesPerSecond)
        let preferred: Int
        switch refreshRatePolicy {
        case .displayMaximum:
            preferred = displayMax
        case .matchVideo(let fps):
            preferred = max(24, min(fps, displayMax))
        }
        if #available(tvOS 15.0, iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(60, preferred),
                maximum: displayMax,
                preferred: preferred
            )
        }
    }

    fileprivate func tick() {
        guard let timeline else { return }
        let t = currentTime()

        // ---- seek 自动检测（含倒退、跳集、倍速突变）----
        if abs(t - lastTime) > 0.8 {
            seek(to: t)
            return
        }
        lastTime = t

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        spawnDueItems(at: t)
        updateScrollPositions(at: t)
        removeExpiredFixed(at: t)
    }

    // MARK: 生成

    private func spawnDueItems(at t: TimeInterval) {
        guard let timeline else { return }
        var budget = 80   // 单帧生成上限，极端跳转时分帧入场，避免单帧尖峰
        let screenWidth = container.bounds.width

        while spawnIndex < timeline.items.count, budget > 0 {
            let item = timeline.items[spawnIndex]
            if item.time > t { break }
            spawnIndex += 1
            budget -= 1

            // 已经过头太多的（seek 边缘）直接丢弃
            if t - item.time > style.scrollDuration { continue }

            switch item.kind {
            case .scroll:
                spawnScroll(item, at: t, screenWidth: screenWidth)
            case .top, .bottom:
                spawnFixed(item, at: t)
            }
        }
    }

    private func spawnScroll(_ item: DanmakuItem, at t: TimeInterval, screenWidth: CGFloat) {
        guard activeScroll.count + activeFixed.count < style.maxOnScreen else { return }

        let width = measureWidth(of: item)
        let speed = (screenWidth + width) / CGFloat(style.scrollDuration)

        // ---- 防重叠分轨：找一条"尾部已让出安全距离"的轨道 ----
        guard let lane = availableScrollLane(for: width, at: t, speed: speed) else {
            return   // 全部轨道占满 → 丢弃（比堆叠重叠体验好）
        }
        // 该轨道的下一个可用时刻：尾部弹幕右缘离开右侧 margin 的时刻
        scrollLaneReadyAt[lane] = t + TimeInterval((width + style.laneMargin) / speed)

        let layer = makeTextLayer(for: item)
        layer.bounds.size = CGSize(width: width, height: laneHeight())
        let x = screenWidth + width / 2 - speed * CGFloat(t - item.time)   // 迟到的弹幕从中间出现
        layer.position = CGPoint(x: x, y: laneCenterY(lane))
        container.addSublayer(layer)

        activeScroll.append(ActiveDanmaku(
            layer: layer, item: item, lane: lane, width: width,
            speed: speed, spawnTime: item.time,
            expireTime: .infinity
        ))
    }

    private func spawnFixed(_ item: DanmakuItem, at t: TimeInterval) {
        guard activeScroll.count + activeFixed.count < style.maxOnScreen else { return }

        let isTop = item.kind == .top
        var lanes = isTop ? topLaneBusyUntil : bottomLaneBusyUntil
        guard let lane = lanes.firstIndex(where: { t >= $0 }) else {
            return   // 固定轨道全占满 → 丢弃
        }
        lanes[lane] = t + style.fixedDuration
        if isTop { topLaneBusyUntil = lanes } else { bottomLaneBusyUntil = lanes }

        let width = measureWidth(of: item)
        let layer = makeTextLayer(for: item)
        layer.bounds.size = CGSize(width: width, height: laneHeight())
        layer.position = CGPoint(
            x: container.bounds.width / 2,
            y: fixedLaneCenterY(item.kind, index: lane)
        )
        container.addSublayer(layer)

        activeFixed.append(ActiveDanmaku(
            layer: layer, item: item, lane: lane, width: width,
            speed: 0, spawnTime: t, expireTime: t + style.fixedDuration
        ))
    }

    /// O(轨道数) 的滚动轨道分配：
    /// 轨道可用 ⇔ 该轨道上一条弹幕的**右缘已完全进入屏幕并留出 margin**。
    /// 由于所有弹幕同速，右缘间距恒定，因此用"就绪时刻"表达，无需遍历弹幕。
    private func availableScrollLane(for width: CGFloat, at t: TimeInterval, speed: CGFloat) -> Int? {
        for lane in 0..<scrollLaneReadyAt.count where t >= scrollLaneReadyAt[lane] {
            return lane
        }
        return nil
    }

    // MARK: 更新 / 回收

    private func updateScrollPositions(at t: TimeInterval) {
        let screenWidth = container.bounds.width
        var writeIndex = 0
        for readIndex in activeScroll.indices {
            let danmaku = activeScroll[readIndex]
            let elapsed = CGFloat(t - danmaku.spawnTime)
            let x = screenWidth + danmaku.width / 2 - danmaku.speed * elapsed

            // 右缘离开屏幕左侧 → 回收
            if x + danmaku.width / 2 < 0 {
                danmaku.layer.removeFromSuperlayer()
                continue
            }
            danmaku.layer.position.x = x
            activeScroll[writeIndex] = danmaku
            writeIndex += 1
        }
        if writeIndex != activeScroll.count {
            activeScroll.removeSubrange(writeIndex...)
        }
    }

    private func removeExpiredFixed(at t: TimeInterval) {
        var writeIndex = 0
        for readIndex in activeFixed.indices {
            let danmaku = activeFixed[readIndex]
            if t >= danmaku.expireTime {
                danmaku.layer.removeFromSuperlayer()
                continue
            }
            activeFixed[writeIndex] = danmaku
            writeIndex += 1
        }
        if writeIndex != activeFixed.count {
            activeFixed.removeSubrange(writeIndex...)
        }
    }

    // MARK: - 图层构造

    private func makeTextLayer(for item: DanmakuItem) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = attributedString(for: item)
        layer.contentsScale = contentsScale   // 4K 面板清晰度（宿主视图注入 displayScale）
        layer.isOpaque = false
        layer.masksToBounds = false
        return layer
    }

    private func attributedString(for item: DanmakuItem) -> NSAttributedString {
        let font = style.bold
            ? UIFont.boldSystemFont(ofSize: style.fontSize)
            : UIFont.systemFont(ofSize: style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: CGFloat(item.color.red) / 255,
                                      green: CGFloat(item.color.green) / 255,
                                      blue: CGFloat(item.color.blue) / 255, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        // 描边（负宽度 = 填充 + 描边）
        if style.strokeWidth > 0 {
            var withStroke = attributes
            withStroke[.strokeWidth] = -style.strokeWidth
            withStroke[.strokeColor] = UIColor(red: CGFloat(style.strokeColor.red) / 255,
                                               green: CGFloat(style.strokeColor.green) / 255,
                                               blue: CGFloat(style.strokeColor.blue) / 255, alpha: 1)
            return NSAttributedString(string: item.text, attributes: withStroke)
        }
        return NSAttributedString(string: item.text, attributes: attributes)
    }

    private func measureWidth(of item: DanmakuItem) -> CGFloat {
        ceil(attributedString(for: item).size().width) + style.strokeWidth
    }

    // MARK: - 轨道几何

    private var laneCount: Int = 0

    private var laneHeight: CGFloat {
        style.fontSize * style.lineSpacingFactor
    }

    private func rebuildLaneCapacity() {
        let height = container.bounds.height * style.areaRatio
        laneCount = max(1, Int(height / laneHeight))
        scrollLaneReadyAt = Array(repeating: 0, count: laneCount)
        topLaneBusyUntil = Array(repeating: 0, count: laneCount)
        bottomLaneBusyUntil = Array(repeating: 0, count: laneCount)
    }

    /// 滚动轨道中心 Y（从顶部往下排）
    private func laneCenterY(_ lane: Int) -> CGFloat {
        let top = container.bounds.height * (1 - style.areaRatio) / 2
        return top + (CGFloat(lane) + 0.5) * laneHeight
    }

    /// 固定轨道中心 Y（top 从顶部排，bottom 从底部排）
    private func fixedLaneCenterY(_ kind: DanmakuLaneKind, index: Int) -> CGFloat {
        let lh = laneHeight
        if kind == .top {
            return (CGFloat(index) + 0.5) * lh
        }
        return container.bounds.height - (CGFloat(index) + 0.5) * lh
    }

    // MARK: - 清理

    private func clearAll() {
        for danmaku in activeScroll { danmaku.layer.removeFromSuperlayer() }
        for danmaku in activeFixed { danmaku.layer.removeFromSuperlayer() }
        activeScroll.removeAll(keepingCapacity: true)
        activeFixed.removeAll(keepingCapacity: true)
        scrollLaneReadyAt = Array(repeating: 0, count: laneCount)
        topLaneBusyUntil = Array(repeating: 0, count: laneCount)
        bottomLaneBusyUntil = Array(repeating: 0, count: laneCount)
    }

    private func currentTime() -> TimeInterval {
        clock?.danmakuTime ?? lastTime
    }
}

// MARK: - 弱代理（打破 CADisplayLink 与引擎的强引用环）
// 引擎由 HostView 强持有；displayLink 仅弱引用引擎，避免循环引用导致的泄漏。

final class WeakProxy: NSObject {
    private weak var target: DanmakuEngine?

    init(_ target: DanmakuEngine) {
        self.target = target
        super.init()
    }

    @objc func tick() {
        target?.tick()
    }
}
