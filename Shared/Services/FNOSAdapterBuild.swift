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
    static let version = "v80"

    /// 本版主要变更摘要
    static let changes = "v80 修复：①详情页返回高概率丢焦点——cover 展示期间不再 disabled 主页（仅飞行期禁用），保住焦点引擎的归还锚点；closeDetail 焦点恢复由单发 0.18s 改为 0.1/0.3/0.6/1.0s 多次幂等兜底。②同行海报不参与动画——行副本 scaleEffect 锚点坐标系错误（.position 包装视图占满全屏，anchor 须按全屏比例而非副本内部占比），改为焦点卡真实屏幕中心占比；行副本 1→3 缩放由 onAppear 同步设置（会被插入事务合并→首帧即 3.0，邻居凭空消失）改为隔帧起弹簧；窗口 ±3 放宽到 ±6 并抽成共享常量 windowHalf，主页隐藏窗口与飞行层副本保证同宽。"
}
