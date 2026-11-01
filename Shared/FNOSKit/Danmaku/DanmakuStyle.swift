import CoreGraphics
import UIKit

/// 弹幕渲染样式（全部可调，Apple TV 4K 建议 fontSize 40+）
public struct DanmakuStyle: Sendable {
    /// 字号（pt）。4K 电视建议 38~44
    public var fontSize: CGFloat
    /// 是否加粗
    public var bold: Bool
    /// 文字描边宽度（0 关闭）。描边比阴影便宜得多，深色画面上保证可读性
    public var strokeWidth: CGFloat
    /// 描边颜色
    public var strokeColor: DanmakuColor

    /// 一条滚动弹幕横穿屏幕所需时间（秒）。越小越快
    public var scrollDuration: TimeInterval
    /// 顶部/底部固定弹幕停留时长（秒）
    public var fixedDuration: TimeInterval

    /// 弹幕占视图高度的比例（0...1），1 = 全屏区域
    public var areaRatio: CGFloat
    /// 行高系数（行高 = fontSize × 该值）
    public var lineSpacingFactor: CGFloat
    /// 同轨道新弹幕与前一弹幕尾部的最小间距（pt）
    public var laneMargin: CGFloat

    /// 整体不透明度（可见时）
    public var opacity: Float
    /// 同屏弹幕上限（超出直接丢弃，防极端数据源）
    public var maxOnScreen: Int
    /// 显示/隐藏切换动画时长（秒）
    public var toggleAnimationDuration: CFTimeInterval

    public init(
        fontSize: CGFloat = 40,
        bold: Bool = true,
        strokeWidth: CGFloat = 2.5,
        strokeColor: DanmakuColor = .init(red: 0, green: 0, blue: 0),
        scrollDuration: TimeInterval = 10,
        fixedDuration: TimeInterval = 5,
        areaRatio: CGFloat = 0.75,
        lineSpacingFactor: CGFloat = 1.45,
        laneMargin: CGFloat = 16,
        opacity: Float = 1.0,
        maxOnScreen: Int = 400,
        toggleAnimationDuration: CFTimeInterval = 0.25
    ) {
        self.fontSize = fontSize
        self.bold = bold
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.scrollDuration = scrollDuration
        self.fixedDuration = fixedDuration
        self.areaRatio = areaRatio
        self.lineSpacingFactor = lineSpacingFactor
        self.laneMargin = laneMargin
        self.opacity = opacity
        self.maxOnScreen = maxOnScreen
        self.toggleAnimationDuration = toggleAnimationDuration
    }

    /// tvOS 推荐预设（大屏高密度）
    public static func appleTV4K() -> DanmakuStyle {
        var style = DanmakuStyle()
        style.fontSize = 42
        style.strokeWidth = 3
        style.scrollDuration = 11
        style.maxOnScreen = 500
        return style
    }
}
