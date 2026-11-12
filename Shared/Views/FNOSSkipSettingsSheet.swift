//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// MARK: - 片头片尾设置面板（v207 重做：实时位置 + 取当前位置 + 微调）

/// 播放器内「片头片尾」独立设置弹层。
///
/// v207 交互（用户规格：定位现在播放的位置做片头/片尾时间 + 微调）：
/// - 面板顶部实时显示当前播放位置（宿主进度回调持续更新）
/// - **确认键 = 取当前位置**写入本行（片头=绝对秒；片尾=距结尾剩余秒）；
///   捕捉视为「标记此处」，本次播放不再自动跳（下次播放起效）——
///   否则捕捉片尾的瞬间片尾开始点恰好等于当前位置，下一 tick 就会立即跳片尾，太突兀
/// - **左右键 / 触摸板滑动 = ±1 秒微调**（连按加速），直接改值——
///   若位置在新边界内会立即生效（自动 seek），v206「本集立即生效」语义保留
/// - 0 = 关闭该端跳过
///
/// 语义与飞牛 Web 播放器一致（逆向自 `/v/assets` 播放器 JS + 服务端实测，勿再假设）：
/// - 片头 = 片头结束**绝对秒数**（0 = 不跳）
/// - 片尾 = **距结尾剩余秒数**（0 = 不跳），片尾开始点 = 总时长 − 片尾秒数
/// - 合法区间 `0...600`
///
/// 数据流：**服务端是基座**（剧集级多端同步；2026-11-13 服务端直探实测：
/// 剧集写 parent_guid → 同集/同剧另一集 `play/info` 回读 `play_config` 全通）。
/// 改值经 `onChange` 交给宿主——宿主更新播放器内存里的生效值并防抖推
/// `POST /v/api/v1/play/setConfigByItem`。**电影实测服务端不回读 play_config
/// （parent_guid 为空）→ `canSync=false`，面板提示仅本次播放生效。**
struct FNOSSkipSettingsSheet: View {

    /// 当前生效值（片头结束绝对秒；nil = 关闭）
    let opening: Double?
    /// 当前生效值（距结尾剩余秒；nil = 关闭）
    let ending: Double?
    /// v207: 实时播放位置（宿主进度回调更新）
    let currentPosition: Double
    /// v207: 总时长（片尾开始点换算/显示用；0 = 未知）
    let totalDuration: Double
    /// v207: 服务端同步可用（剧集 + 已解析 parent_guid）；false = 电影等仅本次生效
    let canSync: Bool
    /// 关闭回调（宿主 overlay 模式）
    let onClose: () -> Void
    /// 改值回调：两参均为「nil = 关闭该端跳过」；宿主负责推服务端并更新生效值
    let onChange: (Double?, Double?) -> Void
    /// v207: 捕捉当前位置动作（isIntro）——宿主置对应 Skipped 标志（本次播放不自动跳）
    let onCapture: (Bool) -> Void

    @State private var openingValue: Double = 0
    @State private var endingValue: Double = 0

    /// v194: 连按加速（0.2s 内连续触发翻倍，最多 ×4：1s→2→4→8s）
    @State private var stepAccel: Double = 1
    @State private var lastStepMove: Date? = nil

    /// overlay 在 tvOS 不保证焦点自动移入（v173 教训）——appear 后程序化落首个控件
    @FocusState private var focusedControl: String?

    private let maxValue: Double = Double(FNOSNativeClient.maxSkipSeconds)

