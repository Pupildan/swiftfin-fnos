//
// FNOSReviewDanmaku.swift
// v167: 详情页 Hero 评论弹幕浮层——评论文本从右向左匀速推过，循环取池。
// 铁律：allowsHitTesting(false)、无 .focusable、无任何手势/命令——纯展示，
// 绝不参与焦点引擎（首页焦点战役的教训不许带进详情页）。
//

import SwiftUI

struct FNOSReviewDanmaku: View {
    /// 评论文本池（调用方已截断单行长度）
    let texts: [String]
    var laneCount: Int = 4
    /// 横向速度 pt/s
    var speed: CGFloat = 150
    /// 同泳道重入间隔（秒）；0 = 按屏宽自动：前一条完全出画后才放下一条
    var laneInterval: Double = 0
    var fontSize: CGFloat = 21
    /// v168: 打开页面时预热的泳道数（0=旧行为，全部从右侧慢慢进入）。
    /// 豆瓣页传 2：首帧前 2 道已有弹幕在屏，杜绝「打开后前几秒空白」被误判为没有弹幕。
    /// 默认 0 → 番剧页调用零改动、零行为变化。
    var prewarmLanes: Int = 0

    @State private var startDate = Date()

    var body: some View {
        if texts.isEmpty {
            EmptyView()
        } else {
            TimelineView(.periodic(from: startDate, by: 1.0 / 20)) { context in
                GeometryReader { geo in
                    let shots = makeShots(
                        now: context.date,
                        width: geo.size.width,
                        height: geo.size.height
                    )
                    ForEach(shots) { shot in
                        Text(shot.text)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.7), radius: 3, x: 1, y: 1)
                            .position(x: shot.cx, y: shot.cy)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private struct Shot: Identifiable {
        let id: Int
        let text: String
        let cx: CGFloat
        let cy: CGFloat
    }

    // MARK: - 运动计算（每帧确定性推导，无状态机、无完成回调）

    private func makeShots(now: Date, width: CGFloat, height: CGFloat) -> [Shot] {
        guard !texts.isEmpty else { return [] }

        let maxW = texts.map(estWidth).max() ?? 0
        var interval = Double((width + maxW) / speed + 0.8)
        if laneInterval > 0 { interval = laneInterval }
        let maxDur = Double(width + maxW) / Double(speed) + 0.5
        let lanes = max(laneCount, 1)
        let stag = interval / Double(lanes)
        // v168 预热：时钟前移 prewarmLanes 个泳道间隔 → 首帧前 N 道已有弹幕在屏
        let elapsed = now.timeIntervalSince(startDate) + Double(max(prewarmLanes, 0)) * stag
        guard elapsed > 0 else { return [] }

        // 顶部弹幕带：只占 hero 上部 42%（避开左下标题/按钮区与右下主演区）
        let band = min(height * 0.42, 470)
        let laneH = band / CGFloat(lanes)

        var shots: [Shot] = []
        for lane in 0..<lanes {
            let laneOff = Double(lane) * stag
            // 跳过早已出画的历史 shot（长驻页面不随时间退化）
            var j = 0
            if elapsed - laneOff > maxDur {
                j = max(0, Int((elapsed - laneOff - maxDur) / interval))
            }
            while true {
                let t0 = Double(j) * interval + laneOff
                guard t0 <= elapsed else { break }
                let age = elapsed - t0
                let k = lane + j * lanes
                let text = texts[k % texts.count]
                let w = estWidth(text)
                let leftX = width - CGFloat(age) * speed
                if leftX > -w {
                    shots.append(Shot(
                        id: k,
                        text: text,
                        cx: leftX + w / 2,
                        cy: laneH * (CGFloat(lane) + 0.5) + 8
                    ))
                }
                j += 1
                if j > 10_000 { break }   // 防御性上限
            }
        }
        return shots
    }

    /// 估算文本宽度：CJK 全角按 1.0em，ASCII 按 0.55em（弹幕定位只需近似）
    private func estWidth(_ s: String) -> CGFloat {
        var w: CGFloat = 0
        for ch in s {
            let v = ch.unicodeScalars.first?.value ?? 0
            w += (v >= 0x2E80) ? fontSize : fontSize * 0.55
        }
        return w
    }
}
