import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Desktop sizing (007 macOS support, FR-014): open at a comfortable default and prevent
    // shrinking below the chat layout's usable floor. The Dart UI is otherwise unchanged.
    self.setContentSize(NSSize(width: 480, height: 820))
    self.contentMinSize = NSSize(width: 380, height: 600)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
