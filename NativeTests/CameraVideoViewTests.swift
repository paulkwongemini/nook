import AppKit

@main
struct CameraVideoViewTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = window.contentView!
        let video = CameraVideoView(frame: host.bounds)
        host.addSubview(video)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func near(_ actual: CGFloat, _ expected: CGFloat) -> Bool { abs(actual - expected) < 0.001 }
        func rectNear(_ actual: CGRect, _ expected: CGRect) -> Bool {
            near(actual.minX, expected.minX) && near(actual.minY, expected.minY)
                && near(actual.width, expected.width) && near(actual.height, expected.height)
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: video.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ start: NSPoint, _ end: NSPoint) {
            video.mouseDown(with: mouse(.leftMouseDown, start))
            video.mouseDragged(with: mouse(.leftMouseDragged, end))
            video.mouseUp(with: mouse(.leftMouseUp, end))
        }
        video.layoutSubtreeIfNeeded()
        expect(video.displayedVideoRect == CGRect(x: 0, y: 60, width: 640, height: 360),
               "The full source image fits inside the viewport with centered letterboxing")
        expect(video.drawable.frame == video.displayedVideoRect && video.layer?.masksToBounds == true,
               "Zoom must resize the full native drawable inside a clipped viewport")
        expect(video.hitTest(NSPoint(x: 320, y: 240)) === video,
               "Native playback child views cannot consume pan gestures")
        drag(NSPoint(x: 320, y: 240), NSPoint(x: 100, y: 100))
        expect(video.center == CGPoint(x: 0.5, y: 0.5), "The complete unzoomed image cannot be panned")

        var zoomChanges: [CGFloat] = []
        video.onZoomChange = { zoomChanges.append($0) }
        video.setZoom(2)
        expect(video.displayedVideoRect == CGRect(x: -320, y: -120, width: 1280, height: 720),
               "Digital zoom enlarges the original aspect-fitted frame about its center")
        video.setZoom(20)
        expect(video.zoom == 4, "Zoom cannot exceed the supported maximum")
        video.setZoom(-5)
        expect(video.zoom == 1 && video.displayedVideoRect == CGRect(x: 0, y: 60, width: 640, height: 360),
               "Zooming out returns to the entire original image")
        video.setZoom(.nan)
        expect(video.zoom == 1 && zoomChanges == [2, 4, 1], "Invalid zoom cannot corrupt geometry or notify a false change")

        video.setZoom(2)
        video.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 320, y: 240)))
        video.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 300, y: 240)))
        video.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 280, y: 240)))
        video.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 280, y: 240)))
        expect(near(video.displayedVideoRect.minX, -360), "Panning follows every movement during a continuous drag")
        video.resetView()
        video.setZoom(2)
        drag(NSPoint(x: 320, y: 240), NSPoint(x: 2000, y: 2000))
        expect(video.displayedVideoRect.origin == .zero && near(video.center.x, 0.25) && near(video.center.y, 1 / 3),
               "Panning toward the bottom-left stops at the image edges without empty borders")
        drag(NSPoint(x: 320, y: 240), NSPoint(x: -2000, y: -2000))
        expect(rectNear(video.displayedVideoRect, CGRect(x: -640, y: -240, width: 1280, height: 720)),
               "Panning toward the top-right clamps both far image edges")

        let pannedCenter = video.center
        let pipHost = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        host.addSubview(pipHost)
        video.removeFromSuperview()
        pipHost.addSubview(video)
        video.frame = pipHost.bounds
        video.layoutSubtreeIfNeeded()
        expect(video.zoom == 2 && video.center == pannedCenter,
               "Reparenting and resizing into PiP preserve zoom and legal pan position")
        expect(near(video.displayedVideoRect.width, 640) && near(video.displayedVideoRect.height, 360),
               "The retained native drawable resizes to the PiP viewport")
        video.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 160, y: 90)))
        video.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 140, y: 90)))
        video.resetView()
        expect(video.zoom == 1 && video.center == CGPoint(x: 0.5, y: 0.5),
               "Reset restores the full original view")
        video.setZoom(2)
        video.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 120, y: 90)))
        expect(video.center == CGPoint(x: 0.5, y: 0.5), "Reset cancels an unfinished pan gesture")
        video.resetView()
        video.videoSize = CGSize(width: 4, height: 3)
        expect(video.displayedVideoRect == CGRect(x: 40, y: 0, width: 240, height: 180),
               "Actual source dimensions replace the default aspect ratio")
        video.videoSize = .zero
        expect(video.displayedVideoRect == CGRect(x: 40, y: 0, width: 240, height: 180),
               "Invalid source dimensions must not damage valid playback geometry")
        print("\(checks) camera video viewport checks passed")
    }
}
