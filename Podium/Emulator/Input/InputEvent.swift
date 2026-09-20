import Foundation

/// A touch in the virtual device's own coordinate space (960×640 points,
/// origin top-left) — never a SwiftUI/UIKit coordinate. The UI layer is
/// responsible for that mapping before an event reaches the emulator core.
struct TouchPoint: Equatable {
    let x: Double
    let y: Double
    let touchID: Int
}

/// An abstract input event the emulator core can consume, independent of
/// SwiftUI. This is what Section 12/19 of the project spec calls for:
/// user touch → Podium coordinate system → virtual touchscreen → guest,
/// with nothing SwiftUI-specific past the UI layer.
enum InputEvent: Equatable {
    case touchBegan(TouchPoint)
    case touchMoved(TouchPoint)
    case touchEnded(TouchPoint)
    case homeButton(pressed: Bool)
    case powerButton(pressed: Bool)
    case volumeUp(pressed: Bool)
    case volumeDown(pressed: Bool)
}
