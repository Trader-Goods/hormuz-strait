import CoreGraphics
import Foundation

/// One cleaning pass. Pure black, with the backlight kept low.
///
/// A sebum film reflects a few percent more light than clean glass. That
/// difference is obvious on a screen that emits almost nothing, and it
/// disappears on a bright page. Dust on the same black glass reads as a
/// bright speck when room light rakes across it.
enum CleaningClock {
    static let duration: TimeInterval = 60
    static let holdToExit: TimeInterval = 1.5
    /// Low, not off, so an LCD backlight does not lift the black into gray,
    /// and not full, which would wash the oils out.
    static let panelBrightness: CGFloat = 0.12

    static func remaining(at date: Date, end: Date) -> Int {
        let seconds = end.timeIntervalSince(date)
        if seconds <= 0 {
            return 0
        }
        return Int(ceil(seconds))
    }

    static func label(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}
