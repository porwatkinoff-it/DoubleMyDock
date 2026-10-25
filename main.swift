// DoubleMyDock — копия системного Дока на всех мониторах, где его нет.
//
// Устройство:
//  • Всё общение с настоящим Доком (Accessibility), список окон и настройки читаются
//    в отдельном фоновом потоке с короткими таймаутами. Главный поток никогда не ждёт Док,
//    поэтому копия не подвисает, даже если Док занят.
//  • Главный поток только раскладывает и рисует панели.
//  • Копия прячется только в полноэкранных программах (и при автоскрытии Дока).
//    Развёрнутые окна укорачиваются, чтобы не заходить под копию, — как macOS делает для Дока.
//  • Журнал: ~/Library/Logs/DoubleMyDock.log (правый клик по пустому месту копии → «Открыть журнал»).

import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

let finderPath = "/System/Library/CoreServices/Finder.app"

// MARK: - Журнал

final class Logger {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DoubleMyDock.log")
    private let q = DispatchQueue(label: "doublemydock.log", qos: .utility)
    private var handle: FileHandle?
    private var written = 0
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func write(_ text: String) {
        let now = Date()
        q.async { [self] in
            if handle == nil || written > 2_000_000 { open() }
            let line = "\(df.string(from: now))  \(text)\n"
            if let d = line.data(using: .utf8) {
                try? handle?.write(contentsOf: d)
                written += d.count
            }
        }
    }

    private func open() {
        try? handle?.close()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        written = 0
    }
}

let logger = Logger()
func dlog(_ s: String) { logger.write(s) }

// MARK: - Модель

enum Orientation: String { case bottom, left, right }

struct Item: Equatable {
    enum Kind: Equatable { case app, folder, file, url, trash, minimized, separator, spacer }
    var kind: Kind
    var title: String
    var path: String?
    var url: URL?
    var running: Bool
    var badge: String?
    var axIndex: Int
}

struct Geometry: Equatable {
    var orientation: Orientation = .bottom
    var barLength: CGFloat = 0     // длина панели вдоль Дока
    var barThickness: CGFloat = 64 // «высота» панели
    var gap: CGFloat = 4           // от края экрана до панели
    var icon: CGFloat = 48         // размер значка
    var centers: [CGFloat] = []    // центры элементов от начала панели
}

struct DockPrefs: Equatable {
    var tile: CGFloat = 48
    var magnification = false
    var large: CGFloat = 64
    var autohide = false
    var orientation: Orientation = .bottom
    var pinned: [String] = []
    var recents: [String] = []
    var showRecents = true

    static func read() -> DockPrefs {
        let d = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(d)
        func v(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, d) }
        var p = DockPrefs()
        if let n = v("tilesize") as? NSNumber { p.tile = min(max(CGFloat(n.doubleValue), 16), 128) }
        p.magnification = (v("magnification") as? NSNumber)?.boolValue ?? false
        if let n = v("largesize") as? NSNumber { p.large = min(max(CGFloat(n.doubleValue), p.tile), 128) }
        p.autohide = (v("autohide") as? NSNumber)?.boolValue ?? false
        p.orientation = Orientation(rawValue: (v("orientation") as? String) ?? "bottom") ?? .bottom
        func paths(_ key: String) -> [String] {
            guard let arr = v(key) as? [[String: Any]] else { return [] }
            return arr.compactMap { e in
                guard let t = e["tile-data"] as? [String: Any],
                      let f = t["file-data"] as? [String: Any],
                      let s = f["_CFURLString"] as? String else { return nil }
                let u = s.hasPrefix("/") ? URL(fileURLWithPath: s) : URL(string: s)
                guard let u, u.isFileURL else { return nil }
                return u.standardizedFileURL.path
            }
        }
        p.pinned = paths("persistent-apps")
        p.recents = paths("recent-apps")
        p.showRecents = (v("show-recents") as? NSNumber)?.boolValue ?? true
        return p
    }
}

struct AXSnapshot {
    var items: [Item]
    var frames: [CGRect]   // в координатах AX (от левого верхнего угла основного экрана)
    var list: CGRect
}

struct WinInfo {
    var pid: pid_t
    var layer: Int
    var owner: String
    var bounds: CGRect     // в координатах CG (от левого верхнего угла основного экрана)
    var alpha: Double
}

struct Snapshot {
    var trusted: Bool
    var prefs: DockPrefs
    var ax: AXSnapshot?
    var trashFull: Bool
    var windows: [WinInfo]
}

// MARK: - Чтение настоящего Дока через Accessibility (только в фоновом потоке)

final class DockReader {
    struct MenuNode {
        var title: String
        var enabled: Bool
        var mark: String
        var children: [MenuNode]
    }

    private(set) var pid: pid_t = 0
    private var appEl: AXUIElement?
    private var listEl: AXUIElement?
    private var elements: [AXUIElement] = []
    private static let attrs = [kAXSubroleAttribute, kAXTitleAttribute, "AXURL", "AXIsApplicationRunning",
                                "AXStatusLabel", kAXPositionAttribute, kAXSizeAttribute] as CFArray

