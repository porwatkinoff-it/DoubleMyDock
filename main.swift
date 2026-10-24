// DoubleMyDock — копия системного Дока на всех мониторах, где его нет.
//
// Как это работает:
//  • Через Accessibility (то же API, что у VoiceOver) читаем настоящий Док:
//    элементы по порядку, разделители, папки, корзину, свёрнутые окна,
//    точки запущенных программ, счётчики уведомлений и точную геометрию.
//  • Рисуем то же самое на других мониторах: «жидкое стекло» на macOS 26,
//    увеличение при наведении, автоскрытие и положение — из настроек Дока.
//  • Нагрузка минимальная: Док опрашивается раз в секунду (несколько мс),
//    анимации крутятся только пока что-то движется.
//  • Без доступа к Accessibility работает в упрощённом режиме по настройкам Дока.

import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

let finderPath = "/System/Library/CoreServices/Finder.app"

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
        if let arr = v("persistent-apps") as? [[String: Any]] {
            for e in arr {
                guard let t = e["tile-data"] as? [String: Any],
                      let f = t["file-data"] as? [String: Any],
                      let s = f["_CFURLString"] as? String else { continue }
                let u = s.hasPrefix("/") ? URL(fileURLWithPath: s) : URL(string: s)
                if let u, u.isFileURL { p.pinned.append(u.standardizedFileURL.path) }
            }
        }
        return p
    }
}

// MARK: - Чтение настоящего Дока через Accessibility

final class DockReader {
    private var pid: pid_t = 0
    private var appEl: AXUIElement?
    private(set) var elements: [AXUIElement] = []

