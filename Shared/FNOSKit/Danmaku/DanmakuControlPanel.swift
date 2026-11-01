import SwiftUI

// MARK: - tvOS 焦点动画风格
//
// "物理级阻尼感"的实现要点：
// - spring(response: 0.32, dampingFraction: 0.55) —— 欠阻尼弹簧，聚焦时有
//   一次轻微过冲再回稳，模拟真实重物滑入的手感；
// - 聚焦/失焦的位移、缩放、阴影**全部挂在同一个 spring** 上（多属性同步变形，
//   不会出现"缩放先到、阴影后到"的塑料感）；
// - 所有数值变化（透明度滑杆、字号、速度）同样用这把弹簧，方向键连扫时
//   形成一个连续的惯性曲线，而不是 60 次离散跳变。

/// 焦点卡片按钮风格：聚焦放大 + 上浮 + 阴影加深，欠阻尼弹簧驱动
public struct DanmakuFocusButtonStyle: ButtonStyle {

    /// 是否为"整行"样式（控制面板行 vs 独立按钮）
    let isRow: Bool

    @Environment(\.isFocused) private var isFocused

    public init(isRow: Bool = false) {
        self.isRow = isRow
    }

    /// 统一的阻尼弹簧（面板内所有动画共用）
    public static let damped = Animation.spring(response: 0.32, dampingFraction: 0.55, blendDuration: 0.08)

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isFocused ? .primary : .white)
            .padding(.horizontal, isRow ? 20 : 26)
            .padding(.vertical, isRow ? 12 : 14)
            .frame(maxWidth: isRow ? .infinity : nil, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.10))
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0.2),
                    radius: isFocused ? 18 : 6,
                    y: isFocused ? 10 : 3)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            // ★ 物理：焦点变化 → 欠阻尼弹簧；按压 → 更快的弹簧
            .animation(Self.damped, value: isFocused)
            .animation(.spring(response: 0.22, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// MARK: - 阻尼数值条（透明度/速度等连续量的可视化）

struct DampedGaugeBar: View {
    let value: Double   // 0...1
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(8, proxy.size.width * value))
            }
        }
        .frame(height: 10)
        // 数值变化用同一把阻尼弹簧 → 方向键连扫时呈现惯性跟随
        .animation(DanmakuFocusButtonStyle.damped, value: value)
    }
}

// MARK: - 弹幕控制面板

/// 弹幕控制面板（tvOS 焦点引擎驱动）。
///
/// 交互设计：
/// - 方向键上下在行间移动，左右在聚焦行上调节数值（tvOS 设置页的标准交互）；
/// - 面板出现后自动聚焦第一行，遥控器"一滑即用"；
/// - 每一行的聚焦变形、数值条填充都由欠阻尼弹簧驱动，滑动时有物理惯性。
///
/// 用法（叠在播放器上方、弹幕层之下均可——弹幕层不吃事件）：
/// ```swift
/// ZStack {
///     PlayerLayerView(player: player)
///     DanmakuOverlay(...)                       // isUserInteractionEnabled = false
///     if showPanel {
///         DanmakuControlPanel(isVisible: $danmuOn, style: $danmuStyle)
///     }
/// }
/// ```
public struct DanmakuControlPanel: View {

    public enum Field: Hashable {
        case toggle, opacity, fontSize, speed
    }

    @FocusState private var focusedField: Field?

    @Binding public var isVisible: Bool
    @Binding public var style: DanmakuStyle
    /// 面板关闭回调（通常同时把外部 showPanel 置 false）
    public var onDismiss: () -> Void

    /// 透明度取值 0...1（从 style.opacity 归一）
    private var opacityValue: Double {
        Double(max(0.1, min(1, style.opacity)))
    }

    public init(isVisible: Binding<Bool>,
                style: Binding<DanmakuStyle>,
                onDismiss: @escaping () -> Void = {}) {
        _isVisible = isVisible
        _style = style
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 10) {
            toggleRow
            opacityRow
            fontSizeRow
            speedRow

            Text("按 Menu/返回键 收起面板")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .focusSection()   // 焦点引擎分组：焦点在面板内循环不外逃
        .onAppear {
            // 面板出现即自动聚焦第一行（稍延迟确保焦点系统就绪）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = .toggle
            }
        }
    }

    // MARK: - 行视图

    private var toggleRow: some View {
        focusableRow(.toggle, title: "弹幕开关", valueText: isVisible ? "开" : "关") {
            withAnimation(DanmakuFocusButtonStyle.damped) {
                isVisible.toggle()
            }
        } onMove: { direction in
            guard direction == .left || direction == .right else { return }
            withAnimation(DanmakuFocusButtonStyle.damped) {
                isVisible.toggle()
            }
        }
    }

    private var opacityRow: some View {
        focusableRow(.opacity, title: "透明度", valueText: "\(Int(opacityValue * 100))%") {
            // 确认键在"关/开"之间快速切换
            withAnimation(DanmakuFocusButtonStyle.damped) {
                style.opacity = style.opacity > 0.5 ? 0.3 : 1.0
            }
        } onMove: { direction in
            let step: Float = direction == .left ? -0.05 : 0.05
            withAnimation(DanmakuFocusButtonStyle.damped) {
                style.opacity = min(1, max(0.1, style.opacity + step))
            }
        } accessory: {
            DampedGaugeBar(value: opacityValue, tint: .pink)
                .frame(width: 180)
        }
    }

    private var fontSizeRow: some View {
        focusableRow(.fontSize, title: "字号", valueText: "\(Int(style.fontSize))") {
        } onMove: { direction in
            let step: CGFloat = direction == .left ? -2 : 2
            withAnimation(DanmakuFocusButtonStyle.damped) {
                style.fontSize = min(64, max(24, style.fontSize + step))
            }
        }
    }

    private var speedRow: some View {
        focusableRow(.speed, title: "速度", valueText: speedLabel) {
        } onMove: { direction in
            // scrollDuration 越小越快
            let step: TimeInterval = direction == .left ? 0.5 : -0.5
            withAnimation(DanmakuFocusButtonStyle.damped) {
                style.scrollDuration = min(16, max(6, style.scrollDuration + step))
            }
        }
    }

    private var speedLabel: String {
        switch style.scrollDuration {
        case ..<7.5:  return "极快"
        case ..<9:    return "快"
        case ..<11.5: return "标准"
        case ..<13.5: return "慢"
        default:      return "极慢"
        }
    }

    // MARK: - 通用行构造

    private func focusableRow<Accessory: View>(
        _ field: Field,
        title: String,
        valueText: String,
        action: @escaping () -> Void,
        onMove: @escaping (MoveCommandDirection) -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                Spacer()
                accessory()
                Text(valueText)
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                    .foregroundColor(focusedField == field ? .secondary : .white.opacity(0.75))
            }
        }
        .buttonStyle(DanmakuFocusButtonStyle(isRow: true))
        .focused($focusedField, equals: field)
        .onMoveCommand(perform: onMove)
        // 面板内焦点转移的编排动画（行间滑动时整组内容轻微跟随）
        .animation(DanmakuFocusButtonStyle.damped, value: focusedField)
    }
}
