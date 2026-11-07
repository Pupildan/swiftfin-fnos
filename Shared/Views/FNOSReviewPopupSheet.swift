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
                Spacer()
                Button(action: onClose) {
                    Text("关闭")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.card)
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .lineSpacing(7)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()   // 焦点进入滚动区，up/down 即可滚动看全文
            }
            .frame(height: 560)   // 有界滚动视口（内容溢出即可滚）
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
