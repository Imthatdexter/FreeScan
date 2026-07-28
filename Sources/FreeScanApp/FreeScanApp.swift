import SwiftUI
import FreeScanUI

@main
struct FreeScanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentSize)
    }
}
