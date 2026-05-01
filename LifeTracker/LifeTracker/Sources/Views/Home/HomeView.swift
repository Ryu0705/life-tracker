import SwiftUI

struct HomeView: View {
    @Environment(\.dayDataSource) private var dataSource
    @StateObject private var loader: TodayDataLoader
    @State private var moment: Date = Date()

    init(dataSource: DayDataSource? = nil, calendar: Calendar = HomeView.defaultCalendar) {
        let source = dataSource ?? MockDayDataSource(context: .empty)
        _loader = StateObject(wrappedValue: TodayDataLoader(dataSource: source, calendar: calendar))
    }

    var body: some View {
        ZStack {
            content
            CheckInActionLayer()
        }
        .task {
            await loader.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if loader.isLoading && loader.day == nil {
            ProgressView("読み込み中…")
        } else if let error = loader.error, loader.day == nil {
            VStack(spacing: 12) {
                Text("読み込みに失敗しました")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("再試行") {
                    Task { await loader.refresh() }
                }
            }
            .padding()
        } else if let day = loader.day {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CurrentBlockCard(currentBlock: day.currentBlock(at: moment))
                    ScheduleListView(scheduled: day.scheduled)
                }
                .padding()
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    static var defaultCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }
}
