import AppKit
import Foundation

@MainActor
enum AxiomApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

if CommandLine.arguments.contains("--verify") {
    Task {
        let succeeded = await AxiomVerification.run()
        Foundation.exit(succeeded ? 0 : 1)
    }
    dispatchMain()
} else {
    AxiomApp.main()
}
