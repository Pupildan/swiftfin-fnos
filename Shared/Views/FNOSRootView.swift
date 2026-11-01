//
// FNOSRootView.swift
// 根视图：按登录状态切换登录页 / 主界面。
//

import SwiftUI

struct FNOSRootView: View {

    @StateObject private var auth = FNOSAuthStore.shared

    var body: some View {
        Group {
            if let credentials = auth.credentials {
                FNOSMainView(auth: auth, credentials: credentials)
            } else {
                FNOSLoginView(auth: auth)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isLoggedIn)
    }
}
