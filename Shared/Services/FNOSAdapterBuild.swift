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
    static let version = "v158"

    /// 本版主要变更摘要
    static let changes = "v158:1)修轻触跳焦(最终版)——删除三按钮.down→onDownToShelf分支(v150日志实锤:轻触漂移被分类为.down走该路径跳焦;v140-v147八版验证无此分支即不跳)。2)修下键导航——引擎原生空间移动+守卫(3s窗口)二次放行,放行时强制聚焦继续播放首卡(修「跑到页面最底部」)。3)修排查器卡死——拉取不再受掩码门控(数据常驻),掩码只控行显示;行数据不再因开关状态丢失。4)焦点回Hero时整页滚回顶部。翻页:左滑(play)=上一页可用;右滑前翻受遥控器漂移+引擎空间跳限制仍不可靠,待硬件层解决(右物理键维修/Gen1遥控)。"
}
