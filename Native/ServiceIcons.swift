import AppKit

@MainActor
enum NativeIcons {
    private static var images: [NativeService: NSImage] = [:]

    static let camera: NSImage = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.black.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5, width: 14, height: 14), xRadius: 3, yRadius: 3)
            body.lineWidth = 1.8
            body.stroke()
            let lens = NSBezierPath()
            lens.move(to: NSPoint(x: 16, y: 10))
            lens.line(to: NSPoint(x: 22, y: 6.5))
            lens.line(to: NSPoint(x: 22, y: 17.5))
            lens.line(to: NSPoint(x: 16, y: 14))
            lens.lineWidth = 1.8
            lens.lineJoinStyle = .round
            lens.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func image(for service: NativeService) -> NSImage {
        if let image = images[service] { return image }
        let size = NSSize(width: 24, height: 24)
        guard let url = Bundle.main.url(forResource: service.rawValue, withExtension: "png", subdirectory: "ServiceIcons"),
              let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            return NSImage(size: size)
        }
        let scale = min(size.width / source.size.width, size.height / source.size.height)
        let drawSize = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2,
                          width: drawSize.width, height: drawSize.height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        images[service] = image
        return image
    }
}
