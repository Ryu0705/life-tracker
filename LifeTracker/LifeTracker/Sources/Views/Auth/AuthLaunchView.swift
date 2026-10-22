import SwiftUI

/// 起動中 (`.initialSession` を待つ間)。起動画面 (Info.plist の UILaunchScreen は空) と同じ背景に小さな ProgressView
struct AuthLaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("読み込み中")
        }
    }
}
