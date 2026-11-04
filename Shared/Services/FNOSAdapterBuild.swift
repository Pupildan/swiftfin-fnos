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
    static let version = "v119"

    /// 本版主要变更摘要
    static let changes = "v119:播放三修。1)播放时不进系统屏保(两个引擎onAppear设isIdleTimerDisabled,onDisappear恢复)。2)mpv引擎剧集播完自动连播下一集(ticker位置逼近时长检测+onFinished回调接容器换集链路,暂停态不误判)。3)mpv字幕/弹幕颜色发灰修复(tone-mapping改hable+target-peak100+黑位压深+sub-color强制纯白,sub-ass-override=force)。"
}