    init() {
        // По умолчанию система ждёт ответа до 6 секунд — отсюда были зависания.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    private func copy(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private func str(_ e: AXUIElement, _ a: String) -> String? { copy(e, a) as? String }
    private func children(_ e: AXUIElement) -> [AXUIElement] { (copy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    private func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(copy(e, kAXPositionAttribute)), let s = size(copy(e, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private func reset() { appEl = nil; listEl = nil; elements = [] }

    /// Читает все значки Дока. Одно обращение к Доку на значок (вместо семи).
    func read() -> AXSnapshot? {
        if appEl == nil {
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            else { return nil }
            pid = dock.processIdentifier
            appEl = AXUIElementCreateApplication(pid)
            listEl = nil
        }
        guard let appEl else { return nil }
        if listEl == nil {
            listEl = children(appEl).first { str($0, kAXRoleAttribute) == kAXListRole }
        }
        guard let list = listEl, let listFrame = frame(list) else { reset(); return nil }
        let kids = children(list)
        guard !kids.isEmpty else { reset(); return nil }

        var items: [Item] = [], frames: [CGRect] = []
        items.reserveCapacity(kids.count)
        for (i, e) in kids.enumerated() {
            var raw: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(e, DockReader.attrs, AXCopyMultipleAttributeOptions(), &raw)
            if err == .cannotComplete { return nil }          // Док занят — попробуем в следующий раз
            let vals: [AnyObject] = err == .success ? (((raw as AnyObject?) as? [AnyObject]) ?? []) : []
            func v(_ k: Int) -> CFTypeRef? {
                guard k < vals.count else { return nil }
                let x = vals[k] as CFTypeRef
                if CFGetTypeID(x) == AXValueGetTypeID(), AXValueGetType(x as! AXValue) == .axError { return nil }
                return x
            }
            let sub = v(0) as? String ?? ""
            let title = v(1) as? String ?? ""
            let url = v(2) as? URL
            let running = (v(3) as? NSNumber)?.boolValue ?? false
            let badge = (v(4) as? String).flatMap { $0.isEmpty ? nil : $0 }
            let kind: Item.Kind
            switch sub {
            case "AXApplicationDockItem": kind = .app
            case "AXFolderDockItem": kind = .folder
            case "AXDocumentDockItem": kind = .file
            case "AXURLDockItem": kind = .url
            case "AXTrashDockItem": kind = .trash
            case "AXMinimizedWindowDockItem": kind = .minimized
            case "AXSeparatorDockItem": kind = .separator
            default: kind = title.isEmpty ? .spacer : .file
            }
            let path = (url?.isFileURL ?? false) ? url!.standardizedFileURL.path : nil
            items.append(Item(kind: kind, title: title, path: path, url: url,
                              running: running, badge: badge, axIndex: i))
            frames.append(CGRect(origin: point(v(5)) ?? .zero, size: size(v(6)) ?? .zero))
        }
        elements = kids
        return AXSnapshot(items: items, frames: frames, list: listFrame)
    }

    // MARK: меню настоящего Дока

    private func element(for item: Item) -> AXUIElement? {
        if item.axIndex >= 0, item.axIndex < elements.count,
           (str(elements[item.axIndex], kAXTitleAttribute) ?? "") == item.title { return elements[item.axIndex] }
        return elements.first { (str($0, kAXTitleAttribute) ?? "") == item.title }
    }

    private func openMenu(_ e: AXUIElement) -> AXUIElement? {
        // Док может не отвечать на это действие, пока меню открыто, — ждём недолго
        AXUIElementSetMessagingTimeout(e, 0.25)
        _ = AXUIElementPerformAction(e, kAXShowMenuAction as CFString)
        for _ in 0..<30 {
            if let m = children(e).first(where: { str($0, kAXRoleAttribute) == kAXMenuRole }) { return m }
            usleep(10_000)
        }
        return nil
    }

    private func closeMenu(_ menu: AXUIElement, of e: AXUIElement) {
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        usleep(15_000)
        if children(e).contains(where: { str($0, kAXRoleAttribute) == kAXMenuRole }) {
            // запасной вариант — Escape прямо в Док
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid)
            }
        }
    }

    private func nodes(_ menu: AXUIElement) -> [MenuNode] {
        children(menu).compactMap { mi in
            guard str(mi, kAXRoleAttribute) == kAXMenuItemRole else { return nil }
            let sub = children(mi).first { str($0, kAXRoleAttribute) == kAXMenuRole }
            return MenuNode(title: str(mi, kAXTitleAttribute) ?? "",
                            enabled: (copy(mi, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true,
                            mark: str(mi, kAXMenuItemMarkCharAttribute) ?? "",
                            children: sub.map { nodes($0) } ?? [])
        }
    }

    func readMenu(for item: Item) -> [MenuNode]? {
        guard let e = element(for: item), let menu = openMenu(e) else { return nil }
        let result = nodes(menu)
        closeMenu(menu, of: e)
        return result.isEmpty ? nil : result
    }

    func pressMenu(for item: Item, path: [String]) {
        guard let e = element(for: item), var menu = openMenu(e) else { return }
        for (depth, title) in path.enumerated() {
            guard let mi = children(menu).first(where: { (str($0, kAXTitleAttribute) ?? "") == title }) else { break }
            if depth == path.count - 1 {
                _ = AXUIElementPerformAction(mi, kAXPressAction as CFString)
                return
            }
            guard let sub = children(mi).first(where: { str($0, kAXRoleAttribute) == kAXMenuRole }) else { break }
            menu = sub
        }
        closeMenu(menu, of: e)
    }

    func press(_ item: Item) {
        guard let e = element(for: item) else { return }
        _ = AXUIElementPerformAction(e, kAXPressAction as CFString)
    }

    // MARK: окна других программ

    /// Меняет рамку окна программы (как делает macOS, чтобы окно не заходило под Док).
    func resizeWindow(pid: pid_t, from old: CGRect, to new: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let wins = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        for w in wins {
            guard let f = frame(w),
                  abs(f.minX - old.minX) < 4, abs(f.minY - old.minY) < 4,
                  abs(f.width - old.width) < 4, abs(f.height - old.height) < 4 else { continue }
            if abs(new.minX - old.minX) > 0.5 || abs(new.minY - old.minY) > 0.5 {
                var o = new.origin
                if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
            }
            var s = new.size
            if let v = AXValueCreate(.cgSize, &s) {
                return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
            }
        }
        return false
    }
}

// MARK: - Фоновый наблюдатель за Доком и окнами

final class DockMonitor {
    let queue = DispatchQueue(label: "doublemydock.monitor", qos: .userInitiated)
    var onSnapshot: ((Snapshot) -> Void)?

    private let reader = DockReader()
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var prefs = DockPrefs()
    private var trusted = false
    private var trashFull = false
    private var lastAX: AXSnapshot?
    private var axFailures = 0
    private let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.cycle(full: false) }
        t.resume()
        timer = t
    }

    /// Внеочередное обновление (запуск программы, смена экранов и т. п.).
    func poke() { queue.async { [weak self] in self?.cycle(full: true) } }

    private func cycle(full: Bool) {
        tick += 1
        let windows = readWindows()

        if full || tick % 6 == 1 {
            let t = AXIsProcessTrusted()
            if t != trusted { trusted = t; if !t { lastAX = nil } }
            prefs = DockPrefs.read()
            trashFull = DockMonitor.trashIsFull()
        }

        if trusted {
            let t0 = CFAbsoluteTimeGetCurrent()
            if let s = reader.read() {
                if axFailures >= 3 { dlog("Док снова отвечает") }
                lastAX = s
                axFailures = 0
            } else {
                axFailures += 1
                if axFailures == 3 {
                    dlog("Док не отвечает через Accessibility — временно упрощённый режим")
                    lastAX = nil
                }
            }
            let dt = CFAbsoluteTimeGetCurrent() - t0
            if dt > 0.25 { dlog(String(format: "Чтение Дока заняло %.0f мс", dt * 1000)) }
        }

        // сторож: если главный поток где-то застрял, это попадёт в журнал
        if tick % 4 == 0 {
            let sent = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let lag = CFAbsoluteTimeGetCurrent() - sent
                if lag > 0.5 { dlog(String(format: "Интерфейс задержался на %.1f с", lag)) }
            }
        }

        let snap = Snapshot(trusted: trusted, prefs: prefs, ax: trusted ? lastAX : nil,
                            trashFull: trashFull, windows: windows)
        let cb = onSnapshot
        DispatchQueue.main.async { cb?(snap) }
    }

    private func readWindows() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [WinInfo] = []
        out.reserveCapacity(list.count)
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard layer == 0 || (layer == dockLevel && owner == "Dock") else { continue }
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            out.append(WinInfo(pid: (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                               layer: layer, owner: owner, bounds: r,
                               alpha: (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1))
        }
        return out
    }

    /// Полна ли Корзина: число записей в папке, без чтения её содержимого.
    private static func trashIsFull() -> Bool {
        let path = NSHomeDirectory() + "/.Trash"
        var attrs = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0,
                             volattr: 0, dirattr: attrgroup_t(ATTR_DIR_ENTRYCOUNT), fileattr: 0, forkattr: 0)
        var buf = [UInt32](repeating: 0, count: 2)
        if getattrlist(path, &attrs, &buf, MemoryLayout<UInt32>.size * 2, 0) == 0 { return buf[1] > 1 }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: path) {
            return items.contains { $0 != ".DS_Store" && $0 != ".localized" }
        }
        return false
    }

    // MARK: действия с Доком — тоже только в фоне

    func readMenu(for item: Item, completion: @escaping ([DockReader.MenuNode]?) -> Void) {
        queue.async { [reader] in
            let r = reader.readMenu(for: item)
            DispatchQueue.main.async { completion(r) }
        }
    }

    func pressMenu(for item: Item, path: [String]) {
        queue.async { [reader] in reader.pressMenu(for: item, path: path) }
    }

    func press(_ item: Item) {
        queue.async { [reader] in reader.press(item) }
    }

    func fitWindow(pid: pid_t, from old: CGRect, to new: CGRect, name: String) {
        queue.async { [reader] in
            if !reader.resizeWindow(pid: pid, from: old, to: new) {
                dlog("Не удалось изменить размер окна «\(name)»")
            }
        }
    }
}

// MARK: - Окна-предупреждения, которые не останавливают копию

/// Показывает окно так, чтобы копии Дока продолжали обновляться, пока оно открыто.
@MainActor
func presentAlert(_ make: @escaping @MainActor () -> NSAlert,
                  then done: @escaping @MainActor (NSApplication.ModalResponse, NSAlert) -> Void = { _, _ in }) {
    RunLoop.main.perform {
        MainActor.assumeIsolated {
            let a = make()
            NSApp.activate(ignoringOtherApps: true)
            a.window.level = .floating
            done(a.runModal(), a)
        }
    }
}

// MARK: - Окно-панель

@MainActor
func makePanel(level: Int) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    p.level = NSWindow.Level(rawValue: level)
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    return p
}

// MARK: - Вид Дока на одном мониторе

