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
    static let version = "v84"

    /// 本版主要变更摘要
    static let changes = "v84 收官版：①进入同行推出不可见的真机理——副本与横图边缘同用 0.45 弹簧，同速后退相对运动≈0（反向横图内缩、相对运动大故可见）；正向副本弹簧提速到 0.26，邻居跑赢图像边缘一倍，推出动作清晰可见（ATV 同款：行快速让位、图像随后铺开）。②反复进出详情海报黑色转圈——原单一混合缓存（countLimit=400）被详情页 2s 轮播的 ~8MB 横图挤爆：海报改独立缓存（300 张，与大图完全隔离）+ 通用缓存按压缩字节成本驱逐（80MB）+ FNOSAsyncImage 首帧同步查缓存（视图重建不再闪 loading）。"
}
