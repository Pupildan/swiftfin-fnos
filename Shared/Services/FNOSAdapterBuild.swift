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
    static let version = "v225"

    /// 本版主要变更摘要
    static let changes = "v225:堵死弹幕屏内闪现的最后一个来源——v224 的 linear 匀速修复解决「贴边不动」后,还有一类闪现来自「迟到弹幕」:seek/跳变/主线程卡顿后积压的弹幕按 lateness 折算起点,起点已算到屏内,发射即凭空冒出一批(=用户看到的「清零后重新加载一批」)。修复:迟到超 0.5s 的弹幕一律丢弃(spawnIndex 照常推进),弹幕只从屏幕右边缘外到点滑入,永不屏内闪现;倍速下跳变阈值放宽到 max(1.2, 0.6×倍速),播放器 position 抖动不再误触发清屏;诊断行新增 发射数/迟丢数/最大迟到秒数。CAAnimation 渲染架构一行未动。"
}
