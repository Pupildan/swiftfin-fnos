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
    static let version = "v221"

    /// 本版主要变更摘要
    static let changes = "v221:修复 v220 弹幕完全不显示的致命 bug——v220 把弹幕 cell 直接 addSubview 到宿主视图自身,而 UIKit 中 addSubview 会触发宿主 setNeedsLayout→layoutSubviews→layoutChanged()→clearAll(),形成「发射即清屏」死循环,弹幕刚加上就被删,屏幕永远空白(v219 用 addSublayer 加到普通 CALayer 上无此坑,v220 改 UIView 时踩了)。修复:①弹幕 cell 移入独立普通 UIView 容器 danmakuContainer(无 layoutSubviews 重载);②宿主 layoutSubviews 只在尺寸真正变化时重建轨道,控制条显隐/焦点变化不再清屏;③setRate 值不变时跳过,避免 4Hz 反复重映射 layer 时间轴;④新增 9999 渲染诊断日志(2s 节流:在屏数/发射点/速度),不显示时可直接定位是没发射、被清屏还是 speed=0 冻结。CAAnimation 丝滑机制原样保留。"
}
