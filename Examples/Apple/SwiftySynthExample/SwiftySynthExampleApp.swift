import SwiftUI

@main
struct SwiftySynthExampleApp: App {
    init() {
        // Headless loudness A/B: `SWIFTYSYNTH_PROBE=1 ./SwiftySynthExample` prints
        // the piano-vs-bass report to stdout and exits before the window shows.
        LoudnessProbe.runIfRequestedThenExit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
