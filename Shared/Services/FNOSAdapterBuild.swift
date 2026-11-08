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
    static let version = "v190"

    /// 本版主要变更摘要
    static let changes = "v190:①弹幕设置四项全改无极滑块(液态玻璃风格;tvOS系统Slider焦点不可靠老坑→复用进度条自绘模式focusable+onMoveCommand步进,长按连发):字号16-44/不透明度20-100%/速度0.5-2.5x/新增显示区域25-100%屏;②新增弹幕显示区域调节(参考安卓TV弹幕客户端):引擎滚动泳道数按区域动态计算(池上限20,同轨3.5s防重叠不变,默认30%≈旧版5泳道密度),渲染层区域外弹幕裁剪;③内嵌字幕按用户令改软件默认字体渲染(40pt白字,弃原ASS描边样式——真机实测描边渲染是线条骨架字),SwiftUI Text直出纯文本;④三弹窗缩小(音轨/字幕600宽、弹幕设置680宽)并锚定在控制条功能按钮上方(bottomTrailing,不再屏幕居中),出现/消失带opacity+move过渡动画;⑤死规则入库:新功能UI一律官方液态玻璃(glassEffect/.glass/.glassProminent),播放器承载用overlay禁.sheet。"
}
