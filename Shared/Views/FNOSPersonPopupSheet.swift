//
// FNOSPersonPopupSheet.swift
// v180: 人物弹窗（豆瓣演员 / TMDB 主要演员 / 番剧角色·制作人员 共用）。
// 点击头像行的人物 → fullScreenCover 居中弹窗：大头像 + 姓名 + 角色；
// TMDB 侧额外拉取官方简介（biography），按长度切行逐行 focusable 滚动查看
// （复用评论弹窗 v178 的滚动方案：单个大 Text 非焦点目标滚不动）。
//

import SwiftUI

/// 人物信息（三个详情页共用；bio/infoLines 由各页拉取填充）
struct FNOSPersonInfo: Identifiable {
    let id: String
    let name: String
    let role: String
    let avatarURL: URL?
    /// 完整信息行（豆瓣 extra.info 键值对 / TMDB 生日·出生地）
    var infoLines: [String] = []
    /// 简介（TMDB biography / 番剧 summary）
    var bio: String? = nil
}

struct FNOSPersonPopupSheet: View {
    let person: FNOSPersonInfo
    var onClose: () -> Void

    /// 完整信息行 = 人物信息键值对（豆瓣 extra.info / TMDB 生日·出生地）+ 简介切行
    private var allRows: [String] { person.infoLines + bioRows }

    /// 简介按段落+长度切行：每行 .focusable()，焦点逐行下移驱动 ScrollView 滚动
    private var bioRows: [String] {
        guard let bio = person.bio, !bio.isEmpty else { return [] }
        var rows: [String] = []
        for para in bio.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let p = para.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if p.count <= 160 {
                rows.append(p)
                continue
            }
            var start = p.startIndex
            while start < p.endIndex {
                let end = p.index(start, offsetBy: 160, limitedBy: p.endIndex) ?? p.endIndex
                let chunk = String(p[start..<end]).trimmingCharacters(in: .whitespaces)
                if !chunk.isEmpty { rows.append(chunk) }
                if end >= p.endIndex { break }
                start = end
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(person.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            // v182: 无关闭按钮——Menu 关闭；此块为焦点锚点（无简介时 Menu 路由 + 焦点落点）
            HStack(spacing: 20) {
                if let url = person.avatarURL {
                    FNOSAsyncImage(url: url, headers: [:])
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 150, height: 150)
                }
                if !person.role.isEmpty {
                    Text(person.role)
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            .focusable()
            .focusEffectDisabled()

            if !allRows.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(allRows, id: \.self) { row in
                            Text(row)
                                .font(.system(size: 17))
                                .foregroundColor(.white)
                                .lineSpacing(6)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .focusable()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 480)
            }
        }
        .padding(36)
        .frame(width: 960)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(.ultraThinMaterial)
        .onExitCommand(perform: onClose)
    }
}
