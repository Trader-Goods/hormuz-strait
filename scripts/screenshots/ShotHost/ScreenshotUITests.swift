import XCTest

final class ScreenshotUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.tradergoods.livetostill")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-copyDebug"]
    }

    func testCapture() throws {
        app.launch()
        dismissSystemAlerts()
        allowPhotos(in: app)
        waitUntil(90, "live photo scan") {
            self.app.staticTexts["6 Live Photos"].exists && !self.app.staticTexts["Scanning your photo library…"].exists
        }
        Thread.sleep(forTimeInterval: 2)
        capture("01-home")

        app.buttons["Empty Recently Deleted"].firstMatch.tap()
        waitUntil(10, "recently deleted sheet") {
            self.app.navigationBars["Empty Recently Deleted"].exists || self.app.staticTexts["Open Photos, then tap Albums."].exists
        }
        if app.sheets.firstMatch.exists {
            app.sheets.firstMatch.swipeUp()
        }
        Thread.sleep(forTimeInterval: 0.6)
        capture("05-empty-recently-deleted")
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        }

        app.tabBars.buttons["Copies"].tap()
        if app.navigationBars["How copies are matched"].waitForExistence(timeout: 4) || app.staticTexts["How copies are matched"].waitForExistence(timeout: 2) {
            app.buttons["Done"].firstMatch.tap()
        }
        let scan = app.buttons["Scan videos"]
        XCTAssertTrue(scan.waitForExistence(timeout: 8), "scan button missing")
        scan.tap()
        waitUntil(120, "copy match") {
            self.app.staticTexts["Original"].exists && self.app.staticTexts["Edited"].exists && self.app.buttons["DELETE"].exists
        }
        Thread.sleep(forTimeInterval: 2)
        capture("03-delete-copies-keep-edited")

        app.buttons["Keep Original"].firstMatch.tap()
        waitUntil(10, "keep original detail") {
            self.app.staticTexts["Keeps the plain video straight from your camera and deletes the edited copy."].exists
        }
        Thread.sleep(forTimeInterval: 0.8)
        capture("04-delete-copies-keep-original")

        app.tabBars.buttons["Live Photos"].tap()
        let selectAll = app.buttons["Select All"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 8))
        selectAll.tap()
        app.buttons["Convert"].firstMatch.tap()
        confirmConvert()
        waitForConversionResult()
        Thread.sleep(forTimeInterval: 0.8)
        capture("02-convert-results")
    }

    private func confirmConvert() {
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Stills are saved'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "convert confirmation missing")
        let buttons = app.buttons.matching(NSPredicate(format: "label == 'Convert'"))
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            button.tap()
            if disappeared(message, timeout: 3) { return }
        }
        dumpUI("convert confirmation stayed open")
        XCTFail("could not confirm convert")
    }

    private func waitForConversionResult() {
        let end = Date().addingTimeInterval(180)
        while Date() < end {
            dismissSystemAlerts()
            if app.staticTexts["In Recently Deleted"].exists { return }
            if app.staticTexts["Nothing saved"].exists || app.staticTexts["Originals kept"].exists {
                dumpUI("conversion finished without deleting")
                XCTFail("conversion did not delete the Live Photos")
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            Thread.sleep(forTimeInterval: 0.7)
        }
        dumpUI("timed out waiting for conversion result")
        XCTFail("conversion result did not appear")
    }

    private func allowPhotos(in application: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow Full Access", "Allow Access to All Photos"]
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            if application.staticTexts["Seeded"].exists { return }
            for source in [application, springboard] {
                for label in labels {
                    let button = source.alerts.buttons[label]
                    if button.exists {
                        print("TAP PHOTO \(label)")
                        button.tap()
                        return
                    }
                    let plain = source.buttons[label]
                    if plain.exists && plain.isHittable {
                        print("TAP PHOTO BUTTON \(label)")
                        plain.tap()
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alerts in [app.alerts, springboard.alerts] {
            let alert = alerts.firstMatch
            guard alert.exists else { continue }
            print("ALERT \(alert.label)")
            for label in ["Delete", "Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    print("TAP \(label)")
                    button.tap()
                    return
                }
            }
            dumpUI("unhandled alert")
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ message: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            dismissSystemAlerts()
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
        dumpUI(message)
        XCTFail(message)
    }

    private func disappeared(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }

    private func capture(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let file = "\(name).png"
        let folders = [
            FileManager.default.temporaryDirectory,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        ]
        for folder in folders {
            let url = folder.appendingPathComponent(file)
            do {
                try data.write(to: url)
                print("CAPTURE \(url.path) \(data.count) bytes")
            } catch {
                print("CAPTURE failed \(url.path) \(error)")
            }
        }
    }

    private func dumpUI(_ message: String, application: XCUIApplication? = nil) {
        let target = application ?? app
        print("DUMP \(message)")
        for element in target.staticTexts.allElementsBoundByIndex where element.exists {
            print("TEXT \(element.label)")
        }
        for element in target.buttons.allElementsBoundByIndex where element.exists {
            print("BUTTON \(element.label) hittable=\(element.isHittable)")
        }
    }
}
