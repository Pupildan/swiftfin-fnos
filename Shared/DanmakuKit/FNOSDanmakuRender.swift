//
//  FNOSDanmakuRender.swift
//  飞牛影视 tvOS —— 弹幕渲染引擎（v223：倍速/回收/显示区域/行距四项实测修复）
//
//  来源：ATV-Bilibili-demo (yichengchen) 内置 DanmakuKit 的成熟方案 + 本机 FNOSKit。
//
//  版本历史教训：
//  - v217-v219：CADisplayLink 主线程每帧改 position.x → 主线程被占用就掉帧卡顿。
//  - v220：addSubview 到宿主自身 → layoutSubviews 清屏死循环 → 全不显示（v221 修复）。
//  - v221：诊断证明发射正常但无像素 → 自定义异步光栅化 layer 不上屏。
//  - v222：内容回退 CATextLayer（可见），移动保留 CABasicAnimation。实测弹幕出来了。
//  - v222 实测四 bug → v223（本版）：
//    1. 倍速弹幕消失：layer.speed 变化重映射动画时间轴（进度跳变到终点，
//       fillMode forwards 定格在出屏）→ 改为「定格视觉位置+按新倍速重挂动画」，
//       layer.speed 恒为 1 不再动。暂停=定格无动画；恢复=从定格位置重挂。
//    2. 左边突然消失：回收寿命 12s < 动画实际时长（屏宽+文本宽）/速度≈14s，
//       弹幕没滚出左边缘就被删 → 回收改为按「动画走完的媒体时刻」(expireAt)。
//    3. 显示区域滑块 75% 封顶 → 放开到 100%（用户指令，解除 260pt 字幕保护）。
//    4. 行距 1.4→1.6；默认顶部 110→60（更靠屏幕上方）。
//    附：seek 跳变阈值随倍速放大 max(0.8, 0.5×rate)，4x 时不再误判清屏。
//
//  丝滑机制（不变）：CABasicAnimation(position.x) 由 render server 独立插值，
//  主线程零逐帧位置计算；周期回调只管到点发射。
//
//  ⚠️ 不碰 FNOSDanmuEngine.sync/anchor 铁律（v130 教训）——那套只决定「何时发射」。
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
    /// v223: 1.4→1.6 行距加大（用户实测太挤）
    var lineHeightFactor: CGFloat = 1.6
    var laneMargin: CGFloat = 16
    var maxOnScreen: Int = 300
    var hideBottom: Bool = false
    /// v223: 110→60 默认位置更靠屏幕上方（用户要求）
    var laneTop: CGFloat { 60 + offsetY }
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
    /// v222: 在屏弹幕（CATextLayer + 媒体时间轴上的动画终点，用于回收）
    private struct ActiveCell {
        let layer: CATextLayer
        let kind: FNOSDanmakuLaneKind
        /// 动画走完的媒体时刻（=发射媒体时刻 + 剩余路程/几何速度，与倍速无关）
        var expireAt: Double
    }
    private var active: [ActiveCell] = []
    private var laneReadyAt: [Double] = []
    private var fixedBusyUntil: [Double] = []
    private var nextLane = 0
    private var lastTime: Double = 0
    private var isVisible = true
    private var diagTick = 0
    /// v223: 当前倍速（0=暂停）；变速用「定格+重挂动画」而不是 layer.speed
    private var currentRate: Double = 1
    /// v225: 发射诊断（每 2s 随诊断行清零）
    private var diagSpawned = 0
    private var diagDroppedLate = 0
    private var diagMaxLateness: Double = 0

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
        emitFrom(currentTime())
    }

    /// 播放器周期回调调用（100/250ms）——只负责到点发射，不算位置
    func sync(mediaTime: Double) {
        guard let timeline else { return }
        // 渲染诊断（4Hz 泵 × 8 ≈ 2s 节流）
        diagTick += 1
        if diagTick % 8 == 0 {
            FNOSDiagLog.send("弹幕渲染: 在屏\(active.count) 发射点\(spawnIndex)/\(timeline.items.count) t=\(Int(mediaTime)) lanes=\(laneReadyAt.count) rate=\(currentRate) size=\(Int(container.bounds.width))x\(Int(container.bounds.height)) 发=\(diagSpawned) 迟丢=\(diagDroppedLate) 最大迟=\(String(format: "%.1f", diagMaxLateness))s")
            diagSpawned = 0; diagDroppedLate = 0; diagMaxLateness = 0
        }
        if abs(mediaTime - lastTime) > max(1.2, 0.6 * currentRate) {
            // seek / 跳集：阈值随倍速放大；倍速下播放器 position 偶发抖动不再误判清屏
            clearAll()
            spawnIndex = timeline.lowerBound(mediaTime)
            emitFrom(mediaTime)
        }
        lastTime = mediaTime
        emitFrom(mediaTime)
        // v223 回收：按「动画走完的媒体时刻」判——旧版固定 12s 寿命比动画实际时长
        // （屏宽+文本宽）/速度 短，弹幕还没滚出左边缘就被删 = 「左边突然消失」
        let expired = active.filter { mediaTime > $0.expireAt + 0.5 }
        for cell in expired { remove(cell) }
    }

    /// 播放/暂停/倍速——v223 全部用「定格视觉位置 + 重挂动画」实现，不再动 layer.speed。
    /// 原因（v222 实测 bug1）：layer.speed 变化会重映射动画时间轴（进度瞬间跳变），
    /// 切倍速时在飞弹幕直接跳到终点（fillMode forwards 定格在出屏位置）→ 弹幕全消失。
    func setRate(_ rate: Double) {
        let r = max(0, rate)
        guard r != currentRate else { return }
        currentRate = r
        // 1) 把所有在飞弹幕的当前视觉位置定格为模型位置，撤掉旧动画
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in active {
            if let p = cell.layer.presentation() {
                cell.layer.position = p.position
                cell.layer.opacity = p.opacity
            }
            cell.layer.removeAllAnimations()
        }
        CATransaction.commit()
        // 2) 暂停：停在这里（无动画；媒体时钟冻结，既不发射也不回收）
        guard r > 0 else { return }
        // 3) 恢复/变速：从定格位置按新倍速重挂动画
        let nowM = currentTime()
        let geo = geoSpeed
        for i in active.indices {
            let layer = active[i].layer
            let width = layer.bounds.width
            if active[i].kind == .scroll {
                let x = layer.position.x
                let remaining = x + width / 2
                guard remaining > 1 else { continue }   // 已出屏，等回收
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = x
                anim.toValue = -width / 2
                // 墙钟时长 = 剩余路程/(几何速度×倍速)；媒体时长恒= 剩余路程/几何速度
                anim.timingFunction = CAMediaTimingFunction(name: .linear)   // v224 匀速
                anim.duration = max(0.1, Double(remaining) / (geo * r))
                anim.beginTime = CACurrentMediaTime()
                anim.isRemovedOnCompletion = false
                anim.fillMode = .forwards
                layer.add(anim, forKey: "fnos.scroll")
                active[i].expireAt = nowM + Double(remaining) / geo
            } else {
                let remainM = active[i].expireAt - nowM
                guard remainM > 0.1 else { continue }
                let anim = CAKeyframeAnimation(keyPath: "opacity")
                anim.values = [1, 1, 0]
                anim.keyTimes = [0, 0.8, 1]
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
                anim.duration = remainM / r
                anim.beginTime = CACurrentMediaTime()
                anim.isRemovedOnCompletion = false
                anim.fillMode = .forwards
                layer.add(anim, forKey: "fnos.fixed")
            }
        }
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
            emitFrom(currentTime())
        } else {
            rebuildLanes()
        }
    }

    func layoutChanged() {
        clearAll()
        emitFrom(currentTime())
    }

    // MARK: 发射逻辑

    private func emitFrom(_ t: Double) {
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
            // v225: 迟到弹幕一律丢弃——弹幕只会从屏幕右边缘外滑入，绝不屏内闪现。
            // seek/跳变/主线程卡顿后的积压弹幕若照常发射，起点已算到屏内 = 「凭空冒出一批」
            if lateness > 0.5 {
                diagDroppedLate += 1
                diagMaxLateness = max(diagMaxLateness, lateness)
                continue
            }
            diagSpawned += 1
            diagMaxLateness = max(diagMaxLateness, lateness)
            switch item.kind {
            case .scroll: shootScroll(item, at: t, lateness: lateness, screenWidth: screenWidth)
            case .top, .bottom: shootFixed(item, at: t, lateness: lateness)
            }
        }
    }

    private func shootScroll(_ item: FNOSDanmakuItem, at t: Double, lateness: Double, screenWidth: CGFloat) {
        guard active.count < style.maxOnScreen else { return }
        let width = measureTextWidth(item: item, fontSize: style.fontSize)
        guard let lane = availableLane(at: t) else { return }
        laneReadyAt[lane] = t + Double((width + style.laneMargin) / geoSpeed)

        let layer = makeDanmakuTextLayer(item: item, fontSize: style.fontSize,
                                         width: width, height: laneHeight,
                                         contentsScale: contentsScale)
        let y = laneCenterY(lane)
        let startX = screenWidth + width / 2 - geoSpeed * CGFloat(lateness)
        layer.position = CGPoint(x: startX, y: y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer.addSublayer(layer)
        CATransaction.commit()
        // 剩余路程 = 从 startX 到完全出屏 (x = -width/2)
        let remaining = Double(startX + width / 2)
        active.append(ActiveCell(layer: layer, kind: item.kind,
                                 expireAt: t + remaining / geoSpeed))
        // 墙钟时长 = 剩余路程/(几何速度×当前倍速)；媒体时长恒= 剩余路程/几何速度
        let duration = max(0.1, remaining / (geoSpeed * max(0.1, currentRate)))
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = startX
        anim.toValue = -width / 2
        // ⚠️ v224 关键修复：CABasicAnimation 默认 timing function 是 ease-in-ease-out，
        // 不是匀速！弹幕启动贴着右边缘几乎不动→加速划过→左边减速——
        // 用户感知=「从右边闪现出来，没有滚动的过程」。弹幕必须 linear 匀速。
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
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
        let remain = max(0.1, style.fixedDuration - lateness)
        active.append(ActiveCell(layer: layer, kind: item.kind, expireAt: t + remain))

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0]
        anim.keyTimes = [0, 0.8, 1]
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = remain / max(0.1, currentRate)
        anim.beginTime = CACurrentMediaTime()
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

    /// 几何速度（pt/媒体秒）——横穿屏宽耗时 scrollDuration，与播放倍速无关
    private var geoSpeed: Double { Double(container.bounds.width) / style.scrollDuration }

    private var laneHeight: CGFloat { style.fontSize * style.lineHeightFactor }
    /// v223: 显示区上限=屏高×areaRatio（用户要求滑块可到 100%，解除原 260pt 字幕保护区）
    private var laneBottom: CGFloat {
        container.bounds.height * style.areaRatio
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
        // v223: 底部固定弹幕贴底显示（原 290/260 字幕保护区已按用户要求解除）
        return max(style.laneTop + laneHeight / 2, container.bounds.height - 100 + style.offsetY)
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
            // 弹幕速度设置通过 scrollDuration 影响发射节奏与动画时长；
            // 播放倍速由 setRate「定格+重挂动画」处理，两者不冲突。
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
