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
    static let version = "v196"

    /// 本版主要变更摘要
    static let changes = "v196:①KS 弹幕无极滑块滑动失效修复(用户实测KS上滑不动/不如MPV)——根因=KS视频层FNOSPanBridge手势与面板滑动桥竞争抢走滑动手势,加delegate shouldBegin:弹层打开时视频层手势让位给面板桥,KS滑动与MPV一致;②滑块步进降低(用户实测步进太快)——滑动灵敏度减半(字号0.15/不透明度0.003/区域0.0015每px),速度单独0.0025每px(限制步进≤0.5),按键步进减半(字号1/不透明度0.025/速度0.05/区域0.025)+连按加速上限×2;③同含v195全部内容(搜索框去灰底/设置搜索按钮对调)。"
}
