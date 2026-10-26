import XCTest

/// End to end on a simulator: allow Health, seed a week, add a destination,
/// test it, sync, and read the log. Point it at a running receiver
/// (`node tools/receiver.mjs --token test-token`) with
/// TEST_RUNNER_RECEIVER_URL; TEST_RUNNER_SCREENSHOTS saves each step's
/// screenshot as a PNG in that directory.
@MainActor
final class HealthRelayUITests: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reset"]
        app.launch()
    }

    func testAddDestinationTestAndSync() throws {
        let receiver = env["RECEIVER_URL"] ?? "http://127.0.0.1:8787/"
        let token = env["RECEIVER_TOKEN"] ?? "test-token"

        // Health access from the Status tab.
        let authorize = app.buttons["authorize"]
        if authorize.waitForExistence(timeout: 30) {
            snap("01-status-new")
            authorize.tap()
            allowHealth()
            sleep(2)
            snap("debug-after-read-access")
        }

        // A week of synthetic data.
        tab("Seed")
        let seed = app.buttons["seed"]
        XCTAssertTrue(seed.waitForExistence(timeout: 10))
        seed.tap()
        allowHealth()
        let seeded = app.staticTexts["seed-status"]
        XCTAssertTrue(seeded.waitForExistence(timeout: 60))
        XCTAssertTrue(seeded.label.hasPrefix("Wrote"), seeded.label)

        // The rest without the Debug-only Seed tab, for clean screenshots.
        app.terminate()
        app.launchArguments = ["-hideSeed"]
        app.launch()

        // A destination.
        tab("Destinations")
        snap("02-destinations-empty")
        app.buttons["add-destination"].tap()
        type("destination-name", "Home server")
        type("destination-url", receiver)
        let tokenField = app.secureTextFields["destination-token"]
        tokenField.tap()
        tokenField.typeText(token)
        snap("03-destination-new")
        app.buttons["save-destination"].tap()
        // In case iOS still offers to save the token as a password.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }

        XCTAssertTrue(app.buttons["save-destination"].waitForNonExistence(timeout: 5))
        let row = app.staticTexts["Home server"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let test = app.buttons["test-destination"]
        // The row can take a tap while the sheet is still settling; tap again.
        for _ in 0..<3 where !test.exists {
            row.tap()
            _ = test.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(test.exists)
        test.tap()
        let result = app.staticTexts["test-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("200"), result.label)
        snap("04-destination-tested")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Sync: the first run sends 30 days, one per batch, a second apart.
        tab("Status")
        app.buttons["sync-now"].tap()
        let progress = app.descendants(matching: .any)["sync-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        // Into the deliveries, past the quick check for changes.
        let delivering = NSPredicate(format: "label CONTAINS 'Sending' OR label CONTAINS 'Reading'")
        expectation(for: delivering, evaluatedWith: progress)
        waitForExpectations(timeout: 60)
        snap("05-status-syncing")
        let message = app.staticTexts["sync-message"]
        let done = NSPredicate(format: "label == 'Up to date'")
        expectation(for: done, evaluatedWith: message)
        waitForExpectations(timeout: 180)
        snap("05-status-synced")

        app.staticTexts["Home server"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Deliveries"].waitForExistence(timeout: 5))
        snap("06-delivery-log")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.swipeUp()
        app.buttons["Data by type"].tap()
        XCTAssertTrue(app.staticTexts["Data in the last 30 days"].waitForExistence(timeout: 10))
        sleep(2)
        snap("07-data-by-type")
    }

    /// Accepts the Health permission sheet, which runs in another process.
    /// iOS 27: "Select All N Topics", Continue at the end of the list, then a
    /// page asking how much history to share, then Allow. Earlier systems:
    /// "Turn On All", then Allow.
    /// A setup link fills the editor; the same URL again updates, not adds.
    func testSetupLink() throws {
        let link = "healthrelay://destination?name=Cubby&url=http%3A%2F%2F127.0.0.1%3A8787%2F&token="
        open(link + "first")
        XCTAssertTrue(app.textFields["destination-url"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("From a setup link").exists)
        XCTAssertEqual(app.textFields["destination-url"].value as? String, "http://127.0.0.1:8787/")
        XCTAssertEqual(app.textFields["destination-name"].value as? String, "Cubby")
        snap("setup-link")
        app.buttons["save-destination"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }

        open(link + "second")
        XCTAssertTrue(text("updates this destination").waitForExistence(timeout: 10))
        app.buttons["save-destination"].tap()
        XCTAssertTrue(app.buttons["save-destination"].waitForNonExistence(timeout: 5))

        tab("Destinations")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Cubby").count, 1)

        open("healthrelay://destination?name=x")
        XCTAssertTrue(app.alerts["Not a setup link"].waitForExistence(timeout: 5))
    }

    /// A static text containing `part`, ignoring case (section headers may be upper-cased).
    private func text(_ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", part)).firstMatch
    }

    /// Opens a link the way the Camera does, through iOS's "Open in" prompt.
    /// (`app.open` would relaunch the app with `-reset`.)
    private func open(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
    }

    private func allowHealth() {
        let icon = app.images["healthauthorization_icon_large"]
        guard icon.waitForExistence(timeout: 10) else { return }
        snap("health-sheet")
        let selectAll = app.cells["UIA.Health.AuthSheet.AllCategoryButton"]
        if selectAll.exists {
            selectAll.tap()
        } else {
            app.staticTexts["Turn On All"].firstMatch.tap()
        }
        tapWhenReady(["Continue", "Allow"])
        let history = app.staticTexts["Past 30 Days and Future Data"]
        if history.waitForExistence(timeout: 5) {
            history.tap()
            snap("health-history")
            tapWhenReady(["Allow"])
        }
        if !icon.waitForNonExistence(timeout: 10) {
            snap("health-sheet-stuck")
            add(XCTAttachment(string: app.debugDescription))
            XCTFail("The Health sheet did not close")
        }
    }

    /// Scrolls the sheet until an enabled button with one of the labels can
    /// be tapped, and taps it.
    private func tapWhenReady(_ labels: [String]) {
        let button = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        for _ in 0..<40 where !(button.exists && button.isHittable && button.isEnabled) {
            app.swipeUp(velocity: .fast)
        }
        button.tap()
    }

    /// Selects a tab once the tab bar is usable again (a sheet may be closing).
    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<10 where !button.isSelected {
            button.tap()
            sleep(1)
        }
        XCTAssertTrue(button.isSelected, "could not select the \(name) tab")
    }

    private func type(_ id: String, _ text: String) {
        let field = app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func snap(_ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SCREENSHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
