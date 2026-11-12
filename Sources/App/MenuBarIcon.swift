import AppKit

/// What the status item shows: one provider's limits as rings or bars, with optional
/// percentages and logo.
struct MenuBarConfig: Equatable {
    enum Style: String, CaseIterable, Identifiable {
        case rings, bars, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rings: "Rings"
            case .bars: "Bars"
            case .none: "None"
            }
        }
    }

    enum Numbers: String, CaseIterable, Identifiable {
        case hidden, first, all
        var id: String { rawValue }
    }

    /// nil: the first provider in panel order.
    var provider: ProviderID?
    /// One status item per provider, each with its logo.
    var each = false
    /// Follow whichever provider is closest to a limit.
    var highest = false
    /// Window ids, first to second: outer ring or top bar first.
    var limits: [String]
    var style: Style
    var numbers: Numbers
    var logo: Bool

    static let eachProvider = "each"
    static let highestProvider = "highest"

    static var current: MenuBarConfig {
        let defaults = UserDefaults.standard
        return MenuBarConfig(
            provider: defaults.string(forKey: Prefs.menuBarProviderKey).flatMap(ProviderID.init(rawValue:)),
            each: defaults.string(forKey: Prefs.menuBarProviderKey) == MenuBarConfig.eachProvider,
            highest: defaults.string(forKey: Prefs.menuBarProviderKey) == MenuBarConfig.highestProvider,
            limits: [defaults.string(forKey: Prefs.menuBarFirstKey), defaults.string(forKey: Prefs.menuBarSecondKey)]
                .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } },
            style: defaults.string(forKey: Prefs.menuBarStyleKey).flatMap(Style.init(rawValue:)) ?? .rings,
            numbers: defaults.string(forKey: Prefs.menuBarNumbersKey).flatMap(Numbers.init(rawValue:)) ?? .first,
            logo: defaults.bool(forKey: Prefs.menuBarLogoKey)
        )
    }
}

/// Everything the status item draws, resolved from state. Equatable so the image is only
/// redrawn when something visible changed.
struct MenuBarIcon: Equatable {
    struct Meter: Equatable {
        var label: String
        /// 0...1 or nil when unknown; drawn as track only.
        var used: Double?
    }

    var provider: ProviderID?
    var meters: [Meter]
    var lines: [String]
    var style: MenuBarConfig.Style
    var logo: Bool
    var display: UsageDisplay
    /// The provider can't refresh until the user signs in again, so these numbers are old.
    var stale = false
    /// Some provider needs the user to sign in.
    var badge = false
    /// A chosen limit the plan lacks (no session on Claude Ultra): the app icon's spark fills
    /// the space inside the single ring.
    var spark = false

    static func make(
        states: [ProviderID: ProviderState], enabled: [ProviderID], config: MenuBarConfig, display: UsageDisplay, now: Date = .now
    ) -> MenuBarIcon {
        let provider = config.provider.flatMap { enabled.contains($0) ? $0 : nil }
            ?? (config.highest ? highestUsage(states: states, enabled: enabled, now: now) : nil)
            ?? enabled.first
        let state = provider.flatMap { states[$0] }
        let windows = state?.snapshot?.windows ?? []
        let all = config.limits.map { id in
            let window = Self.window(id, in: windows)
            return (window, Meter(label: window?.label ?? Self.fallbackLabel(id), used: window.flatMap { $0.hasReset(now: now) ? nil : $0.used }))
        }
        // A limit this provider doesn't have (Fable on Codex) is left out rather than drawn
        // as a ring that never fills; with none of them, its main limit stands in so the item
        // never vanishes. Before the first fetch, all are drawn empty.
        let known = all.filter { $0.0 != nil }.map(\.1)
        let stand = windows.first { $0.kind == .primary }.map { [Meter(label: $0.label, used: $0.hasReset(now: now) ? nil : $0.used)] } ?? []
        let meters = windows.isEmpty ? all.map(\.1) : known.isEmpty ? stand : known
        // Nothing to draw and no numbers would leave nothing to click.
        let style = config.style == .none && config.numbers == .hidden && !config.logo ? .rings : config.style
        let numbered = switch config.numbers {
        case .hidden: [Meter]()
        case .first: Array(meters.prefix(1))
        case .all: meters
        }
        return MenuBarIcon(
            provider: provider,
            meters: style == .none ? [] : meters,
            lines: numbered.compactMap { $0.used.map(display.text) },
            style: style,
            logo: (config.logo || config.each || config.highest) && provider != nil,
            display: display,
            stale: state?.needsSignIn == true,
            // One item per provider: each carries only its own dot. Only a sign-in that worked
            // before: a provider never signed in isn't worth a permanent dot.
            badge: config.each ? lapsed(state) : enabled.contains { lapsed(states[$0]) },
            spark: style == .rings && !windows.isEmpty && meters.count == 1 && config.limits.count > 1
        )
    }

