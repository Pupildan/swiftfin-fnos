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
    static let version = "v155"

    /// 本版主要变更摘要
    static let changes = "v155:轻触跳焦根因落位(用户真机二分:v117引入)。v116→v117 diff逐项评估:6项改动中5项与首页焦点面无关,唯一带持续运行时足迹的=新增的@AppStorage缓存键(含几十KB JSON)——其UserDefaults KVO观察者在系统级写入时反复失效MainView,触摸手势期间被视图更新打断→焦点误投递。修复:tmdbCache/bangumiDate/bangumiCache/doubanDate/doubanCache五个键从@AppStorage改为计算属性直读直写UserDefaults(观察者归零,回到v116的1个小键;缓存功能不变)。"
}
