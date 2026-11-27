//
//  FNOSDanmakuRender.swift
//  飞牛影视 tvOS —— 弹幕渲染引擎（v222：CATextLayer 内容 + CAAnimation 移动）
//
//  来源：ATV-Bilibili-demo (yichengchen) 内置 DanmakuKit 的成熟方案 + 本机 FNOSKit。
//
//  版本历史教训：
//  - v217-v219：CADisplayLink 主线程每帧改 position.x → 主线程被占用就掉帧卡顿。
//  - v220：改 UIView cell + 自定义异步光栅化 layer + CABasicAnimation，
//    但 addSubview 到宿主自身触发 layoutSubviews→clearAll 死循环 → 全不显示（v221 修复）。
//  - v221：修复死循环后日志证明发射/回收/速度全部正常（在屏16 发射点推进 speed=1.0），
//    但屏幕仍无像素 → 嫌疑锁定自定义 FNOSDanmakuAsyncLayer 的异步光栅化不上屏。
//  - v222（本版）：**内容回退到 v219 验证过可见的 CATextLayer**（同步渲染，
//    v218 教训=纯实心字不加描边），**移动保留 CABasicAnimation**（v220 的丝滑机制）。
//    弹幕 layer 用 addSublayer 加到独立普通 UIView 容器（不触发布局回调，v219 同款）。
//
//  丝滑机制（v220/v221 继承）：
//  1. 每条弹幕发射时挂一个 CABasicAnimation(position.x)，动画由 render server
//     进程独立插值，主线程零逐帧位置计算 → 不受主线程负载影响。
//  2. 播放器周期回调（100/250ms）只负责「到点发射新弹幕」，不管位置。
//  3. 播放/暂停/倍速用容器 layer.speed（Core Animation 原生时间缩放）。
//
//  ⚠️ 不碰 FNOSDanmuEngine.sync/anchor 铁律（v130 教训）——那套只决定「何时发射」。
//  轨道几何保留项目死规则：顶部 110pt + offsetY，底部 260pt 字幕保护区。
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
    let rgb: UInt32
}

final class FNOSDanmakuTimeline {
    let items: [FNOSDanmakuItem]
    init(items: [FNOSDanmakuItem]) { self.items = items.sorted { $0.time < $1.time } }
    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

struct FNOSDanmakuStyle: Equatable {
    var fontSize: CGFloat = 26
    var opacity: Float = 1
    /// 横穿屏幕耗时（秒），由设置面板 speed 换算：scrollDuration = 12 / speed
    var scrollDuration: Double = 12
    var fixedDuration: Double = 5
    var areaRatio: CGFloat = 0.3
    var offsetY: CGFloat = 0
    var lineHeightFactor: CGFloat = 1.4
    var laneMargin: CGFloat = 16
    var maxOnScreen: Int = 300
    var hideBottom: Bool = false
    var laneTop: CGFloat { 110 + offsetY }
}

@MainActor
protocol FNOSDanmakuClock: AnyObject {
    var danmakuTime: TimeInterval { get }
    /// 播放器倍速（0=暂停）；渲染层用它同步 CAAnimation layer.speed
    var playbackRate: Double { get }
}

// MARK: - 文本图层（v222：CATextLayer 同步渲染，v219 真机验证可见）

private func makeDanmakuTextLayer(item: FNOSDanmakuItem, fontSize: CGFloat,
                                  width: CGFloat, height: CGFloat,
                                  contentsScale: CGFloat) -> CATextLayer {
    let layer = CATextLayer()
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    let color = UIColor(red: CGFloat((item.rgb >> 16) & 0xFF) / 255,
                        green: CGFloat((item.rgb >> 8) & 0xFF) / 255,
                        blue: CGFloat(item.rgb & 0xFF) / 255, alpha: 1)
    // v218 教训：CATextLayer 不认「填充+描边」语义（只画轮廓=骨架字）→ 纯实心字
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph
    ]
    layer.string = NSAttributedString(string: item.text, attributes: attrs)
    layer.contentsScale = contentsScale
    layer.isOpaque = false
    layer.masksToBounds = false
    layer.backgroundColor = UIColor.clear.cgColor
    layer.bounds.size = CGSize(width: width, height: height)
    return layer
}

