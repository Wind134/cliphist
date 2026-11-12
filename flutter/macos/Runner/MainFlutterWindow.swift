import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 400, height: 600))

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    // Stay hidden until Dart decides. Avoids a first-frame flash on login
    // when silent start is enabled.
    self.orderOut(nil)
  }
}
