import Cocoa
import FlutterMacOS
import KEQDesktopSupport
import KEQNetworkClient

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?
  private var networkChannel: FlutterMethodChannel?
  private var networkClient = NetworkServiceClient()
  private var titleLabel: NSTextField?

  override var title: String {
    didSet {
      titleLabel?.stringValue = title
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    let desktopChannel = FlutterMethodChannel(name: "keqdis_vpn_channel", binaryMessenger: messenger)
    self.desktopChannel = desktopChannel
    let desktop = DesktopController(window: self) { [weak desktopChannel] method, arguments in
      desktopChannel?.invokeMethod(method, arguments: arguments)
    }
    (NSApp.delegate as? AppDelegate)?.attachDesktop(desktop)
    desktopChannel.setMethodCallHandler { call, result in
      desktop.handle(method: call.method, arguments: call.arguments) { response in
        switch response {
        case .success(let value): result(value)
        case .failure(let error): result(FlutterError(code: "macos_desktop", message: error.localizedDescription, details: nil))
        }
      }
    }

    let networkChannel = FlutterMethodChannel(name: "com.keqdroid.keqdroid/network", binaryMessenger: messenger)
    self.networkChannel = networkChannel
    networkChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "The application is closing.", details: nil)); return }
      let complete: (Result<[String: Any], Error>) -> Void = { response in
        DispatchQueue.main.async {
          switch response {
          case .success(let value): result(value)
          case .failure(let error):
            let failure = NetworkServiceError.bridge(error, method: call.method)
            result(FlutterError(code: failure.code, message: failure.message, details: failure.details))
          }
        }
      }
      if call.method == "authorize" { self.networkClient.authorize(completion: complete) }
      else { self.networkClient.call(method: call.method, arguments: call.arguments as? [String: Any] ?? [:], completion: complete) }
    }

    super.awakeFromNib()
    setupCenteredTitle()
  }

  private func setupCenteredTitle() {
    self.titleVisibility = .hidden
    guard let frameView = self.contentView?.superview else { return }
    func findTitlebarView(_ view: NSView) -> NSView? {
      if NSStringFromClass(type(of: view)).contains("NSTitlebarView") { return view }
      for sub in view.subviews {
        if let found = findTitlebarView(sub) { return found }
      }
      return nil
    }
    if let titlebarView = findTitlebarView(frameView) {
      let label = NSTextField(labelWithString: self.title.isEmpty ? "keqdroid" : self.title)
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = NSFont.titleBarFont(ofSize: 13)
      label.textColor = .windowFrameTextColor
      label.alignment = .center
      label.isSelectable = false
      label.isEditable = false
      label.isBezeled = false
      label.drawsBackground = false
      titlebarView.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor)
      ])
      self.titleLabel = label
    }
  }
}
