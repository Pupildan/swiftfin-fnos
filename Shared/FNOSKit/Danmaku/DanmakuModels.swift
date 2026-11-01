import Foundation
import CoreGraphics

// MARK: - 弹幕模型

/// 弹幕轨道类型
public enum DanmakuLaneKind: Equatable, Sendable {
    /// 滚动弹幕（从右向左）
    case scroll
    /// 顶部固定弹幕
    case top
    /// 底部固定弹幕
    case bottom
}

/// 单条弹幕（解析完成、可直接交给渲染引擎）
public struct DanmakuItem: Sendable {
    /// 出现时刻（秒，相对视频起点）
    public let time: Double
    /// 文本内容
    public let text: String
    /// 轨道类型
    public let kind: DanmakuLaneKind
    /// 文字颜色
    public let color: DanmakuColor

    public init(time: Double, text: String, kind: DanmakuLaneKind, color: DanmakuColor) {
        self.time = time
        self.text = text
        self.kind = kind
        self.color = color
    }
}

/// 平台无关的颜色表示（解析期使用，渲染时转 UIColor/CGColor）
public struct DanmakuColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = DanmakuColor(red: 255, green: 255, blue: 255)

    /// 解析 "#FFFFFF" / "FFFFFF" 格式
    public init?(hexString: String?) {
        guard var hex = hexString, !hex.isEmpty else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(rgbValue: value)
    }

    /// 解析 dandanplay 十进制 RGB（如 16777215 = 白色）
    public init?(rgbValue: UInt32) {
        self.init(red: UInt8((rgbValue >> 16) & 0xFF),
                  green: UInt8((rgbValue >> 8) & 0xFF),
                  blue: UInt8(rgbValue & 0xFF))
    }
}

// MARK: - 时间轴（引擎的稳定数据源）

/// 一集弹幕的不可变时间轴。
/// 以 class 身份存在是为了让 SwiftUI 侧用 ObjectIdentifier 判断"是否需要重载"，
/// 避免 struct 数组在每次视图刷新时触发重新排序/重建。
public final class DanmakuTimeline {
    /// 按 time 升序
    public let items: [DanmakuItem]
    /// 数据来源描述（用于调试/HUD）
    public let source: String

    public init(items: [DanmakuItem], source: String) {
        self.items = items.sorted { $0.time < $1.time }
        self.source = source
    }

    public var count: Int { items.count }

    /// 二分查找：第一个 time >= t 的下标
    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - dandanplay 兼容格式解析

public enum DanmakuParsing {

    /// 解析 dandanplay 的 `p` 字段："时间,模式,颜色[,其他...]"
    /// 模式（dandanplay 规范）：1~3 滚动，4 底部，5 顶部，7/8 定位（跳过）
    public static func item(fromCommentP p: String, text: String) -> DanmakuItem? {
        let parts = p.split(separator: ",").map(String.init)
        guard let time = Double(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") else {
            return nil
        }
        let mode = Int(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "1") ?? 1
        let color: DanmakuColor
        if parts.count > 2, let rgb = UInt32(parts[2].trimmingCharacters(in: .whitespaces)) {
            color = DanmakuColor(rgbValue: rgb) ?? .white
        } else {
            color = .white
        }
        guard let kind = laneKind(fromDandanplayMode: mode) else { return nil }
        return DanmakuItem(time: time, text: text, kind: kind, color: color)
    }

    static func laneKind(fromDandanplayMode mode: Int) -> DanmakuLaneKind? {
        switch mode {
        case 1...3: return .scroll
        case 4:     return .bottom
        case 5:     return .top
        default:    return nil   // 定位/高级弹幕：无坐标数据，跳过
        }
    }

    /// 解析 fnos-tv `/danmu/get` 格式的条目（mode 0 = 滚动）
    public static func item(fromDanmuGet time: Double?, mode: Int?, colorHex: String?, text: String?) -> DanmakuItem? {
        guard let time, let text, !text.isEmpty else { return nil }
        let kind: DanmakuLaneKind
        switch mode ?? 0 {
        case 4:  kind = .bottom
        case 5:  kind = .top
        default: kind = .scroll   // 0（及 1~3）均为滚动
        }
        let color = DanmakuColor(hexString: colorHex) ?? .white
        return DanmakuItem(time: time, text: text, kind: kind, color: color)
    }
}