private func measureTextWidth(item: FNOSDanmakuItem, fontSize: CGFloat) -> CGFloat {
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    return ceil(NSString(string: item.text).size(withAttributes: [.font: font]).width) + 8
}

// MARK: - 渲染引擎（CAAnimation 驱动）

@MainActor
final class FNOSDanmakuRenderEngine {

    weak var clock: FNOSDanmakuClock?
    private let container: UIView
    private var style: FNOSDanmakuStyle
    var contentsScale: CGFloat = 2
    private var timeline: FNOSDanmakuTimeline?
    private var spawnIndex = 0
    /// v222: 在屏弹幕（CATextLayer + 媒体时间轴发射时刻，用于按寿命回收）
    private struct ActiveCell {
        let layer: CATextLayer
        let kind: FNOSDanmakuLaneKind
        let bornAt: Double
    }
    private var active: [ActiveCell] = []
    private var laneReadyAt: [Double] = []
    private var fixedBusyUntil: [Double] = []
    private var nextLane = 0
    private var lastTime: Double = 0
    private var isVisible = true
    private var diagTick = 0

    init(container: UIView, style: FNOSDanmakuStyle = FNOSDanmakuStyle()) {
        self.container = container
        self.style = style
        container.layer.speed = 1
        rebuildLanes()
    }

    // MARK: 对外接口（与 FNOSDanmuView 对接）

    func setTimeline(_ timeline: FNOSDanmakuTimeline?) {
        clearAll()
        self.timeline = timeline
        spawnIndex = timeline.map { $0.lowerBound(currentTime() + 0.001) } ?? 0
        lastTime = currentTime()
        // 换集/seek 时把「此刻应在屏上」的一批弹幕补发射出去（带 progress 偏移）
        emitFrom(currentTime(), backfill: true)
    }

    /// 播放器周期回调调用（100/250ms）——只负责到点发射，不算位置
    func sync(mediaTime: Double) {
        guard let timeline else { return }
        // 渲染诊断（4Hz 泵 × 8 ≈ 2s 节流）
        diagTick += 1
        if diagTick % 8 == 0 {
            FNOSDiagLog.send("弹幕渲染: 在屏\(active.count) 发射点\(spawnIndex)/\(timeline.items.count) t=\(Int(mediaTime)) lanes=\(laneReadyAt.count) speed=\(container.layer.speed) size=\(Int(container.bounds.width))x\(Int(container.bounds.height))")
        }
        if abs(mediaTime - lastTime) > 0.8 {
            clearAll()
            spawnIndex = timeline.lowerBound(mediaTime)
            emitFrom(mediaTime, backfill: true)
        }
        lastTime = mediaTime
        emitFrom(mediaTime, backfill: false)
        // 回收：滚动弹幕跑完时长 / 固定弹幕超过停留时长
        let expired = active.filter { cell in
            let lifespan = cell.kind == .scroll ? style.scrollDuration : style.fixedDuration
            return mediaTime - cell.bornAt > lifespan + 0.5
        }
        for cell in expired { remove(cell) }
    }

    /// 播放/暂停/倍速——改容器 layer.speed，Core Animation 原生时间缩放，
    /// 不用重新计算任何位置，也不会打断正在跑的动画。
    /// 值不变时跳过——4Hz 泵反复设 speed 会不断重映射 layer 时间轴。
    func setRate(_ rate: Double) {
        let s = Float(max(0, rate))
        guard container.layer.speed != s else { return }
        container.layer.speed = s
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        container.alpha = visible ? CGFloat(style.opacity) : 0
        CATransaction.commit()
    }

    func updateStyle(_ newStyle: FNOSDanmakuStyle) {
        let layoutKey = newStyle.areaRatio != style.areaRatio
            || newStyle.fontSize != style.fontSize
            || newStyle.offsetY != style.offsetY
        let hideKey = newStyle.hideBottom != style.hideBottom
        style = newStyle
        container.alpha = isVisible ? CGFloat(style.opacity) : 0
        if hideKey {
            for cell in active where cell.kind == .bottom { remove(cell) }
        }
        if layoutKey {
            clearAll()
            emitFrom(currentTime(), backfill: true)
        } else {
            rebuildLanes()
        }
    }

