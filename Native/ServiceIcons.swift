import AppKit

@MainActor
enum NativeIcons {
    private static var images: [NativeService: NSImage] = [:]

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
