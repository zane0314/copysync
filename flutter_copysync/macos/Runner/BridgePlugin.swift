import ApplicationServices
import Cocoa
import Carbon
import CryptoKit
import FlutterMacOS
import ServiceManagement
import UserNotifications

// CopySync macOS 原生桥接（Task 22）：把 mac-clipboard/CopySync.m 已验证能力
// 逐条迁移为 MethodChannel 方法。通道名 xyz.copysync/bridge，Dart 侧接口见
// lib/bridge/native_bridge.dart。WebView 恢复回调按主设计 §9 不迁移。
//
// 错误约定（与 BridgeErrorCodes 一一对应）：
// permission_denied / cancelled / not_found / not_ready / checksum_mismatch /
// hotkey_failed / invalid_args / unavailable / system_error。

private let bridgeChannelName = "xyz.copysync/bridge"
private let markerPasteboardType = NSPasteboard.PasteboardType("com.example.copysync")
private let pasteSignature: Int64 = 0x434F5059
private let ignoreNextCopyKey = "ignoreNextCopy"
private let clipboardHistoryKey = "clipboardHistory"
private let historyPinnedKey = "historyPinned"
private let historyShortcutKey = "historyShortcut"
private let receivedDeliveryPathsKey = "receivedDeliveryPaths"
private let historyLimit = 10
private let updateManifestURL = "https://copy-direct.example.com/api/update/mac"

private func bridgeError(_ code: String, _ message: String) -> FlutterError {
  return FlutterError(code: code, message: message, details: nil)
}

