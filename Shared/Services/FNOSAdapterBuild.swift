//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, can be obtained one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// 飞牛影视（fnOS）适配版本标识。
///
/// 每次交付新 ipa 前递增 `version`，用户可在
/// 「设置 → 关于本应用」与「设置 → 高级」核对更新是否生效。
enum FNOSAdapterBuild {

    /// 适配版本号（递增）
    static let version = "v223"

    /// 本版主要变更摘要
    static let changes = "v223:v222 实测四项修复。①倍速弹幕消失:layer.speed 变化会重映射 CA 动画时间轴(进度瞬间跳变到终点,fillMode forwards 定格在出屏位置)→改「定格视觉位置+按新倍速重挂动画」,layer.speed 恒为1;暂停=定格无动画,恢复=从定格位置重挂;seek 跳变阈值随倍速放大(4x 不再误判清屏)。②弹幕左侧突然消失:回收寿命固定12s<动画实际时长(屏宽+文本宽)/速度≈14s,弹幕没滚出左边缘就被删→回收改按「动画走完的媒体时刻」expireAt,与倍速无关。③显示区域滑块 75% 封顶→放开到 100%(用户指令,解除 260pt 字幕保护死规则),引擎 laneBottom=屏高×area。④行距 1.4→1.6;默认顶部 110→60(更靠屏幕上方)。"
}