@MainActor
final class DockView: NSView {
    unowned let controller: Controller
    var background: NSView!
    var rim: NSView!               // тонкая светлая кромка, как у Дока
    var hoverU: CGFloat?           // положение курсора вдоль панели (в базовых координатах)
    var lastU: CGFloat = 0
    var mag: CGFloat = 0           // 0…1 — насколько включено увеличение
    var hideAmount: CGFloat = 0    // 0…1 — для автоскрытия
    var pressedIndex: Int?
    var dropIndex: Int?

    var iconRects: [CGRect] = []
    var barRect: CGRect = .zero

    init(controller: Controller) {
        self.controller = controller
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: раскладка (как в macOS: значки растут, соседи раздвигаются,
    // точка под курсором остаётся на месте, панель расширяется)

    func relayout() {
        let g = controller.geometry, items = controller.items
        let n = items.count
        guard n > 0, g.centers.count == n else { iconRects = []; barRect = .zero; needsDisplay = true; return }
        let s = g.icon
        let L = controller.prefs.magnification ? max(controller.prefs.large, s) : s
        let u = hoverU ?? lastU
        let R = s * 2.6

        var edges = [CGFloat](repeating: 0, count: n + 1)
        for i in 1..<max(n, 1) { edges[i] = (g.centers[i - 1] + g.centers[i]) / 2 }
        if n == 1 { edges[0] = g.centers[0] - s * 0.55; edges[1] = g.centers[0] + s * 0.55 }
        else {
            edges[0] = g.centers[0] - (edges[1] - g.centers[0])
            edges[n] = g.centers[n - 1] + (g.centers[n - 1] - edges[n - 1])
        }

        var sizes = [CGFloat](repeating: s, count: n)
        var newEdges = [CGFloat](repeating: edges[0], count: n + 1)
        for i in 0..<n {
            let it = items[i]
            if it.kind != .separator && it.kind != .spacer && mag > 0 && L > s {
                let d = abs(g.centers[i] - u)
                let f: CGFloat = d < R ? (cos(.pi * d / R) + 1) / 2 : 0
                sizes[i] = s + (L - s) * f * mag
            }
            let w = edges[i + 1] - edges[i]
            let scale = (it.kind == .separator || it.kind == .spacer) ? 1 : sizes[i] / s
            newEdges[i + 1] = newEdges[i] + w * scale
        }
        func map(_ x: CGFloat) -> CGFloat {
            if x <= edges[0] { return newEdges[0] + (x - edges[0]) }
            for i in 0..<n where x <= edges[i + 1] {
                let t = (x - edges[i]) / max(edges[i + 1] - edges[i], 0.001)
                return newEdges[i] + t * (newEdges[i + 1] - newEdges[i])
            }
            return newEdges[n] + (x - edges[n])
        }
        let shift = mag > 0 ? u - map(u) : 0
        let barStart = newEdges[0] + shift - edges[0]
        let barEnd = newEdges[n] + shift + (g.barLength - edges[n])

        let axisLen = g.orientation == .bottom ? bounds.width : bounds.height
        let base = ((axisLen - g.barLength) / 2).rounded()
        let edgeOff = g.gap - hideAmount * (g.gap + g.barThickness + 2)
        let baseline = (g.barThickness - s) / 2

        func rect(along a: CGFloat, _ len: CGFloat, cross c: CGFloat, _ clen: CGFloat) -> CGRect {
            switch g.orientation {
            case .bottom: return CGRect(x: base + a, y: edgeOff + c, width: len, height: clen)
            case .left:   return CGRect(x: edgeOff + c, y: bounds.height - base - a - len, width: clen, height: len)
            case .right:  return CGRect(x: bounds.width - edgeOff - c - clen, y: bounds.height - base - a - len, width: clen, height: len)
            }
        }
        barRect = rect(along: barStart, barEnd - barStart, cross: 0, g.barThickness)
        iconRects = (0..<n).map { i in
            if items[i].kind == .separator || items[i].kind == .spacer {
                return rect(along: newEdges[i] + shift, newEdges[i + 1] - newEdges[i], cross: 0, g.barThickness)
            }
            let mid = (newEdges[i] + newEdges[i + 1]) / 2 + shift
            let sz = sizes[i]
            return rect(along: mid - sz / 2, sz, cross: baseline + controller.bounceOffset(items[i]), sz)
        }
        let bar = barRect.integral
        if background.frame != bar { background.frame = bar; rim.frame = bar }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        rim.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.32 : 0.65).cgColor
        needsDisplay = true
    }

    // MARK: рисование (значки заранее растрированы — быстро даже при анимации)

    override func draw(_ dirtyRect: NSRect) {
        let items = controller.items, g = controller.geometry
        guard iconRects.count == items.count, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let px = controller.iconPixels()
        for (i, it) in items.enumerated() {
            let r = iconRects[i]
            switch it.kind {
            case .spacer: continue
            case .separator:
                let line: CGRect
                if g.orientation == .bottom {
                    line = CGRect(x: r.midX - 0.5, y: r.minY + r.height * 0.2, width: 1, height: r.height * 0.6)
                } else {
                    line = CGRect(x: r.minX + r.width * 0.2, y: r.midY - 0.5, width: r.width * 0.6, height: 1)
                }
                (dark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.18)).setFill()
                line.fill()
                continue
            default: break
            }
            if let cg = controller.cgIcon(for: it, pixels: px) {
                if pressedIndex == i || dropIndex == i {
                    ctx.saveGState()
                    ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
                    ctx.draw(cg, in: r)
                    ctx.setBlendMode(.sourceAtop)
                    ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
                    ctx.fill(r)
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                } else {
                    ctx.draw(cg, in: r)
                }
            }

            if it.running && it.kind == .app {
                let ds: CGFloat = max(3, (g.icon * 0.085).rounded())
                let off = max(1, (g.barThickness - g.icon) / 4 - ds / 2)
                let dot: CGRect
                switch g.orientation {
                case .bottom: dot = CGRect(x: r.midX - ds / 2, y: barRect.minY + off, width: ds, height: ds)
                case .left:   dot = CGRect(x: barRect.minX + off, y: r.midY - ds / 2, width: ds, height: ds)
                case .right:  dot = CGRect(x: barRect.maxX - off - ds, y: r.midY - ds / 2, width: ds, height: ds)
                }
                (dark ? NSColor.white.withAlphaComponent(0.8) : NSColor.black.withAlphaComponent(0.65)).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }

            if let b = it.badge { drawBadge(b, on: r) }
        }
        if let i = hoverIndex(), i < items.count, items[i].kind != .separator, items[i].kind != .spacer {
            drawLabel(items[i].title, for: iconRects[i], dark: dark)
        }
    }

    private func drawBadge(_ text: String, on r: CGRect) {
        let fs = max(9, r.width * 0.24)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let t = text as NSString
        let ts = t.size(withAttributes: attrs)
        let h = max(fs * 1.55, ts.height + 2)
        let w = max(h, ts.width + fs * 0.9)
        let b = CGRect(x: r.maxX - w * 0.8, y: r.maxY - h * 0.85, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: b, xRadius: h / 2, yRadius: h / 2).fill()
        t.draw(at: CGPoint(x: b.midX - ts.width / 2, y: b.midY - ts.height / 2), withAttributes: attrs)
    }

