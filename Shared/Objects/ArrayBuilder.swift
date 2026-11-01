//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

@resultBuilder
public enum ArrayBuilder<Component> {

    public static func buildBlock(_ components: [Component]...) -> [Component] {
        components.flattened()
    }

    public static func buildExpression(_ expression: Component) -> [Component] {
        [expression]
    }

    public static func buildExpression(_ expression: Component?) -> [Component] {
        expression.flatMap { [$0] } ?? []
    }

    public static func buildOptional(_ component: [Component]?) -> [Component] {
        component ?? []
    }

    public static func buildEither(first component: [Component]) -> [Component] {
        component
    }

    public static func buildEither(second component: [Component]) -> [Component] {
        component
    }

    public static func buildArray(_ components: [[Component]]) -> [Component] {
        components.flattened()
    }

    public static func buildExpression(_ expression: [Component]) -> [Component] {
        expression
    }

    static func buildExpression<T: FNOSStringRawRepresentable>(_ expression: T) -> [Component] where T.RawValue == Component {
        [expression.rawValue]
    }

    static func buildExpression<T: FNOSStringRawRepresentable>(_ expression: [T]) -> [Component] where T.RawValue == Component {
        expression.map(\.rawValue)
    }

    static func buildExpression(_ expression: Void) -> [Component] {
        []
    }
}

/// 标记协议：App 自己的 String 枚举组件。
/// KSPlayer 给 Array 注入了 `RawRepresentable where Element: Codable`，
/// 会让 RawRepresentable 重载对数组表达式产生二义性 —— 必须用标记收窄。
public protocol FNOSStringRawRepresentable: RawRepresentable where RawValue == String {}

extension VideoRangeType: FNOSStringRawRepresentable {}
extension ItemSortBy: FNOSStringRawRepresentable {}
extension BaseItemKind: FNOSStringRawRepresentable {}
extension TranscodeReason: FNOSStringRawRepresentable {}
extension AudioCodec: FNOSStringRawRepresentable {}
extension VideoCodec: FNOSStringRawRepresentable {}
extension SubtitleFormat: FNOSStringRawRepresentable {}
extension MediaContainer: FNOSStringRawRepresentable {}