private func sha256Hex(_ data: Data) -> String {
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - 本地历史（CopySync.m:334-489，上限 10 条 + SHA-256 去重置顶）

final class HistoryStore {
  private(set) var items: [[String: Any]] = []
  var onChanged: (() -> Void)?

  var historyImagesURL: URL {
    return BridgePaths.cacheRoot.appendingPathComponent("历史截图", isDirectory: true)
  }

  func load() {
    let saved = UserDefaults.standard.array(forKey: clipboardHistoryKey) ?? []
    var loaded: [[String: Any]] = []
    for entry in saved {
      // 兼容旧版纯字符串条目（CopySync.m:205-211）。
      if let text = entry as? String, !text.isEmpty {
        loaded.append([
          "id": UUID().uuidString, "kind": "text", "text": text,
          "created": Date().timeIntervalSince1970,
        ])
      } else if let dict = entry as? [String: Any],
        (dict["id"] as? String)?.isEmpty == false,
        (dict["kind"] as? String)?.isEmpty == false
      {
        loaded.append(dict)
      }
    }
    items = loaded
    while items.count > historyLimit { removeFile(for: items.last); items.removeLast() }
    save()
  }

  func save() {
    UserDefaults.standard.set(items, forKey: clipboardHistoryKey)
  }

  private func removeFile(for item: [String: Any]?) {
    guard let item = item, item["kind"] as? String == "image",
      let path = item["path"] as? String, !path.isEmpty
    else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  // 注：旧实现的 prune 会跳过"传输中"条目（inFlightHistoryIDs）；V3 中传输
  // 状态在 Dart 侧管理，原生层不再感知，故直接淘汰最旧条目。
  private func prune() {
    while items.count > historyLimit {
      removeFile(for: items.last)
      items.removeLast()
    }
  }

  @discardableResult
  func addText(_ text: String) -> [String: Any]? {
    guard !text.isEmpty else { return nil }
    let fingerprint = sha256Hex(Data(text.utf8))
    items.removeAll { $0["fingerprint"] as? String == fingerprint }
    let item: [String: Any] = [
      "id": UUID().uuidString, "kind": "text", "text": text,
      "fingerprint": fingerprint, "created": Date().timeIntervalSince1970,
    ]
    items.insert(item, at: 0)
    prune()
    save()
    onChanged?()
    return item
  }

  @discardableResult
  func addImage(png: Data, title: String) -> [String: Any]? {
    guard !png.isEmpty else { return nil }
    BridgePaths.ensureFolders()
    let fingerprint = sha256Hex(png)
    if let index = items.firstIndex(where: { $0["fingerprint"] as? String == fingerprint }) {
      // 图片去重：保留原 id/path 只刷新时间并置顶（CopySync.m:380-385）。
      var existing = items.remove(at: index)
      existing["created"] = Date().timeIntervalSince1970
      items.insert(existing, at: 0)
    } else {
      let identifier = UUID().uuidString
      let url = historyImagesURL.appendingPathComponent(identifier).appendingPathExtension("png")
      do {
        try png.write(to: url, options: .atomic)
      } catch {
        return nil
      }
      items.insert([
        "id": identifier, "kind": "image", "text": title, "path": url.path,
        "fingerprint": fingerprint, "created": Date().timeIntervalSince1970,
      ], at: 0)
    }
    prune()
    save()
    onChanged?()
    return items.first
  }

  func item(id: String) -> [String: Any]? {
    return items.first { $0["id"] as? String == id }
  }

  func remove(id: String) -> Bool {
    guard let index = items.firstIndex(where: { $0["id"] as? String == id }) else {
      return false
    }
    removeFile(for: items[index])
    items.remove(at: index)
    save()
    onChanged?()
    return true
  }

  func clear() {
    for item in items { removeFile(for: item) }
    items.removeAll()
    save()
    onChanged?()
  }

  var isPinned: Bool {
    get {
      if UserDefaults.standard.object(forKey: historyPinnedKey) == nil {
        UserDefaults.standard.set(true, forKey: historyPinnedKey)
      }
      return UserDefaults.standard.bool(forKey: historyPinnedKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: historyPinnedKey)
    }
  }
}

// MARK: - 目录约定（CopySync.m:305-332，~/Documents 下）

enum BridgePaths {
  static var cacheRoot: URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return documents.appendingPathComponent("CopySync 临时文件", isDirectory: true)
  }

  static var received: URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return documents.appendingPathComponent("CopySync", isDirectory: true)
  }

  static var outgoing: URL {
    return cacheRoot.appendingPathComponent("待发送", isDirectory: true)
  }

  static func ensureFolders() {
    let historyImages = cacheRoot.appendingPathComponent("历史截图", isDirectory: true)
    for url in [cacheRoot, historyImages, received, outgoing] {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    // 迁移旧接收目录（CopySync.m:325-331）。
    let legacy = [
      cacheRoot.appendingPathComponent("接收文件", isDirectory: true),
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("CopySync 接收文件", isDirectory: true),
    ]
    for dir in legacy {
      let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for file in files {
        try? FileManager.default.moveItem(at: file, to: uniqueReceivedURL(name: file.lastPathComponent))
      }
    }
  }

  // 重名加 8 位随机后缀（CopySync.m:1215-1224）。
  static func uniqueReceivedURL(name: String) -> URL {
    let safeName = URL(fileURLWithPath: name).lastPathComponent
    let base = safeName.isEmpty ? "CopySync-file" : safeName
    var destination = received.appendingPathComponent(base)
    if !FileManager.default.fileExists(atPath: destination.path) { return destination }
    let ext = destination.pathExtension
    let stem = destination.deletingPathExtension().lastPathComponent
    let suffix = String(UUID().uuidString.prefix(8))
    let uniqueName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
    destination = received.appendingPathComponent(uniqueName)
    return destination
  }
}

// MARK: - 全局快捷键（CopySync.m:1053-1088，Carbon RegisterEventHotKey）

private func bridgeHotKeyHandler(
  nextHandler: EventHandlerCallRef?, event: EventRef?, userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event = event, let userInfo = userInfo else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  GetEventParameter(
    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
  let plugin = Unmanaged<BridgePlugin>.fromOpaque(userInfo).takeUnretainedValue()
  let id: String
  switch hotKeyID.id {
  case 2: id = "screenshot"
  case 3: id = "history"
  default: id = "main"
  }
  DispatchQueue.main.async { plugin.emit("hotkey.pressed", ["id": id]) }
  return noErr
}

// MARK: - 桥接插件主体

final class BridgePlugin: NSObject {
  private let channel: FlutterMethodChannel
  private let history = HistoryStore()
  private var watchTimer: Timer?
  private var pasteboardChangeCount: Int = 0
  private var previousApplication: NSRunningApplication?
  private var hotKeyRefs = [String: EventHotKeyRef]()
  private var hotKeyHandlerRef: EventHandlerRef?
  private var captureProcess: Process?
  private var captureResult: FlutterResult?
  private var captureBeforeChangeCount: Int = 0
  private var menubar: MenubarController?
  private var lastStatus = "等待复制"

  private static var shared: BridgePlugin?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: bridgeChannelName, binaryMessenger: messenger)
    let plugin = BridgePlugin(channel: channel)
    channel.setMethodCallHandler(plugin.handle(_:result:))
    shared = plugin
    NSLog("CopySyncBridge: channel %@ registered", bridgeChannelName)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    BridgePaths.ensureFolders()
    history.load()
    history.onChanged = { [weak self] in self?.emit("history.changed", nil) }
    pasteboardChangeCount = NSPasteboard.general.changeCount
    if UserDefaults.standard.string(forKey: historyShortcutKey) == nil {
      UserDefaults.standard.set("commandComma", forKey: historyShortcutKey)
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(workspaceActivated(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    menubar = MenubarController(plugin: self)
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func workspaceActivated(_ notification: Notification) {
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    else { return }
    previousApplication = app
  }

  func emit(_ name: String, _ arguments: Any?) {
    channel.invokeMethod(name, arguments: arguments)
  }

  // MARK: 分发

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "menubar.setStatus":
      setStatus(ok: args?["ok"] as? Bool ?? true, message: args?["message"] as? String ?? "")
      result(nil)
    case "menubar.showMainWindow":
      showMainWindow()
      result(nil)
    case "menubar.toggleMainWindow":
      if let window = NSApp.windows.first, window.isVisible {
        window.orderOut(nil)
      } else {
        showMainWindow()
      }
      result(nil)
    case "hotkey.register":
      registerHotKey(result, id: args?["id"] as? String ?? "", shortcut: args?["shortcut"] as? String)
    case "hotkey.unregister":
      unregisterHotKey(args?["id"] as? String ?? "")
      result(nil)
    case "clipboard.watch":
      startWatch()
      result(true)
    case "clipboard.stop":
      watchTimer?.invalidate()
      watchTimer = nil
      result(nil)
    case "clipboard.readText":
      result(NSPasteboard.general.string(forType: .string))
    case "clipboard.readImage":
      result(readImageFromPasteboard(NSPasteboard.general)?.base64EncodedString())
    case "clipboard.write":
      writeClipboard(result, args: args)
    case "clipboard.ignoreNext":
      UserDefaults.standard.set(true, forKey: ignoreNextCopyKey)
      setStatus(ok: true, message: "下一次复制将被忽略")
      result(nil)
    case "screenshot.captureRegion":
      captureRegion(result)
    case "paste.intoPreviousApp":
      pasteIntoPreviousApp(result, args: args)
    case "history.list":
      result(history.items)
    case "history.addText":
      guard let text = args?["text"] as? String, let item = history.addText(text) else {
        result(bridgeError("invalid_args", "历史文本为空"))
        return
      }
      result(item)
    case "history.addImage":
      guard let base64 = args?["dataBase64"] as? String, let png = Data(base64Encoded: base64),
        let item = history.addImage(png: png, title: args?["title"] as? String ?? "图片")
      else {
        result(bridgeError("system_error", "无法保存本地图片历史"))
        return
      }
      result(item)
    case "history.copy":
      copyHistoryItem(result, id: args?["id"] as? String ?? "")
    case "history.remove":
      if history.remove(id: args?["id"] as? String ?? "") {
        result(nil)
      } else {
        result(bridgeError("not_found", "历史条目不存在"))
      }
    case "history.clear":
      history.clear()
      setStatus(ok: true, message: "本地历史已清空")
      result(nil)
    case "history.setPinned":
      history.isPinned = args?["pinned"] as? Bool ?? true
      result(nil)
    case "history.isPinned":
      result(history.isPinned)
    case "permissions.status":
      result([
        "screenRecording": CGPreflightScreenCaptureAccess(),
        "postEvent": CGPreflightPostEventAccess(),
      ])
    case "permissions.request":
      requestPermission(result, type: args?["type"] as? String ?? "")
    case "loginItem.set":
      setLoginItem(result, enabled: args?["enabled"] as? Bool ?? false)
    case "loginItem.isEnabled":
      if #available(macOS 13.0, *) {
        result(SMAppService.mainApp.status == .enabled)
      } else {
        result(bridgeError("unavailable", "登录启动需要 macOS 13+"))
      }
    case "notify.show":
      showNotification(args: args)
      result(nil)
    case "files.saveSent":
      saveFile(result, args: args, storageKey: { "sent:\($0)" })
    case "files.saveReceived":
      saveFile(result, args: args, storageKey: { $0 })
    case "files.revealReceived":
      revealReceived(result, args: args)
    case "cache.usage":
      result(cacheUsage())
    case "cache.clear":
      clearCache()
      result(nil)
    case "update.check":
      UpdateManager.check(manifestURL: args?["url"] as? String ?? updateManifestURL, result: result)
    case "update.download":
      UpdateManager.download(
        result, url: args?["url"] as? String ?? "", sha256: args?["sha256"] as? String ?? "")
    case "update.install":
      UpdateManager.install(result, zipPath: args?["path"] as? String ?? "")
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 状态与窗口

  func setStatus(ok: Bool, message: String) {
    lastStatus = message
    menubar?.setStatus(message)
  }

  private func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }

  // MARK: 全局快捷键

  private func installHotKeyHandlerIfNeeded() -> OSStatus {
    if hotKeyHandlerRef != nil { return noErr }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    // InstallApplicationEventHandler 已从新版 SDK 移除，用 InstallEventHandler
    // 挂到应用事件目标，语义相同。
    return InstallEventHandler(
      GetApplicationEventTarget(), bridgeHotKeyHandler, 1, &eventType,
      Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
  }

  private func registerHotKey(_ result: FlutterResult, id: String, shortcut: String?) {
    let signature = OSType(0x43505359)  // 'CPSY'
    let key: UInt32
    let modifiers: UInt32
    let hotKeyID: EventHotKeyID
    switch id {
    case "main":
      key = UInt32(kVK_ANSI_Period); modifiers = UInt32(cmdKey)
      hotKeyID = EventHotKeyID(signature: signature, id: 1)
    case "screenshot":
      key = UInt32(kVK_ANSI_J); modifiers = UInt32(cmdKey)
      hotKeyID = EventHotKeyID(signature: signature, id: 2)
    case "history":
      let choice = shortcut ?? UserDefaults.standard.string(forKey: historyShortcutKey) ?? "commandComma"
      if let shortcut = shortcut { UserDefaults.standard.set(shortcut, forKey: historyShortcutKey) }
      switch choice {
      case "option": key = UInt32(kVK_ANSI_V); modifiers = UInt32(optionKey)
      case "commandShift": key = UInt32(kVK_ANSI_V); modifiers = UInt32(cmdKey | shiftKey)
      default: key = UInt32(kVK_ANSI_Comma); modifiers = UInt32(cmdKey)
      }
      hotKeyID = EventHotKeyID(signature: signature, id: 3)
    default:
      result(bridgeError("invalid_args", "未知快捷键 id：\(id)"))
      return
    }
    unregisterHotKey(id)
    let handlerStatus = installHotKeyHandlerIfNeeded()
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      key, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    if handlerStatus == noErr && status == noErr, let ref = ref {
      hotKeyRefs[id] = ref
      result(nil)
    } else {
      result(bridgeError("hotkey_failed", "全局快捷键注册失败（\(status != noErr ? status : handlerStatus)）"))
    }
  }

  private func unregisterHotKey(_ id: String) {
    if let ref = hotKeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
  }

  // MARK: 剪贴板监听（CopySync.m:1420-1440，0.45s 轮询 + 标记 + ignoreNext）

  private func startWatch() {
    if watchTimer != nil { return }
    pasteboardChangeCount = NSPasteboard.general.changeCount
    watchTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
      self?.watchPasteboard()
    }
  }

  private func watchPasteboard() {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != pasteboardChangeCount else { return }
    pasteboardChangeCount = pasteboard.changeCount
    if pasteboard.availableType(from: [markerPasteboardType]) != nil { return }
    if UserDefaults.standard.bool(forKey: ignoreNextCopyKey) {
      UserDefaults.standard.set(false, forKey: ignoreNextCopyKey)
      setStatus(ok: true, message: "已忽略一次复制")
      return
    }
    if let png = readImageFromPasteboard(pasteboard) {
      if let item = history.addImage(png: png, title: "复制的图片") {
        setStatus(ok: true, message: "图片已保存到本地历史")
        emit("clipboard.changed", item)
      }
      return
    }
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    if let item = history.addText(text) {
      setStatus(ok: true, message: "文本已保存到本地历史")
      emit("clipboard.changed", item)
    }
  }

  // PNG 优先，TIFF 转 PNG（CopySync.m:397-404）。
  private func readImageFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
    if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
    guard let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty,
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  // MARK: 剪贴板写入（带自写标记，CopySync.m:411-431）

  private func writeClipboard(_ result: FlutterResult, args: [String: Any]?) {
    let kind = args?["kind"] as? String ?? "text"
    let pasteItem = NSPasteboardItem()
    if kind == "image" {
      guard let base64 = args?["dataBase64"] as? String, let png = Data(base64Encoded: base64)
      else {
        result(bridgeError("invalid_args", "clipboard.write 缺少图片数据"))
        return
      }
      pasteItem.setData(png, forType: .png)
    } else {
      pasteItem.setString(args?["text"] as? String ?? "", forType: .string)
    }
    pasteItem.setString("", forType: markerPasteboardType)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([pasteItem]) else {
      result(bridgeError("system_error", "复制失败"))
      return
    }
    pasteboardChangeCount = pasteboard.changeCount
    if args?["ignoreNext"] as? Bool == true {
      UserDefaults.standard.set(true, forKey: ignoreNextCopyKey)
    }
    result(nil)
  }

  private func copyHistoryItem(_ result: FlutterResult, id: String) {
    guard let item = history.item(id: id) else {
      result(bridgeError("not_found", "历史条目不存在"))
      return
    }
    if item["kind"] as? String == "image" {
      let path = item["path"] as? String ?? ""
      guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
        result(bridgeError("not_found", "历史图片文件已不存在"))
        return
      }
      writeClipboard(result, args: ["kind": "image", "dataBase64": data.base64EncodedString()])
    } else {
      writeClipboard(result, args: ["kind": "text", "text": item["text"] as? String ?? ""])
    }
  }

  // MARK: 区域截图（CopySync.m:863-893，screencapture -i -c -x）

  private func captureRegion(_ result: @escaping FlutterResult) {
    guard captureProcess == nil else {
      result(bridgeError("system_error", "已有截图任务进行中"))
      return
    }
    guard CGPreflightScreenCaptureAccess() else {
      requestScreenRecording()
      result(bridgeError("permission_denied", "需要屏幕录制权限才能截图"))
      return
    }
    captureBeforeChangeCount = NSPasteboard.general.changeCount
    captureResult = result
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-c", "-x"]
    task.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async { self?.captureTerminated() }
    }
    do {
      captureProcess = task
      try task.run()
      setStatus(ok: true, message: "请框选截图区域")
    } catch {
      captureProcess = nil
      let pending = captureResult
      captureResult = nil
      pending?(bridgeError("system_error", error.localizedDescription))
    }
  }

  private func captureTerminated() {
    captureProcess = nil
    guard let result = captureResult else { return }
    captureResult = nil
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != captureBeforeChangeCount,
      let png = pasteboard.data(forType: .png), !png.isEmpty
    else {
      result(bridgeError("cancelled", "已取消区域截图"))
      return
    }
    pasteboardChangeCount = pasteboard.changeCount
    guard let item = history.addImage(png: png, title: "区域截图") else {
      result(bridgeError("system_error", "无法保存本地图片历史"))
      return
    }
    setStatus(ok: true, message: "截图已保存到本地历史")
    result(item)
  }

  // MARK: 粘贴到前一应用（CopySync.m:817-832/1533-1567）

  private func pasteIntoPreviousApp(_ result: @escaping FlutterResult, args: [String: Any]?) {
    var writeError: FlutterError?
    writeClipboard({ value in
      if let error = value as? FlutterError { writeError = error }
    }, args: args)
    if let error = writeError {
      result(error)
      return
    }
    guard CGPreflightPostEventAccess() else {
      requestPostEventAccess()
      result(bridgeError("permission_denied", "内容已复制；允许辅助功能后，再点击即可直接粘贴"))
      return
    }
    guard let target = previousApplication else {
      result(bridgeError("not_found", "内容已复制；请先打开要粘贴的窗口后再点历史"))
      return
    }
    pasteInto(application: target, attempt: 0, result: result)
  }

  private func pasteInto(
    application: NSRunningApplication, attempt: Int, result: @escaping FlutterResult
  ) {
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != application.processIdentifier && attempt < 12 {
      application.activate(options: .activateAllWindows)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.pasteInto(application: application, attempt: attempt + 1, result: result)
      }
      return
    }
    sendCommandV()
    setStatus(ok: true, message: "已粘贴到 \(application.localizedName ?? "当前窗口")")
    result(nil)
  }

  private func sendCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keys: [CGKeyCode] = [
      CGKeyCode(kVK_Command), CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_Command),
    ]
    let downs = [true, true, false, false]
    for index in 0..<4 {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: keys[index], keyDown: downs[index])
      else { continue }
      if index < 3 { event.flags = .maskCommand }
      event.setIntegerValueField(.eventSourceUserData, value: pasteSignature)
      event.post(tap: .cgSessionEventTap)
    }
  }

  // MARK: 权限（CopySync.m:900-929）

  private func openPrivacyPane(_ anchor: String) {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func requestScreenRecording() {
    if CGRequestScreenCaptureAccess() { return }
    openPrivacyPane("Privacy_ScreenCapture")
  }

  private func requestPostEventAccess() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if !CGRequestPostEventAccess() {
      openPrivacyPane("Privacy_Accessibility")
    }
  }

  private func requestPermission(_ result: FlutterResult, type: String) {
    switch type {
    case "screenRecording":
      if CGPreflightScreenCaptureAccess() {
        result(true)
      } else if CGRequestScreenCaptureAccess() {
        result(true)
      } else {
        openPrivacyPane("Privacy_ScreenCapture")
        result(bridgeError("permission_denied", "允许屏幕录制并重启 CopySync 后即可截图"))
      }
    case "postEvent":
      if CGPreflightPostEventAccess() {
        result(true)
      } else {
        requestPostEventAccess()
        if CGPreflightPostEventAccess() {
          result(true)
        } else {
          result(bridgeError("permission_denied", "请在系统设置的辅助功能中允许 CopySync，然后重新打开应用"))
        }
      }
    default:
      result(bridgeError("invalid_args", "未知权限类型：\(type)"))
    }
  }

  // MARK: 登录启动（CopySync.m:1090-1100，SMAppService）

  private func setLoginItem(_ result: FlutterResult, enabled: Bool) {
    guard #available(macOS 13.0, *) else {
      result(bridgeError("unavailable", "登录启动需要 macOS 13+"))
      return
    }
    do {
      let service = SMAppService.mainApp
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
      result(nil)
    } catch {
      result(bridgeError("system_error", error.localizedDescription))
    }
  }

  // MARK: 通知（CopySync.m:1476-1481）

  private func showNotification(args: [String: Any]?) {
    let content = UNMutableNotificationContent()
    content.title = args?["title"] as? String ?? "CopySync"
    content.body = args?["body"] as? String ?? ""
    content.sound = .default
    let identifier = args?["id"] as? String ?? UUID().uuidString
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }

  // MARK: 接收文件（CopySync.m:543-569/1215-1315；V3 中下载由 Dart ApiClient 完成，原生只负责落盘与定位）

  private var receivedDeliveryPaths: [String: String] {
    get { UserDefaults.standard.dictionary(forKey: receivedDeliveryPathsKey) as? [String: String] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: receivedDeliveryPathsKey) }
  }

  private func saveFile(
    _ result: FlutterResult, args: [String: Any]?, storageKey: (String) -> String
  ) {
    let name = args?["name"] as? String ?? ""
    let rawID = (args?["itemId"] as? String) ?? (args?["deliveryId"] as? String) ?? ""
    guard let base64 = args?["dataBase64"] as? String, let data = Data(base64Encoded: base64)
    else {
      result(bridgeError("invalid_args", "缺少文件数据"))
      return
    }
    let key = storageKey(rawID)
    if !key.isEmpty, let saved = receivedDeliveryPaths[key],
      FileManager.default.fileExists(atPath: saved)
    {
      // 已落盘：直接定位（CopySync.m:1279-1283）。
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved)])
      result(saved)
      return
    }
    BridgePaths.ensureFolders()
    let destination = BridgePaths.uniqueReceivedURL(name: name)
    do {
      try data.write(to: destination, options: .atomic)
    } catch {
      result(bridgeError("system_error", "保存文件失败：\(error.localizedDescription)"))
      return
    }
    if !key.isEmpty {
      var paths = receivedDeliveryPaths
      paths[key] = destination.path
      receivedDeliveryPaths = paths
    }
    NSWorkspace.shared.activateFileViewerSelecting([destination])
    result(destination.path)
  }

  private func revealReceived(_ result: FlutterResult, args: [String: Any]?) {
    BridgePaths.ensureFolders()
    let deliveryID = args?["deliveryId"] as? String ?? ""
    let name = args?["name"] as? String ?? ""
    var fileURL: URL? = nil
    if !deliveryID.isEmpty, let saved = receivedDeliveryPaths[deliveryID],
      FileManager.default.fileExists(atPath: saved)
    {
      fileURL = URL(fileURLWithPath: saved)
    }
    if fileURL == nil {
      // 按名字模糊匹配（CopySync.m:547-557）。
      let safeName = URL(fileURLWithPath: name).lastPathComponent
      let base = safeName.isEmpty ? "CopySync-file" : safeName
      let files = (try? FileManager.default.contentsOfDirectory(
        at: BridgePaths.received, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      fileURL = files.first { candidate in
        if candidate.lastPathComponent == base { return true }
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        let candidateStem = candidate.deletingPathExtension().lastPathComponent
        return (ext.isEmpty || candidate.pathExtension == ext)
          && candidateStem.hasPrefix("\(stem)-")
      }
    }
    guard let found = fileURL, FileManager.default.fileExists(atPath: found.path) else {
      NSWorkspace.shared.open(BridgePaths.received)
      result(bridgeError("not_ready", "文件仍在接收中，请稍后再点一次"))
      return
    }
    if !deliveryID.isEmpty {
      var paths = receivedDeliveryPaths
      paths[deliveryID] = found.path
      receivedDeliveryPaths = paths
    }
    NSWorkspace.shared.activateFileViewerSelecting([found])
    result(found.path)
  }

  // MARK: 缓存（CopySync.m:491-517/588-601）

  private func sizeOfDirectory(_ directory: URL, excludingHistory: Bool) -> UInt64 {
    var total: UInt64 = 0
    let historyPath = history.historyImagesURL.path
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      options: .skipsHiddenFiles)
    else { return 0 }
    for case let url as URL in enumerator {
      if excludingHistory && url.path.hasPrefix(historyPath) {
        enumerator.skipDescendants()
        continue
      }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
    }
    return total
  }

  private func cacheUsage() -> [String: Any] {
    let screenshots = history.items.filter { $0["kind"] as? String == "image" }.count
    return [
      "historyCount": history.items.count,
      "historyLimit": historyLimit,
      "screenshotCount": screenshots,
      "screenshotBytes": sizeOfDirectory(history.historyImagesURL, excludingHistory: false),
      "cacheBytes": sizeOfDirectory(BridgePaths.cacheRoot, excludingHistory: true),
    ]
  }

  private func clearCache() {
    // 只清理待发送缓存，不动历史截图与已接收文件（CopySync.m:595-598）。
    try? FileManager.default.removeItem(at: BridgePaths.outgoing)
    try? FileManager.default.createDirectory(at: BridgePaths.outgoing, withIntermediateDirectories: true)
    setStatus(ok: true, message: "临时缓存已清理")
  }
}