    var body: some View {
        VStack(spacing: 14) {
            Text("片头片尾")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            // 用户规格：定位到现在播放的位置（实时刷新）
            Text("当前位置 \(timeString(currentPosition))\(totalDuration > 1 ? " / \(timeString(totalDuration))" : "")")
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            captureRow(id: "opening", title: "片头结束")
            captureRow(id: "ending", title: "片尾保留")

            Text(bottomHint)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(26)
        .frame(width: 680)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            // v190/v193 同款：触摸板滑动桥（每实例协调器）——滑动增量直接回调
            FNOSPanelPanHostView(
                isEnabled: { focusedControl == "opening" || focusedControl == "ending" },
                onPanDelta: { dx in
                    let d = Double(dx) * 0.3   // 1px ≈ 0.3s（微调粒度，比 v206 的 1s/px 精细）
                    switch focusedControl {
                    case "opening":
                        setValue(isIntro: true, clampValue(openingValue + d))
                    case "ending":
                        setValue(isIntro: false, clampValue(endingValue + d))
                    default:
                        break
                    }
                }
            )
        )
        // Menu 键关闭（焦点在面板内时路由到此处；弹幕面板同款模式）
        .onExitCommand(perform: onClose)
        .onAppear {
            openingValue = opening ?? 0
            endingValue = ending ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if focusedControl == nil { focusedControl = "opening" }
            }
        }
    }

    private var bottomHint: String {
        let sync = canSync
            ? "设置自动同步到飞牛影视（Web / 手机）"
            : "此内容不支持服务端保存，设置仅本次播放生效"
        return "确认键 = 取当前位置 · 左右键 = ±1 秒微调 · 0 = 关闭\n\(sync)"
    }

    // MARK: - 捕捉行（官方 glass 按钮：确认键=取当前位置；onMoveCommand 左右=微调）

    private func captureRow(id: String, title: String) -> some View {
        let isFocused = focusedControl == id
        return Button {
            capturePosition(isIntro: id == "opening")
        } label: {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(valueText(id))
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                    if id == "ending", endingValue > 0, totalDuration > 1 {
                        Text("开始于 \(timeString(max(0, totalDuration - endingValue)))")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(width: 600)
        }
        // v208: 弃官方 .glass（聚焦态白底白字看不清）——FNOSBareButtonStyle 压系统焦点板 +
        // 自绘描边表焦点（用户规格「改成描边」；玻璃面板上禁半透明白填充的老规矩不破）
        .buttonStyle(FNOSBareButtonStyle())
        .focusEffectDisabled()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isFocused ? 1.0 : 0.28), lineWidth: isFocused ? 2.5 : 1)
        )
        .focused($focusedControl, equals: id)
        .onMoveCommand { direction in
            // v194: 连按加速（0.2s 内连续按翻倍，最多 ×4）
            let now = Date()
            let rapid = lastStepMove.map { now.timeIntervalSince($0) < 0.2 } ?? false
            stepAccel = rapid ? min(stepAccel * 2, 4) : 1
            lastStepMove = now
            let effective = Double(Int(stepAccel))   // 1s → 2 → 4 → 8
            switch direction {
            case .left:
                adjust(isIntro: id == "opening", delta: -effective)
            case .right:
                adjust(isIntro: id == "opening", delta: effective)
            default:
                break   // 上下交给焦点引擎在行间移动
            }
        }
    }

    // MARK: - 改值

    private func adjust(isIntro: Bool, delta: Double) {
        if isIntro {
            setValue(isIntro: true, clampValue(openingValue + delta))
        } else {
            setValue(isIntro: false, clampValue(endingValue + delta))
        }
    }

    private func setValue(isIntro: Bool, _ v: Double) {
        if isIntro {
            if v != openingValue { openingValue = v; commit() }
        } else {
            if v != endingValue { endingValue = v; commit() }
        }
    }

    /// 确认键：把当前播放位置写进本行（片头=绝对秒；片尾=距结尾剩余秒）
    private func capturePosition(isIntro: Bool) {
        let pos = max(0, currentPosition)
        if isIntro {
            setValue(isIntro: true, clampValue(pos))
            onCapture(true)
        } else if totalDuration > 1 {
            setValue(isIntro: false, clampValue(max(0, totalDuration - pos)))
            onCapture(false)
        }
    }

    private func commit() {
        onChange(
            openingValue > 0 ? openingValue : nil,
            endingValue > 0 ? endingValue : nil
        )
    }

    /// v207: 整数秒粒度（捕捉=精确到秒；v206 的 5 秒步进已弃）
    private func clampValue(_ v: Double) -> Double {
        min(max(v.rounded(), 0), maxValue)
    }

    private func valueText(_ id: String) -> String {
        if id == "opening" {
            return openingValue > 0 ? timeString(openingValue) : "关闭"
        }
        return endingValue > 0 ? "剩 \(timeString(endingValue))" : "关闭"
    }

    private func timeString(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
