import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 参考图窗口仅保留红绿灯按钮，不显示标题文字。
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true

    RegisterGeneratedPlugins(registry: flutterViewController)
    BridgePlugin.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