    private static func lapsed(_ state: ProviderState?) -> Bool {
        state.map { $0.needsSignIn && $0.snapshot != nil } == true
    }

    /// The provider with the fullest limit that still counts (not past its reset). Ties keep
    /// panel order. Logo on, so it's clear which one is shown.
    static func highestUsage(states: [ProviderID: ProviderState], enabled: [ProviderID], now: Date) -> ProviderID? {
        let usage = { (id: ProviderID) in
            states[id]?.snapshot?.windows.filter { !$0.hasReset(now: now) }.map(\.used).max() ?? -1
        }
        return enabled.max { usage($0) < usage($1) || (usage($0) == usage($1) && enabled.firstIndex(of: $0)! > enabled.firstIndex(of: $1)!) }
    }

    /// Codex labels windows by length; when lengths are missing they fall back to slot order.
    static func window(_ id: String, in windows: [UsageWindow]) -> UsageWindow? {
        if let exact = windows.first(where: { $0.id == id }) { return exact }
        let primary = windows.filter { $0.kind == .primary }
        let session = primary.first { $0.id != "weekly" }
        switch id {
        case "session": return session
        case "weekly": return primary.first { $0.id != session?.id }
        default: return nil
        }
    }

    static func fallbackLabel(_ id: String) -> String {
        id == "session" ? "Session" : id == "weekly" ? "Weekly" : id
    }

    private static let height: CGFloat = 22
    private static let logoSize: CGFloat = 14
    private static let ringsWidth: CGFloat = 18
    private static let barsWidth: CGFloat = 22