    private func copy(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private func str(_ e: AXUIElement, _ a: String) -> String? { copy(e, a) as? String }
    private func children(_ e: AXUIElement) -> [AXUIElement] { (copy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private func axValue(_ e: AXUIElement, _ a: String) -> AXValue? {
        guard let v = copy(e, a), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = axValue(e, kAXPositionAttribute), let sv = axValue(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p)
        AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Элементы Дока, их рамки и рамка самой панели (в координатах AX: от левого верхнего угла).
    func read() -> (items: [Item], frames: [CGRect], list: CGRect)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        if dock.processIdentifier != pid || appEl == nil {
            pid = dock.processIdentifier
            appEl = AXUIElementCreateApplication(pid)
        }
        guard let appEl,
              let list = children(appEl).first(where: { str($0, kAXRoleAttribute) == kAXListRole }),
              let listFrame = frame(list) else { return nil }

        var items: [Item] = [], frames: [CGRect] = []
        elements = children(list)
        for (i, e) in elements.enumerated() {
            let sub = str(e, kAXSubroleAttribute) ?? ""
            let title = str(e, kAXTitleAttribute) ?? ""
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
            let url = copy(e, "AXURL") as? URL
            let running = (copy(e, "AXIsApplicationRunning") as? NSNumber)?.boolValue ?? false
            let badge = str(e, "AXStatusLabel").flatMap { $0.isEmpty ? nil : $0 }
            items.append(Item(kind: kind, title: title,
                              path: (url?.isFileURL ?? false) ? url!.standardizedFileURL.path : nil,
                              url: url, running: running, badge: badge, axIndex: i))
            frames.append(frame(e) ?? .zero)
        }
        return (items, frames, listFrame)
    }

    func press(_ index: Int) {
        guard index >= 0, index < elements.count else { return }
        AXUIElementPerformAction(elements[index], kAXPressAction as CFString)
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
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    return p
}

// MARK: - Вид Дока на одном мониторе

@MainActor
final class DockView: NSView {
    unowned let controller: Controller
    var background: NSView!
    var hoverU: CGFloat?          // положение курсора вдоль панели (в базовых координатах)
    var lastU: CGFloat = 0
    var mag: CGFloat = 0          // 0…1 — насколько включено увеличение
    var hidden: CGFloat = 0       // 0…1 — для автоскрытия
    var pressedIndex: Int?
    var dropIndex: Int?

    // вычисленная раскладка (в координатах вида)
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
        guard n > 0, g.centers.count == n else { iconRects = []; barRect = .zero; return }
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
        // сдвиг, чтобы точка под курсором не уезжала
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

        // база вдоль оси: панель по центру экрана
        let axisLen = g.orientation == .bottom ? bounds.width : bounds.height
        let base = ((axisLen - g.barLength) / 2).rounded()
        let edgeOff = g.gap - hidden * (g.gap + g.barThickness + 2)
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
            let mid = (newEdges[i] + newEdges[i + 1]) / 2 + shift
            let sz = sizes[i]
            var r = rect(along: mid - sz / 2, sz, cross: baseline + controller.bounceOffset(items[i]), sz)
            if items[i].kind == .separator || items[i].kind == .spacer {
                r = rect(along: newEdges[i] + shift, newEdges[i + 1] - newEdges[i], cross: 0, g.barThickness)
            }
            return r
        }
        background.frame = barRect.integral
        needsDisplay = true
    }

    // MARK: рисование

    override func draw(_ dirtyRect: NSRect) {
        let items = controller.items, g = controller.geometry
        guard iconRects.count == items.count else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
            let img = controller.icon(for: it)
            if pressedIndex == i || dropIndex == i {
                let darker = NSImage(size: r.size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor(white: 0, alpha: 0.35).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                darker.draw(in: r)
            } else {
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            }

            if it.running {
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
        if let i, i == was { controller.activate(controller.items[i]) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        let menu = controller.menu(for: i.map { controller.items[$0] })
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    // MARK: перетаскивание файлов на значки (открыть программой / в корзину)

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        let i = index(at: convert(s.draggingLocation, from: nil))
        let ok = i.map { [.app, .trash, .folder].contains(controller.items[$0].kind) } ?? false
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
        guard let i = index(at: convert(s.draggingLocation, from: nil)),
              let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty
        else { return false }
        controller.drop(urls, on: controller.items[i])
        return true
    }
}

// MARK: - Контроллер

@MainActor
final class Controller: NSObject {
    struct Mirror { let panel: NSPanel; let view: DockView }

    private(set) var items: [Item] = []
    private(set) var geometry = Geometry()
    private(set) var prefs = DockPrefs()
    private var mirrors: [CGDirectDisplayID: Mirror] = [:]
    private let reader = DockReader()
    private var iconCache: [String: NSImage] = [:]
    private let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    private var lastDockScreen: CGDirectDisplayID?
    private var animTimer: Timer?
    private var bounces: [String: Date] = [:]
    private var hideTimers: [CGDirectDisplayID: Date] = [:]
    private var axTrusted = false
    private var ticks = 0

    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(opts)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(appWillLaunch(_:)), name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        wnc.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wnc.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }
        let t = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.3
        refresh(force: true)
    }

    // MARK: события

    @objc private func appsChanged() { refresh(force: false) }
    @objc private func screensChanged() { refresh(force: true) }
    @objc private func tick() {
        ticks += 1
        if !axTrusted && ticks % 3 == 0 { axTrusted = AXIsProcessTrusted() }
        refresh(force: false)
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

    // MARK: чтение состояния

    private func refresh(force: Bool) {
        let newPrefs = DockPrefs.read()
        var newItems = items, newGeo = geometry
        var dockScreen: CGDirectDisplayID? = nil

        if axTrusted, let r = reader.read() {
            newItems = r.items
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let cocoaList = CGRect(x: r.list.minX, y: primaryH - r.list.maxY, width: r.list.width, height: r.list.height)
            let screen = NSScreen.screens.first { $0.frame.intersects(cocoaList.insetBy(dx: 1, dy: 1)) }
            dockScreen = screen.map(displayID)

            // геометрию обновляем, только когда настоящий Док не увеличен под курсором
            let tiles = zip(r.items, r.frames).filter { $0.0.kind != .separator && $0.0.kind != .spacer }
            let vertical = newPrefs.orientation != .bottom
            let lens = tiles.map { vertical ? $0.1.height : $0.1.width }
            let calm = (lens.max() ?? 0) - (lens.min() ?? 0) < 1.5
            if calm || force || geometry.centers.count != r.items.count, let screen {
                var g = Geometry()
                g.orientation = newPrefs.orientation
                g.icon = newPrefs.tile
                if vertical {
                    g.barLength = r.list.height
                    g.barThickness = r.list.width
                    g.centers = r.frames.map { $0.midY - r.list.minY }
                    g.gap = newPrefs.orientation == .left
                        ? cocoaList.minX - screen.frame.minX
                        : screen.frame.maxX - cocoaList.maxX
                } else {
                    g.barLength = r.list.width
                    g.barThickness = r.list.height
                    g.centers = r.frames.map { $0.midX - r.list.minX }
                    g.gap = cocoaList.minY - screen.frame.minY
                }
                if !calm, geometry.centers.count == r.items.count { g.centers = geometry.centers; g.barLength = geometry.barLength }
                g.gap = min(max(g.gap, 0), 40)
                if g.barThickness < g.icon { g.barThickness = (g.icon * 1.3).rounded() }
                newGeo = g
            }
        } else {
            (newItems, newGeo) = fallbackLayout(newPrefs)
        }

        if dockScreen == nil { dockScreen = visibleFrameDockScreen() ?? lastDockScreen }
        lastDockScreen = dockScreen

        let changed = force || newItems != items || newGeo != geometry || newPrefs != prefs
        items = newItems; geometry = newGeo; prefs = newPrefs
        layoutPanels(dockScreen: dockScreen, redraw: changed)
    }

    /// Без Accessibility: закреплённые + запущенные + корзина, отступы как у Дока.
    private func fallbackLayout(_ p: DockPrefs) -> ([Item], Geometry) {
        let me = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != me }
            .compactMap { $0.bundleURL?.standardizedFileURL.path }
        let runSet = Set(running)
        let pinned = [finderPath] + p.pinned.filter { $0 != finderPath && FileManager.default.fileExists(atPath: $0) }
        var extra: [String] = []
        for r in running where !pinned.contains(r) && !extra.contains(r) { extra.append(r) }
        func app(_ path: String) -> Item {
            var name = FileManager.default.displayName(atPath: path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            return Item(kind: .app, title: name, path: path, url: URL(fileURLWithPath: path),
                        running: runSet.contains(path), badge: nil, axIndex: -1)
        }
        let sep = Item(kind: .separator, title: "", path: nil, url: nil, running: false, badge: nil, axIndex: -1)
        var list = pinned.map(app)
        if !extra.isEmpty { list.append(sep); list += extra.map(app) }
        list.append(sep)
        list.append(Item(kind: .trash, title: "Корзина", path: NSHomeDirectory() + "/.Trash",
                         url: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"), running: false, badge: nil, axIndex: -1))

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
        return (list, g)
    }

    func icon(for it: Item) -> NSImage {
        let key: String
        switch it.kind {
        case .trash: key = "#trash"
        case .minimized: key = "#min"
        case .url: key = "#url"
        default: key = it.path ?? "#doc"
        }
        if let i = iconCache[key] { return i }
        let img: NSImage
        switch it.kind {
        case .trash: img = NSImage(named: NSImage.trashEmptyName) ?? NSWorkspace.shared.icon(for: .folder)
        case .url: img = NSImage(named: NSImage.networkName) ?? NSWorkspace.shared.icon(for: .internetLocation)
        case .minimized: img = NSImage(named: NSImage.multipleDocumentsName) ?? NSWorkspace.shared.icon(for: .data)
        default: img = it.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .data)
        }
        iconCache[key] = img
        return img
    }

    // MARK: экраны

    private func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    private func visibleFrameDockScreen() -> CGDirectDisplayID? {
        for s in NSScreen.screens {
            let f = s.frame, v = s.visibleFrame
            if v.minY - f.minY > 0.5 || v.minX - f.minX > 0.5 || f.maxX - v.maxX > 0.5 { return displayID(s) }
        }
        return nil
    }

    private func makeMirror() -> Mirror {
        let p = makePanel(level: dockLevel)
        let root = NSView()
        root.wantsLayer = true
        let view = DockView(controller: self)
        view.autoresizingMask = [.width, .height]

        let bg: NSView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()        // то же «жидкое стекло», что у Дока в Tahoe
            bg = glass
        } else { bg = Controller.legacyBackground() }
        #else
        bg = Controller.legacyBackground()
        #endif
        root.addSubview(bg)
        root.addSubview(view)
        view.background = bg
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
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
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

    private func layoutPanels(dockScreen: CGDirectDisplayID?, redraw: Bool) {
        var seen = Set<CGDirectDisplayID>()
        for s in NSScreen.screens {
            let id = displayID(s)
            seen.insert(id)
            if id == dockScreen && NSScreen.screens.count > 1 || NSScreen.screens.count == 1 {
                mirrors[id]?.panel.orderOut(nil)
                continue
            }
            let m: Mirror
            if let e = mirrors[id] { m = e } else { m = makeMirror(); mirrors[id] = m }
            let fr = panelFrame(on: s)
            if m.panel.frame != fr { m.panel.setFrame(fr, display: false) }
            if redraw {
                applyRadius(m.view.background)
                if prefs.autohide && m.view.hoverU == nil { m.view.hidden = 1 } else if !prefs.autohide { m.view.hidden = 0 }
                m.view.relayout()
            }
            if !m.panel.isVisible { m.panel.orderFrontRegardless() }
        }
        for (id, m) in mirrors where !seen.contains(id) { m.panel.orderOut(nil); mirrors[id] = nil }
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
            // край экрана тоже «зона», если Док скрыт
            let sf = m.panel.screen?.frame ?? .zero
            let atEdge: Bool
            switch g.orientation {
            case .bottom: atEdge = p.y <= sf.minY + 2 && p.x >= sf.minX && p.x <= sf.maxX
            case .left:   atEdge = p.x <= sf.minX + 2 && p.y >= sf.minY && p.y <= sf.maxY
            case .right:  atEdge = p.x >= sf.maxX - 3 && p.y >= sf.minY && p.y <= sf.maxY
            }
            let inside = zone.contains(local) || (prefs.autohide && atEdge && v.hidden > 0.5)

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
                if prefs.autohide { hideTimers[id] = Date() }
                needAnim = true
                v.needsDisplay = true
            }
        }
        if needAnim { startAnimating() }
    }

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
            if prefs.autohide {
                if v.hoverU != nil { targetHide = 0 }
                else if let t = hideTimers[id], now.timeIntervalSince(t) < 0.35 { targetHide = 0; busy = true }
                else { targetHide = 1 }
            }
            let step: CGFloat = 1.0 / 8
            let newMag = v.mag + max(-step, min(step, targetMag - v.mag))
            let newHide = v.hidden + max(-step * 0.8, min(step * 0.8, targetHide - v.hidden))
            if newMag != v.mag || newHide != v.hidden { busy = true }
            v.mag = newMag
            v.hidden = newHide
            v.relayout()
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
            } else { reader.press(it.axIndex) }
        case .minimized:
            reader.press(it.axIndex)
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .folder, .file, .url:
            if let u = it.url { NSWorkspace.shared.open(u) } else { reader.press(it.axIndex) }
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

    func menu(for it: Item?) -> NSMenu {
        let m = NSMenu()
        @discardableResult
        func add(_ title: String, _ sel: Selector, _ obj: Any? = nil) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.representedObject = obj
            m.addItem(mi)
            return mi
        }
        if let it, let p = it.path {
            if it.kind == .app, let app = runningApp(p) {
                add(app.isHidden ? "Показать" : "Скрыть", #selector(toggleHidden(_:)), p)
                if p != finderPath { add("Завершить", #selector(quitApp(_:)), p) }
            } else if it.kind == .app {
                add("Открыть", #selector(openPath(_:)), p)
            }
            add("Показать в Finder", #selector(reveal(_:)), p)
            m.addItem(.separator())
        }
        if #available(macOS 13.0, *) {
            add("Открывать при входе", #selector(toggleLogin)).state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        }
        if !axTrusted { add("Разрешить доступ к Доку…", #selector(openAXSettings)) }
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
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration())
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
    @objc private func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
    @objc private func quitSelf() { NSApp.terminate(nil) }
}

// MARK: - Запуск

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // без значка в Доке и без меню
    let controller = Controller()
    controller.start()
    withExtendedLifetime(controller) { app.run() }
}
