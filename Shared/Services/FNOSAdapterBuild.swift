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
    static let version = "v152"

    /// 本版主要变更摘要
    static let changes = "v152:1)下键导航修复——守卫双击窗口0.8s→3s(真机日志:人手二次下键间隔1-6s,0.8s来不及;轻触跳焦已由v151根除,3s窗口误放行风险极低)。2)向前翻页换通道——日志证实.right从不投递(引擎拿去空间跳)而垂直轴.up/.down可靠送达,play/detail增加.up→pageNext(上滑=下一页);.left→pagePrevious保持(play左滑翻页日志已验证送达)。"
}