    private func drawLabel(_ text: String, for r: CGRect, dark: Bool) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                    .foregroundColor: dark ? NSColor.white : NSColor.black]
        let t = text as NSString
        let ts = t.size(withAttributes: attrs)
        let w = ts.width + 20, h = ts.height + 8
        let g = controller.geometry
        var box: CGRect
        switch g.orientation {
        case .bottom: box = CGRect(x: r.midX - w / 2, y: r.maxY + 10, width: w, height: h)
        case .left:   box = CGRect(x: r.maxX + 10, y: r.midY - h / 2, width: w, height: h)
        case .right:  box = CGRect(x: r.minX - 10 - w, y: r.midY - h / 2, width: w, height: h)
        }
        box.origin.x = min(max(box.minX, 4), bounds.width - w - 4)
        box = box.integral
        (dark ? NSColor(white: 0.12, alpha: 0.88) : NSColor(white: 0.97, alpha: 0.92)).setFill()
        NSBezierPath(roundedRect: box, xRadius: h / 2, yRadius: h / 2).fill()
        t.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attrs)
    }

    // MARK: мышь

    func hoverIndex() -> Int? {
        guard hoverU != nil, let w = window else { return nil }
        let p = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        return index(at: convert(p, from: nil))
    }

    func index(at p: CGPoint) -> Int? {
        let g = controller.geometry
        for (i, r) in iconRects.enumerated() {
            let hit: CGRect
            switch g.orientation {
            case .bottom: hit = CGRect(x: r.minX - 2, y: barRect.minY, width: r.width + 4, height: max(r.maxY, barRect.maxY) - barRect.minY)
            case .left:   hit = CGRect(x: barRect.minX, y: r.minY - 2, width: max(r.maxX, barRect.maxX) - barRect.minX, height: r.height + 4)
            case .right:  hit = CGRect(x: min(r.minX, barRect.minX), y: r.minY - 2, width: barRect.maxX - min(r.minX, barRect.minX), height: r.height + 4)
            }
            if hit.contains(p) { return i }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let inBar = barRect.insetBy(dx: -2, dy: -2).contains(p)
        return (inBar || index(at: p) != nil) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        pressedIndex = index(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        let was = pressedIndex
        pressedIndex = nil
        needsDisplay = true
        if let i, i == was, i < controller.items.count { controller.activate(controller.items[i]) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        controller.showContextMenu(for: index(at: p), at: p, in: self, event: e)
    }

    // MARK: перетаскивание файлов на значки

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        let i = index(at: convert(s.draggingLocation, from: nil))
        let ok = i.map { $0 < controller.items.count && [.app, .trash, .folder].contains(controller.items[$0].kind) } ?? false
        if dropIndex != (ok ? i : nil) { dropIndex = ok ? i : nil; needsDisplay = true }
        guard ok, let i else { return [] }
        switch controller.items[i].kind {
        case .trash: return .delete
        case .folder: return .move
        default: return .generic
        }
    }
    override func draggingExited(_ s: NSDraggingInfo?) { dropIndex = nil; needsDisplay = true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil; needsDisplay = true }
        guard let i = index(at: convert(s.draggingLocation, from: nil)), i < controller.items.count,
              let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty
        else { return false }
        controller.drop(urls, on: controller.items[i])
        return true
    }
}

// MARK: - Обновления с GitHub

