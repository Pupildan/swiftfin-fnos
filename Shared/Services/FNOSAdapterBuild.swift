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
    static let version = "v193"

    /// 本版主要变更摘要
    static let changes = "v193:①弹幕设置无极滑块滑动调节手感修复(用户实测滑很多次才动一点点)——滑动桥改每实例协调器+滑动增量直接回调面板绑定(旧版写UserDefaults再靠@AppStorage回读,滑块不即时跟随),灵敏度提升(字号0.3/不透明度0.006/速度0.015/区域0.003 每px),滑块填充与数值随滑动即时进退;②mpv弹窗焦点修复(用户实测焦点进不去弹层、自动回退到播放键)——ticker每250ms的焦点兜底在弹层打开时不再把焦点拽回播放键;关闭弹层后焦点回到打开它的那个按钮(音轨/字幕/弹幕设置各自对应),不再一律回播放键。"
}
