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
    static let version = "v222"

    /// 本版主要变更摘要
    static let changes = "v222:修复 v221 弹幕仍不显示——v221 日志证明发射/回收/速度全部正常(在屏16条 发射点推进 speed=1.0)但屏幕无像素,嫌疑锁定 v220 引入的自定义异步光栅化 layer(FNOSDanmakuAsyncLayer 后台渲染 contents 疑似不上屏)。本版内容回退到 v219 真机验证可见的 CATextLayer 同步渲染(v218 教训=纯实心字不加描边,无骨架字),移动保留 CABasicAnimation(v220 丝滑机制:render server 独立插值,主线程零逐帧计算);弹幕 layer 用 addSublayer 加到独立普通 UIView 容器(v219 同款,不触发布局回调);v221 的死循环修复/尺寸守卫/渲染诊断全部保留,诊断行新增容器尺寸字段。"
}
