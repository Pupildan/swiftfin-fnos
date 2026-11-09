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
    static let version = "v197"

    /// 本版主要变更摘要
    static let changes = "v197:①KS 弹幕滑块滑动失效真根因修复(用户实测v196仍不行)——上轮v196漏了给FNOSPanBridge的recognizer挂delegate,导致shouldBegin让位逻辑是死代码;现已补上recognizer.delegate=FNOSPanBridge.shared,弹层打开时视频层手势让位给面板滑动桥,KS滑动与MPV一致;②搜索框灰底彻底去除——TextField加focusEffectDisabled()去掉tvOS系统聚焦效果(之前.plain只去样式未去聚焦遮盖),改自绘白色描边(聚焦变亮,无灰底灰盖);③屏保所有权归播放器容器(用户实测MPV播放中进系统屏保)——容器onAppear置true/onDisappear置false,KS销毁与MPV onDisappear不再各自置false(之前DoVi自动切换KS→MPV会把isIdleTimerDisabled重置false导致MPV播放中进屏保)。"
}
