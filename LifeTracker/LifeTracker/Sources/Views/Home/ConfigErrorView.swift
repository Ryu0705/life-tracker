import SwiftUI

struct ConfigErrorView: View {
    let error: Error

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("設定エラー")
                .font(.title2)
                .bold()
            Text(error.localizedDescription)
                .font(.body)
            Text("対処手順:")
                .font(.headline)
                .padding(.top, 8)
            Text("""
            1. LifeTracker.xcconfig.example を LifeTracker.xcconfig にコピー
            2. SUPABASE_URL / SUPABASE_ANON_KEY を Supabase Dashboard の値で埋める
            3. Xcode で Project → Configurations → Debug/Release に
               "Based on Configuration File" で LifeTracker.xcconfig を割り当て
            4. アプリ再ビルド
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}
