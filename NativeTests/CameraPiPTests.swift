import AppKit

@main
struct CameraPiPTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "local.nook.tests.pip." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 899, height: 664),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = window.contentView!
        let pip = CameraPiPView(defaults: defaults)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func layout() { host.layoutSubtreeIfNeeded() }
        func mouse(_ type: NSEvent.EventType, point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        pip.show(in: host)
        layout()
        expect(pip.frame == NSRect(x: 563, y: 16, width: 320, height: 180), "PiP starts inset at bottom right")
        for (corner, origin) in [(CameraPiPCorner.topLeft, NSPoint(x: 16, y: 468)),
                                 (.topRight, NSPoint(x: 563, y: 468)),
                                 (.bottomLeft, NSPoint(x: 16, y: 16)),
                                 (.bottomRight, NSPoint(x: 563, y: 16))] {
            pip.snap(to: corner)
            layout()
            expect(pip.frame.origin == origin, "Every corner must use the same content inset")
            expect(pip.corner == corner, "Snapping updates the selected corner")
        }
        pip.snap(to: .topRight)
        window.setContentSize(NSSize(width: 1199, height: 864))
        layout()
        expect(pip.frame == NSRect(x: 863, y: 668, width: 320, height: 180), "PiP follows its corner when the window grows")
        window.setContentSize(NSSize(width: 899, height: 664))
        layout()
        expect(pip.frame.origin == NSPoint(x: 563, y: 468), "PiP remains inside the window when it shrinks")

        let video = NSView(frame: pip.videoContainer.bounds)
        pip.videoContainer.addSubview(video)
        expect(pip.videoContainer.layer?.masksToBounds == true, "Embedded video is clipped at the rounded border")
        expect(pip.videoContainer.layer?.cornerRadius == 14, "Video uses the rounded container corners")
        expect(pip.shadow != nil, "The overlay uses a native view shadow outside the clipped video")
        expect(pip.hitTest(NSPoint(x: pip.frame.midX, y: pip.frame.midY)) === pip,
               "Video child views must not swallow the drag gesture")
        for (point, origin, corner) in [(NSPoint(x: -1000, y: 1000), NSPoint(x: 16, y: 468), CameraPiPCorner.topLeft),
                                       (NSPoint(x: 2000, y: 1000), NSPoint(x: 563, y: 468), .topRight),
                                       (NSPoint(x: -1000, y: -1000), NSPoint(x: 16, y: 16), .bottomLeft),
                                       (NSPoint(x: 2000, y: -1000), NSPoint(x: 563, y: 16), .bottomRight)] {
            let center = NSPoint(x: pip.frame.midX, y: pip.frame.midY)
            pip.mouseDown(with: mouse(.leftMouseDown, point: center))
            pip.mouseDragged(with: mouse(.leftMouseDragged, point: point))
            expect(pip.frame.origin == origin, "Dragging cannot push the video outside the content area")
            pip.mouseUp(with: mouse(.leftMouseUp, point: point))
            layout()
            expect(pip.corner == corner && pip.frame.origin == origin, "Releasing a drag snaps to the nearest corner")
        }
        let dragOrigin = NSPoint(x: pip.frame.midX, y: pip.frame.midY)
        pip.mouseDown(with: mouse(.leftMouseDown, point: dragOrigin))
        pip.mouseDragged(with: mouse(.leftMouseDragged, point: NSPoint(x: 360, y: 290)))
        expect(pip.frame.origin == NSPoint(x: 200, y: 200), "Dragging follows the pointer before it is released")
        pip.mouseUp(with: mouse(.leftMouseUp, point: NSPoint(x: 360, y: 290)))
        layout()
        expect(pip.corner == .bottomLeft && pip.frame.origin == NSPoint(x: 16, y: 16), "Release from the interior snaps to the nearer bottom-left corner")
        pip.snap(to: .bottomRight)
        let cover = NSView(frame: host.bounds)
        host.addSubview(cover)
        pip.show(in: host)
        layout()
        expect(host.subviews.last === pip, "Showing PiP again keeps it above newly selected web views")
        expect(pip.frame.origin == NSPoint(x: 563, y: 16), "Showing again preserves corner placement")
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "",
                                   charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        pip.keyDown(with: left)
        layout()
        expect(pip.corner == .bottomLeft && pip.frame.origin == NSPoint(x: 16, y: 16), "Keyboard users can change the corner")
        var returns = 0
        pip.onReturnToCamera = { returns += 1 }
        pip.mouseDown(with: mouse(.leftMouseDown, point: NSPoint(x: 176, y: 106), clicks: 2))
        expect(returns == 1, "Double-click returns to the Camera tab")
        expect(pip.accessibilityPerformPress() && returns == 2, "Assistive technology can return to the Camera tab")
        pip.dismiss()
        expect(pip.superview == nil && video.superview === pip.videoContainer, "Dismissing only removes the overlay, not its live renderer")
        let restored = CameraPiPView(defaults: defaults)
        restored.show(in: host)
        layout()
        expect(restored.corner == .bottomLeft && restored.frame.origin == NSPoint(x: 16, y: 16), "The chosen corner survives recreating the overlay")
        restored.dismiss()
        print("\(checks) camera PiP checks passed")
    }
}