    func layoutChanged() {
        clearAll()
        emitFrom(currentTime(), backfill: true)
    }

    // MARK: 发射逻辑

    private func emitFrom(_ t: Double, backfill: Bool) {
        guard let timeline else { return }
        guard container.bounds.width > 100 else { return }   // 布局未就绪，防退化几何
        var budget = 50   // 单帧发射上限，防尖峰
        let screenWidth = container.bounds.width
        while spawnIndex < timeline.items.count, budget > 0 {
            let item = timeline.items[spawnIndex]
            if item.time > t { break }
            spawnIndex += 1
            budget -= 1
            let lateness = t - item.time
            if lateness > style.scrollDuration { continue }   // 太旧，跳过
            switch item.kind {
            case .scroll: shootScroll(item, at: t, lateness: lateness, screenWidth: screenWidth)
            case .top, .bottom: shootFixed(item, at: t, lateness: lateness)
            }
        }
        _ = backfill  // 两种模式共用（背填靠 lateness 决定初始位置）
    }

    private func shootScroll(_ item: FNOSDanmakuItem, at t: Double, lateness: Double, screenWidth: CGFloat) {
        guard active.count < style.maxOnScreen else { return }
        let width = measureTextWidth(item: item, fontSize: style.fontSize)
        guard let lane = availableLane(at: t) else { return }
        laneReadyAt[lane] = t + Double((width + style.laneMargin) / speed)

        let layer = makeDanmakuTextLayer(item: item, fontSize: style.fontSize,
                                         width: width, height: laneHeight,
                                         contentsScale: contentsScale)
        let y = laneCenterY(lane)
        let startX = screenWidth + width / 2 - speed * CGFloat(lateness)
        layer.position = CGPoint(x: startX, y: y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer.addSublayer(layer)
        CATransaction.commit()
        active.append(ActiveCell(layer: layer, kind: item.kind, bornAt: item.time))

        // 剩余路程 = 从 startX 到完全出屏 (x = -width/2)
        let remaining = Double(startX + width / 2)
        let duration = max(0.1, remaining / speed)
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = startX
        anim.toValue = -width / 2
        // duration 不除 layer.speed——Core Animation 会按 layer 时间缩放自动变速
        anim.duration = duration
        anim.beginTime = CACurrentMediaTime()
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        layer.add(anim, forKey: "fnos.scroll")
    }

    private func shootFixed(_ item: FNOSDanmakuItem, at t: Double, lateness: Double) {
        guard active.count < style.maxOnScreen else { return }
        guard !(item.kind == .bottom && style.hideBottom) else { return }
        guard let lane = fixedBusyUntil.firstIndex(where: { t >= $0 }) else { return }
        fixedBusyUntil[lane] = t + style.fixedDuration

        let width = measureTextWidth(item: item, fontSize: style.fontSize)
        let layer = makeDanmakuTextLayer(item: item, fontSize: style.fontSize,
                                         width: width, height: laneHeight,
                                         contentsScale: contentsScale)
        layer.position = CGPoint(x: container.bounds.width / 2, y: fixedCenterY(item.kind))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer.addSublayer(layer)
        CATransaction.commit()
        active.append(ActiveCell(layer: layer, kind: item.kind, bornAt: item.time))

        let remain = max(0.1, style.fixedDuration - lateness)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0]
        anim.keyTimes = [0, 0.8, 1]
        anim.duration = remain
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        layer.add(anim, forKey: "fnos.fixed")
    }

    private func remove(_ cell: ActiveCell) {
        cell.layer.removeAllAnimations()
        cell.layer.removeFromSuperlayer()
        active.removeAll { $0.layer === cell.layer }
    }

