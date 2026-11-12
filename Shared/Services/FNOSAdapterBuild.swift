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
    static let version = "v208"

    /// 本版主要变更摘要
    static let changes = "v208:v207 真机反馈三修+图标。①面板时间读取不准=打开瞬间靠下一个 tick 才有位置,改打开时立即同步真实位置/总时长(两内核同款);②弹窗选中效果白底白字看不清=弃官方 .glass 改 FNOSBareButtonStyle+自绘描边(聚焦白 2.5pt/非聚焦 0.28 白 1pt);③自动跳过后选集/进度失效的头号嫌疑=KS onPlay 后台线程直接 seek 有内部竞态,改一律 Task{@MainActor} 提交,并加触发时与 seek 后 1.2s 的 timemodel 快照诊断(9999),复现即可实锤;④App 图标换 Nbeefin 图(imagestack 双层整图铺满,按现有资产尺寸生成)。"
}
