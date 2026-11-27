import SwiftUI

@main
struct RelogioDuploApp: App {
    @State private var model = ClockModel()

    init() { LoginItem.ensureEnabled() }

    var body: some Scene {
        MenuBarExtra {
            CalendarView(today: model.now)
                .padding(12)
            .fixedSize()
        } label: {
            Image(nsImage: MenuBarImage.make(text: model.text))
                .accessibilityLabel(model.text)
        }
        .menuBarExtraStyle(.window)
    }
}
