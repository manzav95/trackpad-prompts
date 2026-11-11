import AppKit

final class AppMain: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

let application = NSApplication.shared
let appMain = AppMain()
application.delegate = appMain
application.setActivationPolicy(.accessory)
application.run()