@MainActor
final class Updater {
    static let repo = "porwatkinoff-it/DoubleMyDock"
    private(set) var available: (version: String, url: URL)?
    private(set) var busy = false
    private var lastPrompted: String? {
        get { UserDefaults.standard.string(forKey: "lastPromptedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPromptedVersion") }
    }

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.check(userInitiated: false)
        }
        let t = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        t.tolerance = 600
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
                req.setValue("DoubleMyDock", forHTTPHeaderField: "User-Agent")
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 20
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]],
                      let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                      let s = dmg["browser_download_url"] as? String, let url = URL(string: s)
                else { throw URLError(.badServerResponse) }
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Updater.isNewer(version, than: current) {
                    available = (version, url)
                    if userInitiated || lastPrompted != version {
                        lastPrompted = version
                        dlog("Доступно обновление \(version)")
                        prompt(version)
                    }
                } else {
                    available = nil
                    if userInitiated { info("Установлена последняя версия", "DoubleMyDock \(current) — самая новая.") }
                }
            } catch {
                if userInitiated { info("Не удалось проверить обновления", error.localizedDescription) }
            }
        }
    }

    private func prompt(_ version: String) {
        let cur = current
        presentAlert({
            let a = NSAlert()
            a.messageText = "Доступна новая версия DoubleMyDock \(version)"
            a.informativeText = "Сейчас установлена \(cur). Обновление скачается и установится само, программа перезапустится."
            a.addButton(withTitle: "Обновить")
            a.addButton(withTitle: "Позже")
            return a
        }, then: { [weak self] r, _ in
            if r == .alertFirstButtonReturn { self?.install() }
        })
    }

    private func info(_ title: String, _ text: String) {
        presentAlert({
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            return a
        })
    }

    func install() {
        guard let av = available, !busy else { return }
        let version = av.version, url = av.url
        busy = true
        dlog("Устанавливаю обновление \(version)")
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DoubleMyDock-\(version)")
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dmg = dir.appendingPathComponent("DoubleMyDock.dmg")
                try FileManager.default.moveItem(at: tmp, to: dmg)
                let mnt = dir.appendingPathComponent("mnt")

                let status: Int32 = await Task.detached { () -> Int32 in
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    p.arguments = ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mnt.path]
                    do { try p.run() } catch { return -1 }
                    p.waitUntilExit()
                    return p.terminationStatus
                }.value
                let newApp = mnt.appendingPathComponent("DoubleMyDock.app")
                guard status == 0, FileManager.default.fileExists(atPath: newApp.path)
                else { throw CocoaError(.fileReadCorruptFile) }

                // Заменяем себя после выхода и перезапускаемся
                let dest = Bundle.main.bundleURL.path
                let script = """
                while kill -0 $1 2>/dev/null; do sleep 0.2; done
                rm -rf "$3.old"
                if mv "$3" "$3.old" && ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
                xattr -dr com.apple.quarantine "$3" 2>/dev/null
                hdiutil detach "$4" -quiet
                open "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                               newApp.path, dest, mnt.path]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                busy = false
                dlog("Обновление не удалось: \(error.localizedDescription)")
                info("Не удалось обновить", error.localizedDescription)
            }
        }
    }
}

// MARK: - Контроллер

@MainActor
final class Controller: NSObject {
    struct Mirror { let panel: NSPanel; let view: DockView }

    final class DockPick: NSObject {
        let item: Item, path: [String]
        init(item: Item, path: [String]) { self.item = item; self.path = path }
    }

    private(set) var items: [Item] = []
    private(set) var geometry = Geometry()
    private(set) var prefs = DockPrefs()
    private var mirrors: [CGDirectDisplayID: Mirror] = [:]
    private let monitor = DockMonitor()
    private var iconCache: [String: NSImage] = [:]
    private var rasterCache: [String: CGImage] = [:]
    private var nameCache: [String: String] = [:]
    private let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    private var dockScreen: CGDirectDisplayID?
    private var pendingWindowScreen: CGDirectDisplayID?
    private var animTimer: Timer?
    private var bounces: [String: Date] = [:]
    private var hideTimers: [CGDirectDisplayID: Date] = [:]
    private var axTrusted = false
    private var gotSnapshot = false
    private var fullscreen = Set<CGDirectDisplayID>()
    private var edgeSince: [CGDirectDisplayID: Date] = [:]
    private var edgeTimers: [CGDirectDisplayID: Timer] = [:]
    private var regularPIDs = Set<pid_t>()
    private var appNames: [pid_t: String] = [:]
    private var fitAttempts: [String: (count: Int, last: Date)] = [:]
    private var fallbackKey = ""
    private var fallbackCache: ([Item], Geometry) = ([], Geometry())
    private var menuRequest = 0
    private var warnedNoDock = false
    let updater = Updater()

    /// Укорачивать развёрнутые окна, чтобы они не заходили под копию (как macOS делает для Дока).
    private var fitWindows: Bool {
        get { UserDefaults.standard.object(forKey: "fitWindows") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fitWindows") }
    }

    func start() {
        dlog("──── Запуск DoubleMyDock \(updater.current), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        logScreens()
        axTrusted = AXIsProcessTrusted()
        dlog("Доступ к Доку: \(axTrusted ? "есть" : "нет")")
        if !axTrusted {
            Task { [weak self] in
                // macOS иногда отвечает «нет» в первые секунды после запуска — перепроверяем
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if AXIsProcessTrusted() { return }
                }
                self?.askForAccessibility(atLaunch: true)
            }
        }
        refreshApps()

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(appWillLaunch(_:)),
                        name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                  NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            wnc.addObserver(self, selector: #selector(workspaceChanged), name: n, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }

        monitor.onSnapshot = { [weak self] s in MainActor.assumeIsolated { self?.apply(s) } }
        monitor.start()
        updater.start()
    }

    // MARK: события

    @objc private func workspaceChanged() {
        refreshApps()
        schedulePoke()
    }

    @objc private func screensChanged() {
        logScreens()
        rasterCache.removeAll()
        schedulePoke()
        layoutPanels(redraw: true)
    }

    private func schedulePoke() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(pokeNow), object: nil)
        perform(#selector(pokeNow), with: nil, afterDelay: 0.08)
    }
    @objc private func pokeNow() { monitor.poke() }

    private func refreshApps() {
        var pids = Set<pid_t>(), names: [pid_t: String] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            pids.insert(a.processIdentifier)
            names[a.processIdentifier] = a.localizedName ?? ""
        }
        regularPIDs = pids
        appNames = names
    }

    @objc private func appWillLaunch(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let p = app.bundleURL?.standardizedFileURL.path else { return }
        bounces[p] = Date()
        startAnimating()
    }

    func bounceOffset(_ it: Item) -> CGFloat {
        guard let p = it.path, let start = bounces[p] else { return 0 }
        let t = Date().timeIntervalSince(start)
        let period = 0.62, count = 2.0
        if t > period * count { return 0 }
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        return geometry.icon * 0.55 * CGFloat(sin(phase * .pi))
    }

    // MARK: координаты и экраны

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    /// AX/CG (от левого верхнего угла) ⇄ Cocoa (от левого нижнего) — формула одна в обе стороны.
    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    private func screen(_ id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { displayID($0) == id } }
    private func screenName(_ id: CGDirectDisplayID) -> String { screen(id)?.localizedName ?? "экран \(id)" }

    private func logScreens() {
        let list = NSScreen.screens.enumerated().map { i, s in
            "«\(s.localizedName)» \(Int(s.frame.width))×\(Int(s.frame.height))" + (i == 0 ? " (основной)" : "")
        }
        dlog("Экраны: " + list.joined(separator: ", "))
    }

    /// Экран, на котором лежит бо́льшая часть прямоугольника (в Cocoa-координатах).
    private func screenMostlyContaining(_ r: CGRect) -> NSScreen? {
        guard r.width > 1, r.height > 1 else { return nil }
        var best: NSScreen?, bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(r)
            if !i.isNull, i.width * i.height > bestArea { bestArea = i.width * i.height; best = s }
        }
        return bestArea >= r.width * r.height * 0.4 ? best : nil
    }

    private func visibleFrameDockScreen() -> CGDirectDisplayID? {
        for s in NSScreen.screens {
            let f = s.frame, v = s.visibleFrame
            if v.minY - f.minY > 0.5 || v.minX - f.minX > 0.5 || f.maxX - v.maxX > 0.5 { return displayID(s) }
        }
        return nil
    }

    /// Запасной способ найти Док: его окно. Берём, только если оно похоже на панель у края экрана.
    private func dockScreenFromWindows(_ wins: [WinInfo], orientation: Orientation) -> CGDirectDisplayID? {
        var found = Set<CGDirectDisplayID>()
        for w in wins where w.owner == "Dock" && w.layer == dockLevel {
            let c = flip(w.bounds)
            guard let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: c.midX, y: c.midY)) }) else { continue }
            let f = s.frame
            let ok: Bool
            switch orientation {
            case .bottom: ok = c.height >= 20 && c.height <= 260 && c.width >= 120 && c.minY - f.minY < 40
            case .left:   ok = c.width >= 20 && c.width <= 260 && c.height >= 120 && c.minX - f.minX < 40
            case .right:  ok = c.width >= 20 && c.width <= 260 && c.height >= 120 && f.maxX - c.maxX < 40
            }
            if ok { found.insert(displayID(s)) }
        }
        return found.count == 1 ? found.first : nil
    }

    // MARK: применение снимка из фонового потока

    private func apply(_ s: Snapshot) {
        if s.trusted != axTrusted {
            axTrusted = s.trusted
            dlog("Доступ к Доку: \(s.trusted ? "есть" : "нет")")
            if s.trusted { accessibilityGranted() }
        }
        let p = s.prefs
        var newItems: [Item]
        var newGeo: Geometry
        var axScreen: CGDirectDisplayID?

        if let ax = s.ax {
            newItems = ax.items
            let cocoaList = flip(ax.list)
            let scr = screenMostlyContaining(cocoaList)
            axScreen = scr.map(displayID)
            newGeo = geometryFromAX(ax, prefs: p, screen: scr, cocoaList: cocoaList)
        } else {
            (newItems, newGeo) = fallbackLayout(p)
        }
        for i in newItems.indices where newItems[i].kind == .trash { newItems[i].running = s.trashFull }

        // Где настоящий Док: сначала Accessibility, потом окно Дока (дважды подряд), потом рабочая область
        var newDock: CGDirectDisplayID?, source = ""
        if let a = axScreen {
            newDock = a; source = "Accessibility"
        } else if let w = dockScreenFromWindows(s.windows, orientation: p.orientation) {
            if w == pendingWindowScreen || dockScreen == nil { newDock = w; source = "окно Дока" }
            pendingWindowScreen = w
        } else if dockScreen == nil, let v = visibleFrameDockScreen() {
            newDock = v; source = "рабочая область экрана"
        }
        var dockChanged = false
        if let nd = newDock, nd != dockScreen {
            dlog("Настоящий Док: «\(screenName(nd))» (определено по: \(source))")
            dockScreen = nd
            dockChanged = true
        }
        if dockScreen == nil && !warnedNoDock {
            warnedNoDock = true
            dlog("Не удалось определить, на каком мониторе Док")
        }

        if p.tile != prefs.tile || p.large != prefs.large || p.magnification != prefs.magnification {
            rasterCache.removeAll()
        }
        let changed = !gotSnapshot || newItems != items || newGeo != geometry || p != prefs
        gotSnapshot = true
        items = newItems
        geometry = newGeo
        prefs = p

        updateFullscreen(s.windows)
        layoutPanels(redraw: changed || dockChanged)
        if axTrusted && fitWindows { fitMaximizedWindows(s.windows) }
    }

    private func geometryFromAX(_ ax: AXSnapshot, prefs p: DockPrefs, screen scr: NSScreen?, cocoaList: CGRect) -> Geometry {
        let vertical = p.orientation != .bottom
        let lens = zip(ax.items, ax.frames)
            .filter { $0.0.kind != .separator && $0.0.kind != .spacer }
            .map { vertical ? $0.1.height : $0.1.width }
        let calm = (lens.max() ?? 0) - (lens.min() ?? 0) < 1.5
        // Настоящий Док сейчас увеличен под курсором — оставляем прежнюю раскладку
        if !calm && gotSnapshot && geometry.centers.count == ax.items.count {
            var g = geometry
            g.orientation = p.orientation
            g.icon = p.tile
            return g
        }
        var g = Geometry()
        g.orientation = p.orientation
        g.icon = p.tile
        if vertical {
            g.barLength = ax.list.height
            g.barThickness = ax.list.width
            g.centers = ax.frames.map { $0.midY - ax.list.minY }
        } else {
            g.barLength = ax.list.width
            g.barThickness = ax.list.height
            g.centers = ax.frames.map { $0.midX - ax.list.minX }
        }
        if let scr {
            switch p.orientation {
            case .bottom: g.gap = cocoaList.minY - scr.frame.minY
            case .left:   g.gap = cocoaList.minX - scr.frame.minX
            case .right:  g.gap = scr.frame.maxX - cocoaList.maxX
            }
        } else {
            g.gap = gotSnapshot ? geometry.gap : 4
        }
        g.gap = min(max(g.gap, 0), 40)
        if g.barThickness < g.icon { g.barThickness = (g.icon * 1.3).rounded() }
        if g.barLength < 40 || g.centers.contains(where: { !$0.isFinite }) {
            return uniformGeometry(ax.items, prefs: p)
        }
        return g
    }

    private func uniformGeometry(_ list: [Item], prefs p: DockPrefs) -> Geometry {
        var g = Geometry()
        g.orientation = p.orientation
        g.icon = p.tile
        let pitch = (p.tile * 1.04).rounded()
        let sepW = (p.tile * 0.38).rounded()
        let pad = (p.tile * 0.2).rounded()
        var x = pad
        for it in list {
            let w = it.kind == .separator ? sepW : pitch
            g.centers.append(x + w / 2)
            x += w
        }
        g.barLength = x + pad
        g.barThickness = (p.tile * 1.33).rounded()
        g.gap = 4
        return g
    }

    /// Без Accessibility: закреплённые + запущенные + недавние + корзина.
    private func fallbackLayout(_ p: DockPrefs) -> ([Item], Geometry) {
        let me = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != me }
            .compactMap { $0.bundleURL?.standardizedFileURL.path }
        let key = (p.pinned + ["|"] + p.recents + ["|"] + running).joined(separator: ";")
            + "|\(p.tile)|\(p.orientation)|\(p.showRecents)"
        if key == fallbackKey { return fallbackCache }

        let runSet = Set(running)
        let pinned = [finderPath] + p.pinned.filter { $0 != finderPath && FileManager.default.fileExists(atPath: $0) }
        var extra: [String] = []
        let recent = p.showRecents ? p.recents.filter { FileManager.default.fileExists(atPath: $0) } : []
        for r in recent + running where !pinned.contains(r) && !extra.contains(r) {
            if recent.contains(r) || runSet.contains(r) { extra.append(r) }
        }
        func app(_ path: String) -> Item {
            let name: String
            if let c = nameCache[path] { name = c } else {
                var n = FileManager.default.displayName(atPath: path)
                if n.hasSuffix(".app") { n.removeLast(4) }
                nameCache[path] = n
                name = n
            }
            return Item(kind: .app, title: name, path: path, url: URL(fileURLWithPath: path),
                        running: runSet.contains(path), badge: nil, axIndex: -1)
        }
        let sep = Item(kind: .separator, title: "", path: nil, url: nil, running: false, badge: nil, axIndex: -1)
        var list = pinned.map(app)
        if !extra.isEmpty { list.append(sep); list += extra.map(app) }
        list.append(sep)
        list.append(Item(kind: .trash, title: "Корзина", path: NSHomeDirectory() + "/.Trash",
                         url: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"), running: false, badge: nil, axIndex: -1))
        let result = (list, uniformGeometry(list, prefs: p))
        fallbackKey = key
        fallbackCache = result
        return result
    }

    // MARK: значки

    private func iconKey(_ it: Item) -> String {
        switch it.kind {
        case .trash: return it.running ? "#trashFull" : "#trashEmpty"
        case .minimized: return "#min"
        case .url: return "#url"
        default: return it.path ?? "#doc:\(it.title)"
        }
    }

    private func icon(for it: Item) -> NSImage {
        let key = iconKey(it)
        if let i = iconCache[key] { return i }
        let img: NSImage
        switch it.kind {
        case .trash: img = NSImage(named: it.running ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(for: .folder)
        case .url: img = NSImage(named: NSImage.networkName) ?? NSWorkspace.shared.icon(for: .internetLocation)
        case .minimized: img = NSImage(named: NSImage.multipleDocumentsName) ?? NSWorkspace.shared.icon(for: .data)
        default: img = it.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data)
        }
        iconCache[key] = img
        return img
    }

    /// Размер растра значка в пикселях: самый большой размер (с увеличением) × плотность экрана.
    func iconPixels() -> Int {
        let pt = max(geometry.icon, prefs.magnification ? prefs.large : 0)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return max(16, Int((pt * scale).rounded(.up)))
    }

    func cgIcon(for it: Item, pixels: Int) -> CGImage? {
        let key = "\(iconKey(it))@\(pixels)"
        if let c = rasterCache[key] { return c }
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon(for: it).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let cg = ctx.makeImage()
        rasterCache[key] = cg
        return cg
    }

    // MARK: панели

    private func makeMirror() -> Mirror {
        let p = makePanel(level: dockLevel)
        let root = NSView()
        root.wantsLayer = true
        let view = DockView(controller: self)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay

        let bg: NSView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()        // то же «жидкое стекло», что у Дока в Tahoe
            glass.style = .clear
            glass.contentView = NSView()
            bg = glass
        } else { bg = Controller.legacyBackground() }
        #else
        bg = Controller.legacyBackground()
        #endif
        let rim = NSView()
        rim.wantsLayer = true
        rim.layer?.borderWidth = 1
        rim.layer?.cornerCurve = .continuous
        root.addSubview(bg)
        root.addSubview(rim)
        root.addSubview(view)
        view.background = bg
        view.rim = rim
        p.contentView = root
        return Mirror(panel: p, view: view)
    }

    private static func legacyBackground() -> NSView {
        let fx = NSVisualEffectView()
        fx.material = .fullScreenUI
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.masksToBounds = true
        fx.layer?.cornerCurve = .continuous
        return fx
    }

    private func applyRadius(_ v: NSView) {
        let r: CGFloat
        if #available(macOS 26.0, *) { r = (geometry.barThickness * 0.42).rounded() }
        else { r = (geometry.barThickness * 0.28).rounded() }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = v as? NSGlassEffectView { glass.cornerRadius = r; return }
        #endif
        v.layer?.cornerRadius = r
    }

    private func panelFrame(on s: NSScreen) -> CGRect {
        let f = s.frame, g = geometry
        let L = prefs.magnification ? max(prefs.large, g.icon) : g.icon
        let thick = (g.gap + g.barThickness + (L - g.icon) + g.icon * 0.6 + 44).rounded()
        switch g.orientation {
        case .bottom: return CGRect(x: f.minX, y: f.minY, width: f.width, height: thick)
        case .left:   return CGRect(x: f.minX, y: f.minY, width: thick + 200, height: f.height)
        case .right:  return CGRect(x: f.maxX - thick - 200, y: f.minY, width: thick + 200, height: f.height)
        }
    }

    private func layoutPanels(redraw: Bool) {
        let screens = NSScreen.screens
        var seen = Set<CGDirectDisplayID>()
        for s in screens {
            let id = displayID(s)
            seen.insert(id)
            let show = screens.count > 1 && dockScreen != nil && id != dockScreen
            guard show else {
                if let m = mirrors[id], m.panel.isVisible {
                    m.panel.orderOut(nil)
                    dlog("Копия убрана с «\(s.localizedName)»")
                }
                continue
            }
            var created = false
            let m: Mirror
            if let e = mirrors[id] { m = e } else {
                m = makeMirror()
                mirrors[id] = m
                created = true
                m.view.hideAmount = autoHide(id) ? 1 : 0
            }
            let fr = panelFrame(on: s)
            if m.panel.frame != fr { m.panel.setFrame(fr, display: false) }
            if redraw || created {
                applyRadius(m.view.background)
                applyRadius(m.view.rim)
                m.view.relayout()
            }
            if (autoHide(id) && m.view.hoverU == nil ? 1 : 0) != m.view.hideAmount { startAnimating() }
            if !m.panel.isVisible {
                m.panel.orderFrontRegardless()
                dlog("Копия показана на «\(s.localizedName)»")
            }
        }
        for (id, m) in mirrors where !seen.contains(id) {
            m.panel.orderOut(nil)
            mirrors[id] = nil
        }
    }

    // MARK: полноэкранные программы и развёрнутые окна

    /// Копия прячется только в полноэкранных программах и при автоскрытии Дока.
    private func autoHide(_ id: CGDirectDisplayID) -> Bool { prefs.autohide || fullscreen.contains(id) }

    /// Сколько курсор должен простоять у края, чтобы скрытая копия выехала.
    private func revealDelay(_ id: CGDirectDisplayID) -> TimeInterval { fullscreen.contains(id) ? 5 : 0.5 }

    private func isUserWindow(_ w: WinInfo) -> Bool {
        w.layer == 0 && w.pid != getpid() && regularPIDs.contains(w.pid) && w.alpha > 0.05
            && w.bounds.width > 60 && w.bounds.height > 60
    }

    private func updateFullscreen(_ wins: [WinInfo]) {
        var full = Set<CGDirectDisplayID>(), who: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            let target = s.frame.insetBy(dx: 4, dy: 4)
            if let w = wins.first(where: { isUserWindow($0) && flip($0.bounds).contains(target) }) {
                let id = displayID(s)
                full.insert(id)
                who[id] = appNames[w.pid] ?? w.owner
            }
        }
        guard full != fullscreen else { return }
        for id in full.subtracting(fullscreen) {
            dlog("Полноэкранная программа «\(who[id] ?? "?")» на «\(screenName(id))» — копия прячется")
        }
        for id in fullscreen.subtracting(full) { dlog("На «\(screenName(id))» больше нет полноэкранной программы") }
        fullscreen = full
        startAnimating()
    }

    /// Как macOS делает для Дока: развёрнутое окно не должно заходить под панель.
    private func fitMaximizedWindows(_ wins: [WinInfo]) {
        let now = Date()
        fitAttempts = fitAttempts.filter { now.timeIntervalSince($0.value.last) < 120 }
        let g = geometry
        let reserve = g.gap + g.barThickness
        for (id, m) in mirrors where m.panel.isVisible && !autoHide(id) {
            guard let s = screen(id) else { continue }
            let f = s.frame, vf = s.visibleFrame
            for w in wins where isUserWindow(w) {
                let r = flip(w.bounds)
                guard f.contains(CGPoint(x: r.midX, y: r.midY)) else { continue }
                var target = r
                switch g.orientation {
                case .bottom:
                    let edge = f.minY + reserve
                    guard r.minY <= f.minY + 6, r.minY < edge - 1, r.maxY >= vf.maxY - 6, r.height >= f.height * 0.5 else { continue }
                    target.origin.y = edge
                    target.size.height = r.maxY - edge
                case .left:
                    let edge = f.minX + reserve
                    guard r.minX <= f.minX + 6, r.minX < edge - 1, r.maxX >= f.maxX - 6, r.width >= f.width * 0.5 else { continue }
                    target.origin.x = edge
                    target.size.width = r.maxX - edge
                case .right:
                    let edge = f.maxX - reserve
                    guard r.maxX >= f.maxX - 6, r.maxX > edge + 1, r.minX <= f.minX + 6, r.width >= f.width * 0.5 else { continue }
                    target.size.width = edge - r.minX
                }
                let key = "\(w.pid):\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
                let a = fitAttempts[key] ?? (0, .distantPast)
                guard a.count < 2, now.timeIntervalSince(a.last) > 3 else { continue }
                fitAttempts[key] = (a.count + 1, now)
                let name = appNames[w.pid] ?? w.owner
                dlog("Окно «\(name)» на «\(s.localizedName)» укорочено, чтобы не заходило под копию")
                monitor.fitWindow(pid: w.pid, from: w.bounds, to: flip(target), name: name)
            }
        }
    }

    // MARK: наведение, увеличение, автоскрытие

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        var needAnim = false
        for (id, m) in mirrors where m.panel.isVisible {
            let v = m.view, g = geometry
            let local = v.convert(m.panel.convertPoint(fromScreen: p), from: nil)
            let L = prefs.magnification ? max(prefs.large, g.icon) : g.icon
            var zone = v.barRect
            switch g.orientation {
            case .bottom: zone.size.height += (v.mag > 0 ? L - g.icon : 0)
            case .left:   zone.size.width += (v.mag > 0 ? L - g.icon : 0)
            case .right:  zone.origin.x -= (v.mag > 0 ? L - g.icon : 0); zone.size.width += (v.mag > 0 ? L - g.icon : 0)
            }
            let sf = m.panel.screen?.frame ?? .zero
            let atEdge: Bool
            switch g.orientation {
            // только внутри этого экрана: курсор на соседнем мониторе ниже края не считается
            case .bottom: atEdge = p.y >= sf.minY && p.y <= sf.minY + 2 && p.x >= sf.minX && p.x < sf.maxX
            case .left:   atEdge = p.x >= sf.minX && p.x <= sf.minX + 2 && p.y >= sf.minY && p.y < sf.maxY
            case .right:  atEdge = p.x < sf.maxX && p.x >= sf.maxX - 3 && p.y >= sf.minY && p.y < sf.maxY
            }
            // скрытая копия выезжает, только если курсор задержался у края (а не пролетел мимо)
            var edgeReveal = false
            if autoHide(id) && atEdge && v.hideAmount > 0.3 {
                let delay = revealDelay(id)
                if let since = edgeSince[id] {
                    edgeReveal = Date().timeIntervalSince(since) >= delay
                } else {
                    edgeSince[id] = Date()
                    edgeTimers[id]?.invalidate()
                    let t = Timer(timeInterval: delay + 0.05, target: self, selector: #selector(edgeCheck),
                                  userInfo: nil, repeats: false)
                    RunLoop.main.add(t, forMode: .common)
                    edgeTimers[id] = t
                }
            } else {
                edgeSince[id] = nil
                edgeTimers[id]?.invalidate()
                edgeTimers[id] = nil
            }
            let inside = (zone.contains(local) && v.hideAmount < 0.5) || edgeReveal

            if inside {
                let axisLen = g.orientation == .bottom ? v.bounds.width : v.bounds.height
                let base = ((axisLen - g.barLength) / 2).rounded()
                let u = g.orientation == .bottom ? local.x - base : (v.bounds.height - local.y) - base
                v.hoverU = u
                v.lastU = u
                hideTimers[id] = nil
                needAnim = true
                v.relayout()
            } else if v.hoverU != nil {
                v.hoverU = nil
                if autoHide(id) { hideTimers[id] = Date() }
                needAnim = true
                v.needsDisplay = true
            }
        }
        if needAnim { startAnimating() }
    }

    @objc private func edgeCheck() { mouseMoved() }

    private func startAnimating() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(animate), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    @objc private func animate() {
        var busy = false
        let now = Date()
        for (id, m) in mirrors where m.panel.isVisible {
            let v = m.view
            let targetMag: CGFloat = (v.hoverU != nil && prefs.magnification) ? 1 : 0
            var targetHide: CGFloat = 0
            if autoHide(id) {
                if v.hoverU != nil { targetHide = 0 }
                else if let t = hideTimers[id], now.timeIntervalSince(t) < 0.35 { targetHide = 0; busy = true }
                else { targetHide = 1 }
            }
            let step: CGFloat = 1.0 / 8
            let newMag = v.mag + max(-step, min(step, targetMag - v.mag))
            let newHide = v.hideAmount + max(-step * 0.8, min(step * 0.8, targetHide - v.hideAmount))
            let moving = newMag != v.mag || newHide != v.hideAmount
            v.mag = newMag
            v.hideAmount = newHide
            if moving || !bounces.isEmpty { v.relayout(); busy = busy || moving }
        }
        bounces = bounces.filter { now.timeIntervalSince($0.value) < 1.3 }
        if !bounces.isEmpty { busy = true }
        if !busy { animTimer?.invalidate(); animTimer = nil }
    }

    // MARK: действия

    func activate(_ it: Item) {
        switch it.kind {
        case .app:
            if let p = it.path {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: cfg)
            } else { monitor.press(it) }
        case .minimized:
            monitor.press(it)
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .folder, .file, .url:
            if let u = it.url { NSWorkspace.shared.open(u) } else { monitor.press(it) }
        case .separator, .spacer:
            break
        }
    }

    func drop(_ urls: [URL], on it: Item) {
        switch it.kind {
        case .app:
            guard let p = it.path else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: p),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .trash:
            for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        case .folder:
            guard let dir = it.url else { return }
            for u in urls { try? FileManager.default.moveItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
        default: break
        }
    }

    private func runningApp(_ path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
    }

    // MARK: меню

    /// Правый клик. Меню значка берётся у настоящего Дока в фоне и показывается, когда готово.
    /// Пустое место и разделители — как у Дока (меню настроек Дока) + внизу «DoubleMyDock ▸».
    func showContextMenu(for index: Int?, at p: CGPoint, in view: DockView, event: NSEvent) {
        let clicked: Item? = index.flatMap { $0 < items.count ? items[$0] : nil }
        let onEmpty = clicked == nil || clicked?.kind == .separator || clicked?.kind == .spacer

        if onEmpty {
            let sep = (clicked?.kind == .separator ? clicked : nil) ?? items.first { $0.kind == .separator }
            guard axTrusted, let sep, sep.axIndex >= 0 else {
                NSMenu.popUpContextMenu(appMenu(), with: event, for: view)
                return
            }
            requestDockMenu(for: sep, at: p, in: view) { [unowned self] nodes in
                guard let nodes else { return self.appMenu() }
                let m = self.mirrorMenu(nodes, item: sep)
                m.addItem(.separator())
                let title = self.updater.available.map { "DoubleMyDock — доступно обновление \($0.version)" } ?? "DoubleMyDock"
                let sub = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                sub.submenu = self.appMenu()
                m.addItem(sub)
                return m
            }
            return
        }

        guard let it = clicked else { return }
        guard axTrusted, it.axIndex >= 0 else {
            NSMenu.popUpContextMenu(fallbackMenu(for: it), with: event, for: view)
            return
        }
        requestDockMenu(for: it, at: p, in: view) { [unowned self] nodes in
            nodes.map { self.mirrorMenu($0, item: it) } ?? self.fallbackMenu(for: it)
        }
    }

    /// Читает меню у настоящего Дока в фоне и показывает собранное меню, когда оно готово.
    private func requestDockMenu(for it: Item, at p: CGPoint, in view: DockView,
                                 build: @escaping @MainActor ([DockReader.MenuNode]?) -> NSMenu) {
        menuRequest += 1
        let req = menuRequest, started = Date()
        monitor.readMenu(for: it) { [weak self, weak view] nodes in
            MainActor.assumeIsolated {
                guard let self, let view, req == self.menuRequest else { return }
                let dt = Int(Date().timeIntervalSince(started) * 1000)
                guard dt < 2000 else { return }     // слишком поздно — пользователь уже ушёл
                if nodes == nil { dlog("Меню «\(it.title)» не прочиталось за \(dt) мс — показано своё") }
                else if dt > 400 { dlog("Меню «\(it.title)» читалось \(dt) мс") }
                let menu = build(nodes)
                // показываем из цикла событий, а не из очереди, чтобы копия не замирала, пока меню открыто
                RunLoop.main.perform {
                    MainActor.assumeIsolated { _ = menu.popUp(positioning: nil, at: p, in: view) }
                }
            }
        }
    }

    private func mirrorMenu(_ nodes: [DockReader.MenuNode], item it: Item) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func build(_ list: [DockReader.MenuNode], into menu: NSMenu, path: [String]) {
            for n in list {
                if n.title.isEmpty && n.children.isEmpty { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: n.title, action: #selector(dockMenuPick(_:)), keyEquivalent: "")
                mi.target = self
                mi.isEnabled = n.enabled
                mi.state = n.mark.isEmpty ? .off : .on
                mi.representedObject = DockPick(item: it, path: path + [n.title])
                if !n.children.isEmpty {
                    let sub = NSMenu(title: n.title)
                    sub.autoenablesItems = false
                    build(n.children, into: sub, path: path + [n.title])
                    mi.submenu = sub
                    mi.action = nil
                }
                menu.addItem(mi)
            }
        }
        build(nodes, into: m, path: [])
        return m
    }

    private func fallbackMenu(for it: Item) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func item(_ title: String, _ sel: Selector, _ obj: Any?, in menu: NSMenu) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.representedObject = obj
            menu.addItem(mi)
        }
        if let p = it.path {
            let opts = NSMenu(title: "Параметры")
            item("Показать в Finder", #selector(reveal(_:)), p, in: opts)
            let o = NSMenuItem(title: "Параметры", action: nil, keyEquivalent: "")
            o.submenu = opts
            m.addItem(o)
            m.addItem(.separator())
            if it.kind == .app, let app = runningApp(p) {
                item(app.isHidden ? "Показать" : "Скрыть", #selector(toggleHidden(_:)), p, in: m)
                if p != finderPath { item("Завершить", #selector(quitApp(_:)), p, in: m) }
            } else {
                item("Открыть", #selector(openPath(_:)), p, in: m)
            }
        }
        return m
    }

    @objc private func dockMenuPick(_ s: NSMenuItem) {
        guard let pick = s.representedObject as? DockPick else { return }
        monitor.pressMenu(for: pick.item, path: pick.path)
    }

    /// Меню по правому клику на пустом месте панели — настройки DoubleMyDock.
    private func appMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ sel: Selector?) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            m.addItem(mi)
            return mi
        }
        add("DoubleMyDock \(updater.current)", nil).isEnabled = false
        m.addItem(.separator())
        if #available(macOS 13.0, *) {
            add("Открывать при входе", #selector(toggleLogin)).state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        }
        add("Не пускать развёрнутые окна под копию", #selector(toggleFit)).state = fitWindows ? .on : .off
        add(axTrusted ? "Доступ к Доку: есть" : "Доступ к Доку: нет — исправить…", #selector(checkAccessibility))
        m.addItem(.separator())
        if updater.busy {
            add("Обновление…", nil).isEnabled = false
        } else if let a = updater.available {
            add("Обновить до \(a.version)", #selector(installUpdate))
        } else {
            add("Проверить обновления", #selector(checkUpdates))
        }
        add("Открыть журнал", #selector(openLog))
        add("Выйти из DoubleMyDock", #selector(quitSelf))
        return m
    }

    @objc private func toggleHidden(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String, let a = runningApp(p) else { return }
        if a.isHidden { a.unhide() } else { a.hide() }
    }
    @objc private func quitApp(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        runningApp(p)?.terminate()
    }
    @objc private func openPath(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    @objc private func reveal(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { NSSound.beep() }
    }
    @objc private func toggleFit() {
        fitWindows.toggle()
        fitAttempts.removeAll()
        dlog("Не пускать развёрнутые окна под копию: \(fitWindows ? "вкл" : "выкл")")
    }
    @objc private func openLog() {
        dlog("Журнал открыт пользователем")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSWorkspace.shared.open(logger.url) }
    }

    // MARK: доступ к Доку

    /// Проверка разрешения «Универсального доступа» с понятной инструкцией.
    private func askForAccessibility(atLaunch: Bool = false) {
        guard !AXIsProcessTrusted() else { return }
        if atLaunch && UserDefaults.standard.bool(forKey: "dontAskAccessibility") { return }
        presentAlert({
            let a = NSAlert()
            a.messageText = "Нужен доступ к Доку"
            a.informativeText = """
            Без него копия работает в упрощённом режиме: не видит папки, свёрнутые окна, \
            счётчики уведомлений и точный порядок значков.

            Нажмите «Исправить»: DoubleMyDock удалит старую запись (если она осталась от прошлой версии), \
            добавит себя заново и откроет настройки. Там останется включить переключатель у DoubleMyDock.
            """
            a.addButton(withTitle: "Исправить")
            a.addButton(withTitle: "Позже")
            if atLaunch {
                a.showsSuppressionButton = true
                a.suppressionButton?.title = "Больше не показывать"
            }
            return a
        }, then: { [weak self] r, a in
            if atLaunch, a.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "dontAskAccessibility")
            }
            guard r == .alertFirstButtonReturn else { return }
            // старая запись от прошлой подписи выглядит включённой, но не действует — сбрасываем её
            if let id = Bundle.main.bundleIdentifier {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "Accessibility", id]
                try? p.run()
                p.waitUntilExit()
            }
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            self?.openAXSettings()
        })
    }

    private func accessibilityGranted() {
        schedulePoke()
        presentAlert({
            let a = NSAlert()
            a.messageText = "Доступ получен"
            a.informativeText = "Теперь копия повторяет Док полностью."
            return a
        })
    }

    @objc private func checkAccessibility() {
        if AXIsProcessTrusted() {
            presentAlert({
                let a = NSAlert()
                a.messageText = "Доступ к Доку есть"
                a.informativeText = "Копия повторяет Док полностью."
                return a
            })
        } else {
            UserDefaults.standard.set(false, forKey: "dontAskAccessibility")
            askForAccessibility()
        }
    }

    @objc private func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
    @objc private func checkUpdates() { updater.check(userInitiated: true) }
    @objc private func installUpdate() { updater.install() }
    @objc private func quitSelf() {
        dlog("Выход по команде пользователя")
        NSApp.terminate(nil)
    }
}

// MARK: - Запуск

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // без значка в Доке и без меню
    let controller = Controller()
    controller.start()
    withExtendedLifetime(controller) { app.run() }
}
