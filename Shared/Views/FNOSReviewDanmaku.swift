//
// FNOSReviewDanmaku.swift
// v167: 详情页 Hero 评论弹幕浮层（豆瓣 + 番剧共用）。
// v170: 回退到 v168 TimelineView 实现（滚动正常）+ 字号 26。
// v171: 修闪烁——删 TimelineView 每帧重建（20fps 步进=闪烁根因）。
//   新底层 = 纯滚动：每泳道「文本链·双拷贝」+ repeatForever 纯线性 offset 动画，
//   CoreAnimation 只对整条链做 transform（60fps 平滑，期间文本零重绘）。
//   与 v169 的区别（v169 真机不滚动）：不用 preference 测宽（真机疑似不触发→静止）、
//   不用 drawingGroup，链宽用确定性估宽直接算——保证一定滚。
//   无缝循环：单份链估宽 ≥ 屏宽+150，行程 = 链宽+间距，复位瞬间第二拷贝与第一拷贝同位。
// 铁律不变：allowsHitTesting(false)、无 .focusable、无手势——不碰焦点引擎。
//

import SwiftUI
import UIKit

/// 链内条目尾间距（池估宽与 HStack spacing 共用同一常量，保证相位一致）
private let danmakuChainGap: CGFloat = 70

struct FNOSReviewDanmaku: View {
    /// 评论文本池（调用方已截断单行长度）
    let texts: [String]
    var laneCount: Int = 4
    /// 横向速度 pt/s
    var speed: CGFloat = 150
    /// 字号（v169: 21→26）
    var fontSize: CGFloat = 26
    /// v168 预热参数（签名兼容保留）。现行实现链首帧即在屏，此参数不再参与计算。
    var prewarmLanes: Int = 0

    var body: some View {
        if texts.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geo in
                let lanes = max(laneCount, 1)
                VStack(spacing: 0) {
                    ForEach(0..<lanes, id: \.self) { lane in
                        DanmakuMarqueeLane(
                            items: lanePool(lane, lanes: lanes, width: geo.size.width),
                            screenWidth: geo.size.width,
                            laneHeight: min(geo.size.height * 0.42, 470) / CGFloat(lanes),
                            speed: speed,
                            fontSize: fontSize
                        )
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
        }
    }

    /// 泳道文本分配 + 估宽补链：单份链估宽 ≥ 屏宽+150（两份拷贝任何相位盖满全屏）
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

    /// 精确文本宽度（建链补条用一次；用实际字体测量，与布局字体一致 → 循环复位无缝）
    private func estWidth(_ s: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return (s as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - 单泳道：文本链双拷贝 + 纯 offset 无缝滚动（无时间判定、无测量）

private struct DanmakuMarqueeLane: View {
    let items: [String]
    let screenWidth: CGFloat
    let laneHeight: CGFloat
    let speed: CGFloat
    let fontSize: CGFloat

    @State private var scrolling = false

    var body: some View {
        let passWidth = items.reduce(0) { $0 + estWidth($1) + danmakuChainGap }
        let travel = passWidth + danmakuChainGap
        HStack(spacing: danmakuChainGap) {
            // 双拷贝：offset 走完 travel 后复位，第二拷贝与第一拷贝同位 → 视觉无缝循环
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: danmakuChainGap) {
                    ForEach(items.indices, id: \.self) { i in
                        Text(items[i])
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.7), radius: 3, x: 1, y: 1)
                            .fixedSize()      // 锁行宽：长短变化不引起重排
                    }
                }
            }
        }
        .frame(width: screenWidth, height: laneHeight, alignment: .leading)
        .offset(x: scrolling ? -travel : 0)
        .animation(
            // 纯滚动：一次 linear + repeatForever，GPU 持续插值，无逐帧重算
            scrolling
                ? .linear(duration: Double(travel / speed)).repeatForever(autoreverses: false)
                : nil,
            value: scrolling
        )
        .onAppear { scrolling = true }   // 出现即滚；首帧链已从左缘铺开，不空屏
    }

    private func estWidth(_ s: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return (s as NSString).size(withAttributes: [.font: font]).width
    }
}
