//
// FNOSReviewPopupSheet.swift
// v173: 评论弹窗（豆瓣 + 番剧详情页共用，1:1 同款）。
// 焦点落评论卡 → 确认键 → fullScreenCover 呈现本组件：屏幕居中、iOS 26 液态玻璃、
// 文字纯白零阴影（用户明令）。内容区定高 560 滚动视口 + 内容 .focusable()：长评可滚看全
// （修 v174 内容不能滚动）。背景 presentationBackground(.ultraThinMaterial)：
// 弹窗外内容高斯模糊（用户要求），非纯透明也非灰底。
// 承载方式用 fullScreenCover(item:) 而非 overlay：tvOS 上 overlay 不保证焦点移入。
//

import SwiftUI

struct FNOSReviewPopupSheet: View {
    let author: String
    /// 评分文案（如「8」带星）；nil = 不显示（番剧短评无评分）
    let ratingText: String?
    let content: String
    /// 关闭回调（确认键按「关闭」或 Menu）
    var onClose: () -> Void

    /// 按自然段落分行（每段一个 .focusable() 行，段内自然换行——不再 110 字硬切句中）：
    /// 单个大 Text 非焦点目标，tvOS 焦点引擎在 ScrollView 内无落点→滚不动，故仍需逐段 focusable
    private var contentRows: [String] {
        content
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(author)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                if let ratingText, !ratingText.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                        Text(ratingText).foregroundColor(.yellow.opacity(0.9))
                    }
                    .font(.system(size: 14))
                }
                // v182: 关闭按钮已删——Menu 关闭（内容行可聚焦，Menu 正确路由到本弹窗）
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(contentRows, id: \.self) { row in
                        Text(row)
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .lineSpacing(6)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable()   // 每行一个焦点落点 → 焦点逐行下移驱动 ScrollView 滚动看全文
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 560)   // 有界滚动视口
        }
        .padding(36)
        .frame(width: 960)
        // iOS 26 液态玻璃（与入库按钮同款 API），严格按玻璃材质实现
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v175: 弹窗外内容高斯模糊（磨砂材质模糊背后详情页），不再是纯透明
        .presentationBackground(.ultraThinMaterial)
        .onExitCommand(perform: onClose)
    }
}
