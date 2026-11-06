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
    static let version = "v151"

    /// 本版主要变更摘要
    static let changes = "v151:轻触跳焦根因实锤(v150日志:轻触未按任何下键,onDownToShelf连发3次)——跳焦走的就是v98接线的.down→onDownToShelf,轻触漂移被分类为.down。本版:1)删除三按钮.down分支(跳焦源头,v140-v147已验证删除即不跳);2)恢复v132式守卫——无bypass进入海报墙弹回Hero,800ms内第二次进入=用户坚持(故意下键)放行;3)守卫同时拦截引擎空间跳(右滑窜到右下卡片),使.detail右滑的.right命令能送达翻页。已知代价:下键导航需按两次。下键/翻页/半屏修复路径均有诊断日志。"
}
