import CoreGraphics

/// The one place that converts between the two screen coordinate systems
/// macOS uses.
///
/// - Accessibility (and Core Graphics) put the origin at the top-left of the
///   primary display (the one with the menu bar), with y growing downward.
/// - AppKit (`NSScreen`, `NSWindow`) puts the origin at the bottom-left of
///   the primary display, with y growing upward.
///
/// Both span every display, so a display left of the primary one has
/// negative x in both, and a display above it has negative y in
/// Accessibility coordinates but y ≥ primary height in AppKit coordinates.
///
/// ATLAS works in Accessibility coordinates everywhere (layouts, the
/// resolver, window frames) and converts only at the AppKit boundary.
public enum ScreenCoordinates {
    /// Converts an AppKit rect (bottom-left origin) to Accessibility
    /// coordinates (top-left origin). `primaryHeight` is the height of the
    /// primary display's full frame, i.e. `NSScreen.screens[0].frame.height`.
    public static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an Accessibility rect (top-left origin) to AppKit
    /// coordinates (bottom-left origin).
    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        // Flipping is its own inverse.
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func axPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func appKitPoint(fromAX point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