    /// One template image so it follows the menu bar's appearance. Faint tracks keep the
    /// mark recognizable at 0%; stale numbers are dimmed; the dot means a sign-in needs the user.
    func image() -> NSImage {
        let ink = NSColor.black.withAlphaComponent(stale ? 0.4 : 1)
        let font = NSFont.monospacedDigitSystemFont(ofSize: lines.count > 1 ? 11 : 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        let logoImage = logo ? provider.flatMap { NSImage(named: $0.logoAsset) } : nil
        // No logo or meters: the dot sits ahead of the numbers.
        let dotWidth: CGFloat = logoImage == nil && meters.isEmpty && badge ? 6 : 0
        let logoWidth = logoImage == nil ? dotWidth : Self.logoSize + (meters.isEmpty ? 0 : 4)
        let meterWidth = meters.isEmpty ? 0 : style == .rings ? Self.ringsWidth : Self.barsWidth
        let lead = logoWidth + meterWidth
        let width = lead + (lines.isEmpty ? 0 : (lead > 0 ? 4 : 0) + ceil(textWidth))
        let image = NSImage(size: NSSize(width: max(width, 6), height: Self.height), flipped: false) { _ in
            if let logoImage {
                let rect = NSRect(x: 0, y: (Self.height - Self.logoSize) / 2, width: Self.logoSize, height: Self.logoSize)
                Self.tinted(logoImage, ink).draw(in: rect)
            }
            let meterRect = NSRect(x: logoWidth, y: 2, width: meterWidth, height: 18)
            switch style {
            case .rings: drawRings(in: meterRect, ink: ink)
            case .bars: drawBars(in: meterRect, ink: ink)
            case .none: break
            }
            if spark {
                ink.setFill()
                Self.spark(at: NSPoint(x: meterRect.midX, y: meterRect.midY), radius: 4.4).fill()
            }
            // Lay digits out by cap height so the block is optically centered.
            let gap: CGFloat = 3
            let block = font.capHeight * CGFloat(lines.count) + gap * CGFloat(max(lines.count - 1, 0))
            let textX = lead + (lead > 0 ? 4 : 0)
            for (index, line) in lines.enumerated() {
                let baseline = (Self.height + block) / 2 - font.capHeight - CGFloat(index) * (font.capHeight + gap)
                (line as NSString).draw(at: NSPoint(x: textX, y: baseline + font.descender), withAttributes: attributes)
            }
            if badge && dotWidth > 0 {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: Self.height / 2 - 2.7, width: 5.4, height: 5.4)).fill()
            } else if badge {
                let anchor = meters.isEmpty ? NSPoint(x: Self.logoSize - 1.5, y: 16.5) : NSPoint(x: meterRect.maxX - 3.5, y: 16.5)
                Self.drawBadge(at: anchor)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityText
        return image
    }

    private var accessibilityText: String {
        let mode = display == .used ? "used" : "left"
        let parts = meters.map { "\($0.label) \($0.used.map(display.text) ?? "unknown") \(mode)" }
        return (["Tokei", provider?.name].compactMap(\.self).joined(separator: " ") + ": " + parts.joined(separator: ", "))
            + (badge ? ". Sign-in needed" : "")
    }

    /// First meter on the outside.
    private func drawRings(in rect: NSRect, ink: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radii: [CGFloat] = meters.count == 1 ? [7] : [7, 3.6]
        for (meter, radius) in zip(meters, radii) {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = meters.count == 1 && !spark ? 2.6 : 2.2
            ink.withAlphaComponent(ink.alphaComponent * 0.3).setStroke()
            track.stroke()
            guard let used = meter.used else { continue }
            let value = display.value(used)
            guard value > 0 else { continue }
            let sweep = min(value, 1) * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = track.lineWidth
            arc.lineCapStyle = sweep >= 360 ? .butt : .round
            ink.setStroke()
            arc.stroke()
        }
    }

    /// First meter on top.
    private func drawBars(in rect: NSRect, ink: NSColor) {
        let thickness: CGFloat = meters.count == 1 ? 5 : 4
        let gap: CGFloat = 3
        let block = thickness * CGFloat(meters.count) + gap * CGFloat(meters.count - 1)
        for (index, meter) in meters.enumerated() {
            let y = rect.midY + block / 2 - thickness - CGFloat(index) * (thickness + gap)
            let track = NSRect(x: rect.minX, y: y, width: rect.width, height: thickness)
            ink.withAlphaComponent(ink.alphaComponent * 0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: thickness / 2, yRadius: thickness / 2).fill()
            guard let used = meter.used else { continue }
            let value = min(max(display.value(used), 0), 1)
            guard value > 0 else { continue }
            var fill = track
            fill.size.width = max(thickness, track.width * value)
            ink.setFill()
            NSBezierPath(roundedRect: fill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
    }

    /// Cuts a gap around the dot so it reads as a separate mark.
    private static func drawBadge(at point: NSPoint) {
        let circle = { (radius: CGFloat) in
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        NSGraphicsContext.current?.compositingOperation = .clear
        circle(4).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        circle(2.7).fill()
    }

    /// Four-point star from Sources/AppIcon.icon/Assets/spark.svg: curves pulled 30% toward the center.
    private static func spark(at center: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let point = { (x: CGFloat, y: CGFloat) in NSPoint(x: center.x + x * r, y: center.y + y * r) }
        let tips: [(CGFloat, CGFloat)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
        let path = NSBezierPath()
        path.move(to: point(0, 1))
        for (index, tip) in tips.enumerated() {
            let next = tips[(index + 1) % tips.count]
            // The SVG's quadratic control point, raised to cubic: 2/3 of the way from each end.
            let control = ((tip.0 + next.0) * 0.3, (tip.1 + next.1) * 0.3)
            path.curve(
                to: point(next.0, next.1),
                controlPoint1: point(tip.0 + (control.0 - tip.0) * 2 / 3, tip.1 + (control.1 - tip.1) * 2 / 3),
                controlPoint2: point(next.0 + (control.0 - next.0) * 2 / 3, next.1 + (control.1 - next.1) * 2 / 3)
            )
        }
        path.close()
        return path
    }

    /// The logo in the same ink as the meters, so it dims with them.
    private static func tinted(_ logo: NSImage, _ ink: NSColor) -> NSImage {
        NSImage(size: logo.size, flipped: false) { rect in
            logo.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

extension ProviderID {
    var logoAsset: String {
        switch self {
        case .claude: "ClaudeMark"
        case .codex: "CodexMark"
        }
    }
}
