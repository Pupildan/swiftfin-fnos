//
//  FNOSDanmakuRender.swift
//  飞牛影视 tvOS —— 弹幕渲染引擎（v220：DanmakuKit 式 CAAnimation 驱动）
//
//  来源：ATV-Bilibili-demo (yichengchen) 内置 DanmakuKit 的成熟方案 + 本机 FNOSKit。
//  为什么 v220 重写：v217-v219 用 CADisplayLink 在主线程每帧改 position.x，
//  主线程被播放器/UI 占用就掉帧→真机「卡段抖动更严重」。
//
//  v220 核心机制（丝滑的根本）：
//  1. 每条弹幕发射时挂一个 CABasicAnimation(position.x)，动画由 render server
//     进程独立插值，**主线程零逐帧位置计算** → 不受主线程负载影响。
//  2. 播放器周期回调（100/250ms）只负责「到点发射新弹幕」，不再管位置。
//  3. 播放/暂停/倍速用容器 layer.speed（Core Animation 原生时间缩放）。
//  4. 文本用异步光栅化（CGContext 先 stroke 再 fill），不会出现骨架字。
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

// MARK: - 异步光栅化 Layer（对标 DanmakuAsyncLayer）

private final class FNOSDanmakuAsyncLayer: CALayer {
    var drawText: ((_ ctx: CGContext, _ size: CGSize) -> Void)?

    override init() {
        super.init()
        contentsScale = UIScreen.main.scale
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func display() {
        guard let drawText else { contents = nil; return }
        let size = bounds.size
        let scale = contentsScale
        // 后台线程光栅化，不占主线程
        DispatchQueue.global(qos: .userInteractive).async {
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { ctx in
                drawText(ctx.cgContext, size)
            }
            DispatchQueue.main.async { self.contents = image.cgImage }
        }
    }
}

// MARK: - 弹幕 Cell（UIView + 异步 layer）

private final class FNOSDanmakuCell: UIView {
    let item: FNOSDanmakuItem
    let lane: Int
    let style: FNOSDanmakuStyle
    var textWidth: CGFloat = 0
    /// 媒体时间轴上的发射时刻，用于回收（不依赖墙钟，暂停/倍速都对）
    var bornAt: Double = 0

    override class var layerClass: AnyClass { FNOSDanmakuAsyncLayer.self }

    init(item: FNOSDanmakuItem, lane: Int, style: FNOSDanmakuStyle, width: CGFloat) {
        self.item = item
        self.lane = lane
        self.style = style
        self.textWidth = width
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: style.fontSize * style.lineHeightFactor))
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let asyncLayer = layer as! FNOSDanmakuAsyncLayer
        asyncLayer.contentsScale = UIScreen.main.scale
        asyncLayer.drawText = { [weak self] ctx, size in
            guard let self else { return }
            self.draw(into: ctx, size: size)
        }
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// CGContext 正确画法：先 stroke 描边，再 fill 填充（不会出骨架字）
    private func draw(into ctx: CGContext, size: CGSize) {
        let text = NSString(string: item.text)
        let font = UIFont.boldSystemFont(ofSize: style.fontSize)
        let textColor = UIColor(
            red: CGFloat((item.rgb >> 16) & 0xFF) / 255,
            green: CGFloat((item.rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(item.rgb & 0xFF) / 255, alpha: 1
        )
        ctx.setLineWidth(2.5)
        ctx.setLineJoin(.round)
        ctx.setTextDrawingMode(.stroke)
        NSString(string: item.text).draw(at: .zero, withAttributes: [
            .font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.85)
        ])
        ctx.setTextDrawingMode(.fill)
        text.draw(at: .zero, withAttributes: [.font: font, .foregroundColor: textColor])
    }
}

// MARK: - 渲染引擎（CAAnimation 驱动）

@MainActor
final class FNOSDanmakuRenderEngine {

    weak var clock: FNOSDanmakuClock?
    private let container: UIView
    private var style: FNOSDanmakuStyle
    private var timeline: FNOSDanmakuTimeline?
    private var spawnIndex = 0
    private var active: [FNOSDanmakuCell] = []
    private var laneReadyAt: [Double] = []
    private var fixedBusyUntil: [Double] = []
    private var nextLane = 0
    private var lastTime: Double = 0
    private var isVisible = true

    init(container: UIView, style: FNOSDanmakuStyle = FNOSDanmakuStyle()) {
        self.container = container
        self.style = style
        container.layer.speed = 1
        rebuildLanes()
    }

    // MARK: 对外接口（与 FNOSDanmuView 对接）