// MARK: - 菜单栏（CopySync.m:143-194 全量菜单项）

final class MenubarController: NSObject, NSMenuDelegate {
  private weak var plugin: BridgePlugin?
  private let statusItem: NSStatusItem
  private let statusMenu = NSMenu()
  private let statusMenuItem = NSMenuItem(title: "状态：等待复制", action: nil, keyEquivalent: "")
  private let historyCountMenuItem = NSMenuItem(title: "本地历史 0 / 10", action: nil, keyEquivalent: "")
  private let screenshotUsageMenuItem = NSMenuItem(title: "历史截图 0 张 · 0 B", action: nil, keyEquivalent: "")
  private let cacheUsageMenuItem = NSMenuItem(title: "临时文件缓存 0 B", action: nil, keyEquivalent: "")

  init(plugin: BridgePlugin) {
    self.plugin = plugin
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    let icon = NSImage(
      systemSymbolName: "clipboard", accessibilityDescription: "CopySync 剪贴板历史")
    icon?.isTemplate = true
    statusItem.button?.image = icon
    statusItem.button?.title = ""
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusMenu.delegate = self
    buildMenu()
  }

  private func buildMenu() {
    statusMenu.addItem(historyCountMenuItem)
    statusMenu.addItem(screenshotUsageMenuItem)
    statusMenu.addItem(cacheUsageMenuItem)
    statusMenu.addItem(.separator())
    addAction("打开历史（⌘,）", action: "openHistory")
    addAction("打开跨设备传输（⌘.）", action: "openTransfers")
    addNative("打开临时文件夹", #selector(openCacheFolder))
    addNative("打开接收文件夹", #selector(openReceivedFolder))
    addAction("清空历史记录…", action: "clearHistory")
    addAction("清理临时缓存…", action: "clearCache")
    statusMenu.addItem(.separator())
    addAction("区域截图到历史（⌘J）", action: "captureRegion")
    addNative("屏幕录制权限…", #selector(requestScreenRecording))
    addAction("检查更新…", action: "checkUpdate")
    statusMenu.addItem(statusMenuItem)
    addNative("忽略下一次复制", #selector(ignoreNextCopy))
    addAction("显示底部状态栏", action: "toggleFooter")
    addAction("偏好设置…", action: "openPreferences")
    addNative("登录时启动", #selector(toggleLaunchAtLogin))
    addNative("请求粘贴权限", #selector(requestPastePermission))
    statusMenu.addItem(.separator())
    statusMenu.addItem(withTitle: "退出", action: #selector(terminateApp), keyEquivalent: "q")
  }

  private func addAction(_ title: String, action: String) {
    let item = NSMenuItem(title: title, action: #selector(emitAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = action
    statusMenu.addItem(item)
  }

  private func addNative(_ title: String, _ selector: Selector) {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    item.target = self
    statusMenu.addItem(item)
  }

  @objc private func emitAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? String else { return }
    plugin?.emit("menubar.action", ["action": action])
  }

  @objc private func statusItemClicked(_ sender: AnyObject?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      statusItem.menu = statusMenu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
    } else {
      // 左键 = 历史浮窗开关（V3 由 Flutter 渲染，Task 24 接线）。
      plugin?.emit("menubar.action", ["action": "toggleHistory"])
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard let plugin = plugin else { return }
    let usage = plugin.cacheUsagePublic
    historyCountMenuItem.title = "本地历史 \(usage["historyCount"] ?? 0) / \(usage["historyLimit"] ?? 10)"
    screenshotUsageMenuItem.title =
      "历史截图 \(usage["screenshotCount"] ?? 0) 张 · \(formattedBytes(usage["screenshotBytes"] ?? 0))"
    cacheUsageMenuItem.title = "临时文件缓存 \(formattedBytes(usage["cacheBytes"] ?? 0))"
  }

  private func formattedBytes(_ raw: Any?) -> String {
    let bytes = (raw as? UInt64) ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  func setStatus(_ message: String) {
    statusMenuItem.title = "状态：\(message)"
  }

  @objc private func openCacheFolder() {
    BridgePaths.ensureFolders()
    NSWorkspace.shared.open(BridgePaths.cacheRoot)
  }

  @objc private func openReceivedFolder() {
    BridgePaths.ensureFolders()
    NSWorkspace.shared.open(BridgePaths.received)
  }

  @objc private func requestScreenRecording() {
    if CGPreflightScreenCaptureAccess() {
      plugin?.setStatus(ok: true, message: "屏幕录制权限已开启")
      return
    }
    if CGRequestScreenCaptureAccess() {
      plugin?.setStatus(ok: true, message: "屏幕录制权限已开启，请再次使用 ⌘J")
      return
    }
    NSWorkspace.shared.open(URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    plugin?.setStatus(ok: false, message: "允许屏幕录制并重启 CopySync 后即可截图")
  }

  @objc private func ignoreNextCopy() {
    UserDefaults.standard.set(true, forKey: ignoreNextCopyKey)
    plugin?.setStatus(ok: true, message: "下一次复制将被忽略")
  }

  @objc private func toggleLaunchAtLogin() {
    guard #available(macOS 13.0, *) else {
      plugin?.setStatus(ok: false, message: "登录启动需要 macOS 13+")
      return
    }
    do {
      let service = SMAppService.mainApp
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
      }
      plugin?.setStatus(ok: true, message: "登录启动设置已更新")
    } catch {
      plugin?.setStatus(ok: false, message: error.localizedDescription)
    }
  }

  @objc private func requestPastePermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if CGRequestPostEventAccess() {
      plugin?.setStatus(ok: true, message: "辅助功能权限已开启，可以点击历史直接粘贴")
    } else {
      NSWorkspace.shared.open(URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
      plugin?.setStatus(ok: false, message: "请在系统设置的辅助功能中允许 CopySync，然后重新打开应用")
    }
  }

  @objc private func terminateApp() {
    NSApp.terminate(nil)
  }
}

extension BridgePlugin {
  // 供菜单栏刷新用量行使用。
  var cacheUsagePublic: [String: Any] { cacheUsage() }
}

// MARK: - 检查/下载/覆盖安装更新（CopySync.m:931-1051，含 SHA-256 校验）

enum UpdateManager {
  static func check(manifestURL: String, result: @escaping FlutterResult) {
    guard let url = URL(string: manifestURL) else {
      result(bridgeError("invalid_args", "更新清单地址无效"))
      return
    }
    URLSession.shared.dataTask(with: url) { data, _, error in
      DispatchQueue.main.async {
        guard error == nil, let data = data,
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          result(bridgeError("system_error", "检查更新失败"))
          return
        }
        let latest = manifest["version"] as? String ?? ""
        let current =
          Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let newer =
          !latest.isEmpty
          && latest.compare(current, options: .numeric) == .orderedDescending
        result([
          "current": current,
          "latest": latest,
          "hasUpdate": newer,
          "notes": manifest["notes"] as? String ?? "",
          "url": manifest["url"] as? String ?? "",
          "sha256": manifest["sha256"] as? String ?? "",
        ])
      }
    }.resume()
  }

  static func download(_ result: @escaping FlutterResult, url: String, sha256: String) {
    guard let remote = URL(string: url), !sha256.isEmpty else {
      result(bridgeError("invalid_args", "更新清单无效"))
      return
    }
    let expected = sha256.lowercased()
    URLSession.shared.downloadTask(with: remote) { location, _, error in
      DispatchQueue.main.async {
        let zip = FileManager.default.temporaryDirectory
          .appendingPathComponent("CopySync-update-\(UUID().uuidString).zip")
        var copied = false
        if let location = location {
          copied = (try? FileManager.default.copyItem(at: location, to: zip)) != nil
        }
        guard error == nil, copied,
          let data = try? Data(contentsOf: zip, options: .mappedIfSafe)
        else {
          try? FileManager.default.removeItem(at: zip)
          result(bridgeError("system_error", "更新下载失败"))
          return
        }
        guard sha256Hex(data) == expected else {
          try? FileManager.default.removeItem(at: zip)
          result(bridgeError("checksum_mismatch", "更新下载或校验失败"))
          return
        }
        result(zip.path)
      }
    }.resume()
  }

  private static func runTask(_ executable: String, _ arguments: [String]) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    do {
      try task.run()
    } catch {
      return false
    }
    task.waitUntilExit()
    return task.terminationStatus == 0
  }

  private static func shellQuote(_ value: String) -> String {
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  static func install(_ result: @escaping FlutterResult, zipPath: String) {
    DispatchQueue.global(qos: .userInitiated).async {
      let zip = URL(fileURLWithPath: zipPath)
      let unpack = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopySync-unpack-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
      guard runTask("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path]) else {
        DispatchQueue.main.async { result(bridgeError("system_error", "无法解压更新")) }
        return
      }
      // 旧实现硬编码 CopySync.app；这里改为扫描解压目录中的第一个 .app
      // 并校验主可执行文件存在（Flutter 产物名与旧包不同）。
      let unpacked = (try? FileManager.default.contentsOfDirectory(
        at: unpack, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      guard
        let source = unpacked.first(where: {
          $0.pathExtension == "app"
            && FileManager.default.fileExists(
              atPath: $0.appendingPathComponent("Contents/MacOS/\($0.deletingPathExtension().lastPathComponent)").path)
        })
      else {
        DispatchQueue.main.async { result(bridgeError("system_error", "更新包不完整")) }
        return
      }
      let destination = Bundle.main.bundlePath
      let helper = FileManager.default.temporaryDirectory
        .appendingPathComponent("copysync-update-\(UUID().uuidString).sh")
      let script = """
        #!/bin/sh
        set -eu
        dest=$1
        src=$2
        old="${dest}.update-old"
        rm -rf "$old"
        mv "$dest" "$old"
        mv "$src" "$dest"
        rm -rf "$old"
        """
      try? script.write(to: helper, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: helper.path)
      let writable = FileManager.default.isWritableFile(
        atPath: (destination as NSString).deletingLastPathComponent)
      let installed: Bool
      if writable {
        installed = runTask(helper.path, [destination, source.path])
      } else {
        let command = "\(shellQuote(helper.path)) \(shellQuote(destination)) \(shellQuote(source.path))"
        let escaped = command
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
        installed = runTask(
          "/usr/bin/osascript",
          ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
      }
      guard installed else {
        DispatchQueue.main.async { result(bridgeError("system_error", "更新安装失败")) }
        return
      }
      DispatchQueue.main.async {
        result(nil)
        // 覆盖安装完成后重启（CopySync.m:1042-1048）。
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "CopySyncUpdater", destination]
        try? relaunch.run()
        NSApp.terminate(nil)
      }
    }
  }
}
