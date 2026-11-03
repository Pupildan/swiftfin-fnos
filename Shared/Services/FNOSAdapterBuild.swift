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
    static let version = "v87"

    /// 本版主要变更摘要
    static let changes = "v87 续播功能完整实装：①本地进度存储（UserDefaults）为可靠主链路——播放中每 5s 落盘、看完自动清除，不依赖服务端上报是否生效；②详情页按钮有记录时变「继续播放」（剧集显示「继续播放 第N集」，跨季查找），点按带进度续播；③进入播放记录>30s 时底部弹「从头开始/继续播放」，3 秒未确认自动续播，焦点默认在继续播放；④剧集播完自动连播下一集（经既有换集链路）；⑤设置页新增「诊断信息」面板（真机无控制台）：空库原始返回/上报失败/Resume 拉取结果留痕，截图即可回报。服务端进度上报继续尽力而为。"
}
