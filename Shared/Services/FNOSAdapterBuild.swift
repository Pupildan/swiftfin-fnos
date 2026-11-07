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
    static let version = "v177"

    /// 本版主要变更摘要
    static let changes = "v177:修继续播放第3+张卡按上键完全不动(用户确认完全不动=上方无落点;Hero可聚焦按钮集中在左侧,右侧卡正上方无Hero落点)。方案A:Hero加onUpToHero回调(照搬onDownToShelf同款,不碰Hero内部焦点判定),播放按钮onMoveCommand(.up)触发;MainView接线滚回Hero顶部+释放海报墙焦点让引擎回落Hero;resume卡.onMoveCommand(.up)兜底透传。另:评论弹窗ScrollView自身focusable修不能滚动;豆瓣相似推荐/番剧相关条目撤外层focusable(焦点进不去按钮);影评全文缓存重开即时显示。"
}
