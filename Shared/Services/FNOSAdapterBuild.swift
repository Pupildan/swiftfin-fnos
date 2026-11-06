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
    static let version = "v149"

    /// 本版主要变更摘要
    static let changes = "v149:轻触跳焦排查结论落地。Hero文件已排除(与v100字节级相同)。本版把外壳焦点配置还原到v98原样:1).focusSection()从继续播放行移回整个海报墙VStack(v98原位置,恢复焦点边界穿越语义);2)去掉banner的.ignoresSafeArea()(恢复按钮组与海报墙的v98安全区几何距离)。Hero文件/三行内容/半屏修复均不动。"
}