    func load(timeline: FNOSDanmakuTimeline?) {
        clearAll()
        self.timeline = timeline
        spawnIndex = timeline.map { $0.lowerBound(currentTime() + 0.001) } ?? 0
        lastTime = currentTime()
        // 换集/seek 时把「此刻应在屏上」的一批弹幕补发射出去（带 progress 偏移）
        emitFrom(currentTime(), backfill: true)
    }

    /// 播放器周期回调调用（100/250ms）——只负责到点发射，不算位置
    func sync(mediaTime: Double) {
        guard timeline != nil else { return }
        if abs(mediaTime - lastTime) > 0.8 {
            clearAll()
            spawnIndex = timeline!.lowerBound(mediaTime)
            emitFrom(mediaTime, backfill: true)
        }
        lastTime = mediaTime
        emitFrom(mediaTime, backfill: false)
        // 回收：滚动弹幕跑完时长 / 固定弹幕超过停留时长
        let expired = active.filter { cell in
            let lifespan = cell.item.kind == .scroll ? style.scrollDuration : style.fixedDuration
            return mediaTime - cell.bornAt > lifespan + 0.5
        }
        for cell in expired { remove(cell) }
    }

    /// v220: 播放/暂停/倍速——改容器 layer.speed，Core Animation 原生时间缩放，
    /// 不用重新计算任何位置，也不会打断正在跑的动画。
    func setRate(_ rate: Double) {
        container.layer.speed = Float(max(0, rate))
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
            for cell in active where cell.item.kind == .bottom { remove(cell) }
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
        guard item.kind != .bottom || !style.hideBottom else { return }
        let width = measureWidth(item)
        guard let lane = availableLane(at: t) else { return }
        laneReadyAt[lane] = t + Double((width + style.laneMargin) / speed)

        let cell = FNOSDanmakuCell(item: item, lane: lane, style: style, width: width)
        cell.bornAt = item.time
        let y = laneCenterY(lane)
        let startX = screenWidth + width / 2 - speed * CGFloat(lateness)
        cell.center = CGPoint(x: startX, y: y)
        container.addSubview(cell)
        active.append(cell)

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
        cell.layer.add(anim, forKey: "fnos.scroll")
    }

    private func shootFixed(_ item: FNOSDanmakuItem, at t: Double, lateness: Double) {
        guard active.count < style.maxOnScreen else { return }
        guard !(item.kind == .bottom && style.hideBottom) else { return }
        guard let lane = fixedBusyUntil.firstIndex(where: { t >= $0 }) else { return }
        fixedBusyUntil[lane] = t + style.fixedDuration

        let width = measureWidth(item)
        let cell = FNOSDanmakuCell(item: item, lane: lane, style: style, width: width)
        cell.bornAt = item.time
        cell.center = CGPoint(x: container.bounds.width / 2, y: fixedCenterY(item.kind))
        container.addSubview(cell)
        active.append(cell)

        let remain = max(0.1, style.fixedDuration - lateness)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0]
        anim.keyTimes = [0, 0.8, 1]
        anim.duration = remain
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        cell.layer.add(anim, forKey: "fnos.fixed")
    }

    private func remove(_ cell: FNOSDanmakuCell) {
        cell.layer.removeAllAnimations()
        cell.removeFromSuperview()
        active.removeAll { $0 === cell }
    }

    private func clearAll() {
        for cell in active {
            cell.layer.removeAllAnimations()
            cell.removeFromSuperview()
        }
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

    private func measureWidth(_ item: FNOSDanmakuItem) -> CGFloat {
        let font = UIFont.boldSystemFont(ofSize: style.fontSize)
        return ceil(NSString(string: item.text).size(withAttributes: [.font: font]).width) + 8
    }

    private func currentTime() -> TimeInterval { clock?.danmakuTime ?? lastTime }
}

// MARK: - 宿主 UIView + SwiftUI 桥接

final class FNOSDanmakuHostView: UIView {
    private(set) var engine: FNOSDanmakuRenderEngine!
    private var emitter: CADisplayLink?
    private var lastEmit: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        engine = FNOSDanmakuRenderEngine(container: self)
        // v220: 4Hz 低频发射泵——只查「有没有新弹幕到点」，位置由 CAAnimation 负责。
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
        engine.layoutChanged()
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

private extension FNOSDanmakuHostView {
    func setTimeline(_ timeline: FNOSDanmakuTimeline?) { engine.load(timeline: timeline) }
    func setVisible(_ visible: Bool) { engine.setVisible(visible) }
}
