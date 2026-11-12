//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// MARK: - 片头片尾设置面板（v206，与 FNOSDanmuSettingsSheet 同款玻璃风格）

/// 播放器内「片头片尾」独立设置弹层。
///
/// 语义与飞牛 Web 播放器一致（逆向自 `/v/assets` 播放器 JS，勿再假设）：
/// - 片头 = 片头结束**绝对秒数**（0 = 不跳）
/// - 片尾 = **距结尾剩余秒数**（0 = 不跳），片尾开始点 = 总时长 − 片尾秒数
/// - 合法区间 `0...600`，步进 5 秒
///
/// 数据流：**服务端是基座**（多端同步），本面板改值后经 `onChange` 交给宿主——
/// 宿主更新播放器内存里的生效值（本端立即生效）并防抖推
/// `POST /v/api/v1/play/setConfigByItem`（挂在剧集级 parent_guid 上）。
/// 面板自身不落任何本地存储，避免与他端修改产生脏数据。
struct FNOSSkipSettingsSheet: View {

    /// 服务端当前值（play_config → play_config），nil = 未设置（显示「关闭」）
    let opening: Double?
    let ending: Double?
    /// 关闭回调（宿主 overlay 模式，与弹幕设置面板一致）
    let onClose: () -> Void
    /// 改值回调：两参均为「nil = 关闭该端跳过」；宿主负责推服务端并更新生效值
    let onChange: (Double?, Double?) -> Void

    @State private var openingValue: Double = 0
    @State private var endingValue: Double = 0

    /// v194: 连按/连滑加速（与弹幕面板同款：0.2s 内连续触发翻倍，最多 ×2）
    @State private var sliderAccel: Double = 1
    @State private var lastSliderMove: Date? = nil

    /// overlay 在 tvOS 不保证焦点自动移入（v173 教训）——appear 后程序化落首个控件
    @FocusState private var focusedControl: String?

    private let step: Double = 5
    private let maxValue: Double = Double(FNOSNativeClient.maxSkipSeconds)

    var body: some View {
        VStack(spacing: 16) {
            Text("片头片尾")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            sliderRow(id: "opening", title: "跳过片头", value: $openingValue)
            sliderRow(id: "ending", title: "跳过片尾", value: $endingValue)

            Text("片尾按「距结尾剩余秒数」计算 · 设置同步到飞牛影视（Web / 手机）")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(26)
        .frame(width: 680)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            // v190/v192 同款：触摸板/转盘滑动桥——滑动增量直接回调滑块绑定
            FNOSPanelPanHostView(
                isEnabled: { focusedControl == "opening" || focusedControl == "ending" },
                onPanDelta: { dx in
                    let d = Double(dx) * 1.0   // 1px ≈ 1s（量程 600s，满幅滑动≈走完）
                    switch focusedControl {
                    case "opening":
                        let v = clampValue(openingValue + d)
                        if v != openingValue { openingValue = v; commit() }
                    case "ending":
                        let v = clampValue(endingValue + d)
                        if v != endingValue { endingValue = v; commit() }
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

    // MARK: - 滑块行（弹幕面板 sliderRow 同款：自绘 + focusable + onMoveCommand 步进）

    private func sliderRow(id: String, title: String, value: Binding<Double>) -> some View {
        let isFocused = focusedControl == id
        let fraction = min(max(value.wrappedValue / maxValue, 0), 1)
        let knob: CGFloat = isFocused ? 24 : 18
        return HStack(spacing: 18) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .frame(height: 8)
                    Capsule()
                        .fill(.white.opacity(isFocused ? 1.0 : 0.7))
                        .frame(width: max(8, geo.size.width * fraction), height: 8)
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .offset(x: max(0, min(geo.size.width - knob, geo.size.width * fraction - knob / 2)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 38)
            .contentShape(Rectangle())
            .focusable(true)
            .focused($focusedControl, equals: id)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                // v194: 连按加速（弹幕面板同款）
                let now = Date()
                let rapid = lastSliderMove.map { now.timeIntervalSince($0) < 0.2 } ?? false
                sliderAccel = rapid ? min(sliderAccel * 2, 2) : 1
                lastSliderMove = now
                let effective = step * sliderAccel
                switch direction {
                case .left:
                    value.wrappedValue = clampValue(value.wrappedValue - effective)
                case .right:
                    value.wrappedValue = clampValue(value.wrappedValue + effective)
                default:
                    break   // 上下交给焦点引擎在行间移动
                }
                commit()
            }
            Text(displayText(value.wrappedValue))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(width: 110, alignment: .trailing)
        }
    }

    // MARK: - 数值

    private func clampValue(_ v: Double) -> Double {
        min(max((v / step).rounded() * step, 0), maxValue)
    }

    private func displayText(_ v: Double) -> String {
        v > 0 ? "\(Int(v)) 秒" : "关闭"
    }

    /// 改值 → 通知宿主（宿主更新生效值 + 防抖推服务端）
    private func commit() {
        onChange(
            openingValue > 0 ? openingValue : nil,
            endingValue > 0 ? endingValue : nil
        )
    }
}
