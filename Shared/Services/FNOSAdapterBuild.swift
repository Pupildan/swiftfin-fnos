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
    static let version = "v131"

    /// 本版主要变更摘要
    static let changes = "v131:1)修首页Hero焦点跳页(右键/滑动从播放移到+或详情时焦点窜到继续播放)——三个Hero按钮补全右左导航(用focusedButton在按钮间移动,不逃到海报墙)。2)豆瓣详情页照搬热门影视详情页布局:hero(高清横屏海报backdrop+左下徽章标题评分集数类型+右下主演导演)+下方简介/主演头像行/评论(frodo Reviews)+按标题入库按钮(MoviePilot lookupSubscribeByName)。豆瓣海报高清m_ratio。"
}
