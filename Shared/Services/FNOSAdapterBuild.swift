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
    static let version = "v161"

    /// 本版主要变更摘要
    static let changes = "v161:方案A落地(用户确认)——推荐行「跟随焦点域」动态挂载。Hero态(启动+回Hero)三行不挂载,首页=纯v98结构(真机实验证实:轻触不跳/左右滑翻页/单次下键全部正常);下键进入海报墙时挂载三行(数据常驻内存无网络等待,正常显示可导航);回Hero时卸载+整页滚回顶部(卸载/挂载都在视口外发生,无视觉闪烁)。详情页浏览期间行保持挂载(关闭后焦点可归还)。移除排查器(rowMask)与守卫等全部临时机制。已知代价:Hero首屏无推荐内容(下键后可见)。"
}