    private func clearAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in active {
            cell.layer.removeAllAnimations()
            cell.layer.removeFromSuperlayer()
        }
        CATransaction.commit()
        active.removeAll(keepingCapacity: true)
        rebuildLanes()
    }

    // MARK: 轨道 / 几何

    private var speed: Double { Double(container.bounds.width) / style.scrollDuration }

    private var laneHeight: CGFloat { style.fontSize * style.lineHeightFactor }
    private var laneBottom: CGFloat {
        min(container.bounds.height * style.areaRatio, container.bounds.height - 260)
    }

    private func rebuildLanes() {
        let count = max(1, min(20, Int((laneBottom - style.laneTop) / laneHeight)))
        laneReadyAt = Array(repeating: 0, count: count)
        fixedBusyUntil = Array(repeating: 0, count: count)
        nextLane = 0
    }

    private func availableLane(at t: Double) -> Int? {
        let count = laneReadyAt.count
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let lane = (nextLane + offset) % count
            if t >= laneReadyAt[lane] {
                nextLane = (lane + 1) % count
                return lane
            }
        }
        return nil
    }

    private func laneCenterY(_ lane: Int) -> CGFloat {
        style.laneTop + (CGFloat(lane) + 0.5) * laneHeight
    }

    private func fixedCenterY(_ kind: FNOSDanmakuLaneKind) -> CGFloat {
        if kind == .top { return style.laneTop + laneHeight / 2 }
        return min(max(container.bounds.height - 290 + style.offsetY, style.laneTop),
                   container.bounds.height - 260)
    }

    private func currentTime() -> TimeInterval { clock?.danmakuTime ?? lastTime }
}

// MARK: - 宿主 UIView + SwiftUI 桥接

final class FNOSDanmakuHostView: UIView {
    private(set) var engine: FNOSDanmakuRenderEngine!
    /// 弹幕容器：独立普通 UIView（无 layoutSubviews 重载）。
    /// v220 教训：cell 若 addSubview 到宿主自身，addSubview 触发宿主
    /// layoutSubviews→clearAll 死循环=发射即清屏。
    private let danmakuContainer = UIView()
    private var lastSize: CGSize = .zero
    private var emitter: CADisplayLink?
    private var lastEmit: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        danmakuContainer.isUserInteractionEnabled = false
        danmakuContainer.backgroundColor = .clear
        danmakuContainer.layer.masksToBounds = false
        addSubview(danmakuContainer)
        engine = FNOSDanmakuRenderEngine(container: danmakuContainer)
        engine.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        // 4Hz 低频发射泵——只查「有没有新弹幕到点」，位置由 CAAnimation 负责。
        let link = CADisplayLink(target: self, selector: #selector(emitTick))
        link.add(to: .main, forMode: .common)
        if #available(tvOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 4, preferred: 4)
        }
        emitter = link
    }

    deinit { emitter?.invalidate() }

    @objc private func emitTick() {
        let now = CACurrentMediaTime()
        guard now - lastEmit >= 0.25 else { return }
        lastEmit = now
        guard let clock = engine.clock else { return }
        // 播放/暂停/倍速 → CAAnimation 容器时间缩放（已在飞的动画平滑变速/冻结）
        engine.setRate(clock.playbackRate)
        engine.sync(mediaTime: clock.danmakuTime)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 容器始终跟住宿主尺寸（这一步不触发弹幕引擎）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        danmakuContainer.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
        // 只在尺寸真正变化时重建轨道——绝不在「子视图变化」时清屏
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
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
        view.engine.setTimeline(timeline)
        view.engine.setVisible(isVisible)
        context.coordinator.lastTimeline = timeline
        context.coordinator.lastStyle = style
        context.coordinator.lastVisible = isVisible
        return view
    }

    func updateUIView(_ uiView: FNOSDanmakuHostView, context: Context) {
        let c = context.coordinator
        uiView.engine.clock = clock
        if c.lastTimeline !== timeline {
            c.lastTimeline = timeline
            uiView.engine.setTimeline(timeline)
        }
        if c.lastStyle != style {
            c.lastStyle = style
            uiView.engine.updateStyle(style)
            // 弹幕速度设置通过 scrollDuration 影响新发射弹幕的 duration；
            // 容器 layer.speed 只由播放器倍速控制（emitTick），两者不冲突。
        }
        if c.lastVisible != isVisible {
            c.lastVisible = isVisible
            uiView.engine.setVisible(isVisible)
        }
        // 播放器时间由 FNOSDanmuView 的 sync 通过 clock 读取；这里只做到点发射
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
