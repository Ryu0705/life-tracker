import SwiftUI

struct CurrentBlockCard: View {
    let currentBlock: DayScheduledTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("現在進行中")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let block = currentBlock {
                Text(block.task.name)
                    .font(.title3.bold())
                Text(rangeText(for: block))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("進行中のブロックはありません")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rangeText(for block: DayScheduledTask) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: block.visibleRange.start)
        let end = formatter.string(from: block.visibleRange.end)
        return "\(start) – \(end)"
    }
}
