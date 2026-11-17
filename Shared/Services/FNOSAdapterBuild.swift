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
    static let version = "v216"

    /// 本版主要变更摘要
    static let changes = "v216:App 图标+顶架图按 brandassets 规范重编。上一版图标未生效根因=旧资产踩格式雷(App Store 层 512x512 RGBA 带透明/主屏层 216x216 尺寸错/顶架混用 tv+tv-marketing 四文件结构),actool 对 document errors 只丢图标不 fail CI。本次:图标=Nbeefin 新图(1280x768+400x240 全不透明 RGB,imagestack 双层+纯黑 Back),顶架=新横图去水印(1920x720+2320x720,左上角 AI 生成水印梯度插值修补,底部水印裁切窗口避开),Contents.json 统一为已真机验证的单 universal 模板。"
}
