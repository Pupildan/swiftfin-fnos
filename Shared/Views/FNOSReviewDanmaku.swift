//
// FNOSReviewDanmaku.swift
// v167: 详情页 Hero 评论弹幕浮层（豆瓣 + 番剧共用）。
// v169 重写（用户指令三条）：
//   1) 字号 21→26 加大；
//   2) 弃用全部时间判定（删 TimelineView / Date 逐帧推导——20fps 步进=闪烁根因）。
//      新底层 = 纯滚动：每泳道一条「文本链·双拷贝」+ repeatForever 线性 offset 动画，
//      CoreAnimation 只对已光栅化的整链做 transform（60fps、期间零重排零重绘）；
//      链身 .drawingGroup() 强制 GPU 离屏渲染（用户指定）；
//      每个 Text .fixedSize() 锁定行宽，长短变化不引起行宽突变。
//   3) 无缝循环相位：单份链估宽 ≥ 屏宽+150（两份拷贝任何相位盖满全屏），
//      行程 = 链宽+尾间距，复位瞬间第二拷贝与第一拷贝逐像素同位 → 视觉无缝。
// 铁律不变：allowsHitTesting(false)、无 .focusable、无手势——不碰焦点引擎。
//

import SwiftUI

/// 泳道间/链内条目尾间距（池估宽与 HStack spacing 共用同一常量，保证相位计算一致）
private let danmakuChainGap: CGFloat = 70

struct FNOSReviewDanmaku: View {
    /// 评论文本池（调用方已截断单行长度）
    let texts: [String]
    var laneCount: Int = 4
    /// 横向速度 pt/s
    var speed: CGFloat = 150
    /// 字号（v169: 21→26 加大）
    var fontSize: CGFloat = 26
    /// v168 预热参数（签名兼容保留）。v169 起无时间判定：链首帧即在屏，
    /// 此参数不再参与计算；番剧/豆瓣调用点均无需改动。
    var prewarmLanes: Int = 0

    var body: some View {
        if texts.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geo in
                let lanes = max(laneCount, 1)
                VStack(spacing: 0) {
                    ForEach(0..<lanes, id: \.self) { lane in
                        DanmakuLane(
                            items: lanePool(lane, lanes: lanes, width: geo.size.width),
                            width: geo.size.width,
                            bandHeight: min(geo.size.height * 0.42, 470) / CGFloat(lanes),
                            speed: speed,
                            fontSize: fontSize
                        )
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // GPU 离屏渲染做在每泳道的链身（DanmakuLane 内 .drawingGroup()）：
            // 链光栅化一次，offset 只动纹理图层——若整带再包一层 drawingGroup，
            // 移动中的泳道会迫使带级纹理逐帧重栅格，恰好毁掉离屏收益。
            .allowsHitTesting(false)
        }
    }

    /// 泳道文本分配 + 估宽补链：单份链估宽 ≥ 屏宽+150（两份拷贝任何相位盖满全屏）。
    /// 估宽宁大勿小（CJK 1.05em / ASCII 0.65em 偏保守），只决定复制多少条，不做时间判定。
    private func lanePool(_ lane: Int, lanes: Int, width: CGFloat) -> [String] {
        var pool = stride(from: lane, to: texts.count, by: lanes).map { texts[$0] }
        guard !pool.isEmpty else { return [] }
        let target = width + 150
        var w: CGFloat = 0
        for s in pool { w += estWidth(s) + danmakuChainGap }
        var idx = 0
        while w < target {
            let t = pool[idx % pool.count]
            pool.append(t)
            w += estWidth(t) + danmakuChainGap
            idx += 1
            if pool.count >= 80 { break }
        }
        return pool
    }

    /// 估算文本宽度（仅用于建链补条，不参与任何每帧计算）
    private func estWidth(_ s: String) -> CGFloat {
        var w: CGFloat = 0
        for ch in s {
            let v = ch.unicodeScalars.first?.value ?? 0
            w += (v >= 0x2E80) ? fontSize * 1.05 : fontSize * 0.65
        }
        return w
    }
}

// MARK: - 单泳道：文本链双拷贝 + 纯 offset 无缝滚动

private struct DanmakuLane: View {
    let items: [String]
    let width: CGFloat
    let bandHeight: CGFloat
    let speed: CGFloat
    let fontSize: CGFloat

    @State private var passWidth: CGFloat = 0   // 单份链实测宽（建链时估宽可能偏差，以实测为准）
    @State private var running = false

    var body: some View {
        if items.isEmpty {
            Color.clear
                .frame(width: width, height: bandHeight)
        } else {
            HStack(spacing: danmakuChainGap) {
                // 双拷贝：复位时第二拷贝与第一拷贝同位 → 视觉无缝循环
                ForEach(0..<2, id: \.self) { copy in
                    HStack(spacing: danmakuChainGap) {
                        ForEach(items.indices, id: \.self) { i in
                            Text(items[i])
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.7), radius: 3, x: 1, y: 1)
                                .fixedSize()      // 锁行宽：长短变化不引起重排（用户指定）
                        }
                    }
                    .background {
                        if copy == 0 {
                            GeometryReader { g in
                                Color.clear.preference(DanmakuPassWidthKey.self, g.size.width)
                            }
                        }
                    }
                }
            }
            .drawingGroup()               // 链身离屏光栅化：滚动期间文本永不重绘
            .offset(x: running ? -(passWidth + danmakuChainGap) : 0)
            .animation(
                // 纯滚动，无时间判定：一次 linear + repeatForever，GPU 持续插值
                running
                    ? .linear(duration: Double((passWidth + danmakuChainGap) / speed))
                        .repeatForever(autoreverses: false)
                    : nil,
                value: running
            )
            .frame(width: width, height: bandHeight, alignment: .leading)
            .onPreferenceChange(DanmakuPassWidthKey.self) { w in
                // 单份链实测宽到位即开滚（一次性；此后动画自行 repeatForever，无任何时间逻辑）
                guard w > 0, !running else { return }
                passWidth = w
                running = true
            }
        }
    }
}

private struct DanmakuPassWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
