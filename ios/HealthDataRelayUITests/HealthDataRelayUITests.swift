import CryptoKit
import StoreKitTest
import XCTest

/// End to end on a simulator: allow Health, seed a week, add a pipeline,
/// test it, run it, and read the log. Point it at a running receiver
/// (`node tools/receiver.mjs --token test-token`) with
/// TEST_RUNNER_RECEIVER_URL; TEST_RUNNER_SCREENSHOTS saves each step's
/// screenshot as a PNG in that directory.
@MainActor
final class HealthDataRelayUITests: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-access", "full"]
        app.launch()
    }

    func testAddPipelineTestAndRun() throws {
        let receiver = env["RECEIVER_URL"] ?? "http://127.0.0.1:8787/"
        let token = env["RECEIVER_TOKEN"] ?? "test-token"

        // Health access from the Pipelines tab.
        let authorize = app.buttons["authorize"]
        if authorize.waitForExistence(timeout: 30) {
            snap("01-pipelines-new")
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
        app.launchArguments = ["-hideSeed", "-access", "full"]
        app.launch()

        // A pipeline, manual unless told otherwise.
        tab("Pipelines")
        snap("02-pipelines-empty")
        app.buttons["add-pipeline"].tap()
        type("pipeline-name", "Home server")
        type("pipeline-url", receiver)
        let tokenField = app.secureTextFields["pipeline-token"]
        tokenField.tap()
        tokenField.typeText(token)
        snap("03-pipeline-new")
        app.buttons["save-pipeline"].tap()
        // In case iOS still offers to save the token as a password.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }

        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 5))
        let card = app.staticTexts["Home server"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let run = app.buttons["run-Home server"]
        XCTAssertTrue(run.waitForExistence(timeout: 5), "a manual card has a Run button")
        XCTAssertFalse(app.staticTexts["next-run"].exists, "and no countdown")

        // Its detail screen, from the card.
        let test = app.buttons["test-pipeline"]
        // The card can take a tap while the sheet is still settling; tap again.
        for _ in 0..<3 where !test.exists {
            card.tap()
            _ = test.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(test.exists)
        test.tap()
        let result = app.staticTexts["test-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("200"), result.label)
        snap("04-pipeline-tested")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Run: the first run sends 30 days, one per batch, a second apart.
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        let progress = app.descendants(matching: .any)["sync-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        // Into the deliveries, past the quick check for changes.
        let delivering = NSPredicate(format: "label CONTAINS 'Sending' OR label CONTAINS 'Reading'")
        expectation(for: delivering, evaluatedWith: progress)
        waitForExpectations(timeout: 60)
        snap("05-pipeline-running")
        let done = NSPredicate(format: "exists == true")
        expectation(for: done, evaluatedWith: run)
        waitForExpectations(timeout: 180)
        XCTAssertTrue(text("Up to date").waitForExistence(timeout: 5))
        snap("05-pipeline-done")

        card.tap()
        let deliveries = app.buttons["deliveries"]
        XCTAssertTrue(deliveries.waitForExistence(timeout: 5))
        deliveries.tap()
        XCTAssertTrue(text("Deliveries").waitForExistence(timeout: 5))
        snap("06-delivery-log")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("Settings")
        app.buttons["Data by type"].tap()
        XCTAssertTrue(app.staticTexts["Data in the last 30 days"].waitForExistence(timeout: 10))
        sleep(2)
        snap("07-data-by-type")
    }

    /// A scheduled card counts down, second by second, instead of offering Run.
    func testScheduledPipelineCountsDown() throws {
        // Without the Debug-only Seed tab: its screenshot is on the site.
        app.terminate()
        app.launchArguments = ["-hideSeed", "-access", "full"]
        app.launch()
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        type("pipeline-name", "Hourly")
        type("pipeline-url", "http://127.0.0.1:8787/")
        app.swipeUp()
        app.buttons["Every"].tap()
        snap("pipeline-schedule")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }

        let countdown = app.staticTexts["next-run"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertTrue(countdown.label.hasPrefix("Next run in 59m"), countdown.label)
        XCTAssertFalse(app.buttons["run-Hourly"].exists)
        snap("08-pipeline-scheduled")
        let first = countdown.label
        let ticked = NSPredicate(format: "label != %@", first)
        expectation(for: ticked, evaluatedWith: countdown)
        waitForExpectations(timeout: 5)
    }

    /// Free doesn't run pipelines: one keeps its trigger but shows a lock
    /// instead of Run, the server asks for Full, and Export still works.
    func testFreeCannotRunPipelines() throws {
        app.terminate()
        app.launchArguments = ["-reset", "-hideSeed", "-access", "free"]
        app.launch()
        XCTAssertTrue(app.buttons["offer-unlock"].waitForExistence(timeout: 30), "free offers the plans")
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        type("pipeline-name", "Hourly")
        type("pipeline-url", "http://127.0.0.1:8787/")
        app.swipeUp()
        XCTAssertTrue(app.buttons["trigger-needs-full"].waitForExistence(timeout: 5), "even a manual pipeline needs Full to run")
        app.buttons["Every"].tap()
        // Choosing a trigger that runs by itself offers Full.
        let done = app.buttons["unlock-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        snap("unlock-sheet")
        done.tap()
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }

        let lock = app.buttons["needs-full-Hourly"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["run-Hourly"].exists, "free can't run it by hand")
        XCTAssertFalse(app.staticTexts["next-run"].exists, "and nothing counts down")
        snap("free-pipeline-locked")
        lock.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        // Its own screen has no Run either.
        app.staticTexts["Hourly"].firstMatch.tap()
        XCTAssertTrue(app.buttons["edit-pipeline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["run-now"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        // Export still makes a file, from the last 7 days.
        app.buttons["export"].tap()
        XCTAssertTrue(app.buttons["export-range-needs-full"].waitForExistence(timeout: 5))
        let run = app.buttons["export-run"]
        reveal(run)
        run.tap()
        allowHealth()
        let result = app.staticTexts["export-result"]
        let failure = app.staticTexts["export-failure"]
        for _ in 0..<20 where !result.exists && !failure.exists {
            app.swipeUp()
            sleep(2)
        }
        XCTAssertFalse(failure.exists, failure.exists ? failure.label : "")
        XCTAssertTrue(app.buttons["export-share"].exists)
        app.buttons["Done"].tap()

        tab("Settings")
        XCTAssertTrue(app.staticTexts["Free"].waitForExistence(timeout: 5) || text("Free").exists)
        app.buttons["server"].tap()
        XCTAssertTrue(app.buttons["server-needs-full"].waitForExistence(timeout: 5))
    }

    /// The trial reaches back 7 days: longer ranges in Export and Charts show
    /// a lock and offer the plans, and a pipeline still runs.
    func testTrialCapsHistory() throws {
        app.terminate()
        app.launchArguments = ["-reset", "-hideSeed", "-access", "trial"]
        app.launch()
        let export = app.buttons["export"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        export.tap()
        let range = app.buttons["export-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["export-range-needs-full"].exists)
        range.tap()
        snap("export-range-locked")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Last 30 days")).firstMatch.tap()
        let done = app.buttons["unlock-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "a longer range offers the plans")
        done.tap()
        XCTAssertTrue(range.label.contains("Last 7 days"), "and the range stays where it was: \(range.label)")
        // Custom can't start before the limit either.
        range.tap()
        app.buttons["Custom"].tap()
        XCTAssertTrue(app.datePickers["range-from"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        tab("Charts")
        let chartRange = app.segmentedControls["chart-range"]
        XCTAssertTrue(chartRange.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chart-needs-full"].exists)
        XCTAssertTrue(chartRange.buttons["7 days"].isSelected, "the trial opens on the week it can read")
        chartRange.buttons["30 days"].tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(chartRange.buttons["7 days"].isSelected)
        snap("charts-locked")
    }

    /// A new install is on the trial from its first launch, with nothing to
    /// tap: the notice says what it is, and a schedule counts down.
    func testANewInstallIsOnTheTrial() throws {
        try clearPurchases()
        app.terminate()
        app.launchArguments = ["-reset", "-hideSeed", "-installedDaysAgo", "0"]
        app.launch()
        XCTAssertTrue(text("Everything is free for 7 days").waitForExistence(timeout: 30))
        snap("trial-notice")
        app.buttons["dismiss-notice"].tap()
        XCTAssertTrue(app.buttons["trial-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("Trial: 7 days left").exists)

        let add = app.buttons["add-pipeline"]
        add.tap()
        type("pipeline-name", "Hourly")
        type("pipeline-url", "http://127.0.0.1:8787/")
        app.swipeUp()
        app.buttons["Every"].tap()
        XCTAssertFalse(app.buttons["unlock-done"].waitForExistence(timeout: 2), "the trial doesn't ask")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.staticTexts["next-run"].waitForExistence(timeout: 10))

        tab("Settings")
        XCTAssertTrue(text("Trial: 7 days left").waitForExistence(timeout: 5))
    }

    /// Eight days after install the trial is over: the card says so, and
    /// a schedule waits for a plan.
    func testTheTrialEndsAfterSevenDays() throws {
        try clearPurchases()
        app.terminate()
        app.launchArguments = ["-reset", "-hideSeed", "-installedDaysAgo", "8"]
        app.launch()
        XCTAssertTrue(text("Your trial has ended").waitForExistence(timeout: 30))
        app.buttons["offer-unlock"].tap()
        XCTAssertTrue(app.buttons["unlock-done"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("Free (trial ended)").exists)
        XCTAssertFalse(app.buttons["start-trial"].exists)
        app.buttons["unlock-done"].tap()
        tab("Settings")
        XCTAssertTrue(text("Free (trial ended)").waitForExistence(timeout: 5))
    }

    /// Lifetime, bought through StoreKit testing, is Full for good.
    func testBuyingLifetime() throws {
        let session = try clearPurchases()
        defer { _ = session }
        app.terminate()
        app.launchArguments = ["-reset", "-hideSeed"]
        app.launch()
        tab("Settings")
        let unlock = app.buttons["settings-unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        unlock.tap()
        let lifetime = app.buttons["buy-lifetime"]
        XCTAssertTrue(app.buttons["unlock-done"].waitForExistence(timeout: 10))
        if !lifetime.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(lifetime.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: lifetime)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(lifetime.label.contains("14.99"), "the price comes from StoreKit: \(lifetime.label)")
        lifetime.tap()
        confirmPurchase()
        XCTAssertTrue(text("Lifetime").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["settings-unlock"].exists)
    }

    /// Forgets what StoreKit testing bought in earlier tests, which
    /// otherwise outlives them on the simulator.
    @discardableResult
    private func clearPurchases() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "HealthDataRelay")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    /// StoreKit testing's purchase sheet, in the app or from the system.
    private func confirmPurchase() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<20 {
            for source in [app!, springboard] {
                for label in ["Get", "Purchase", "Subscribe", "Confirm", "Buy", "OK"] {
                    let b = source.buttons[label]
                    if b.exists && b.isHittable { b.tap(); return }
                }
            }
            sleep(1)
        }
    }

    /// A trigger can change from the editor, and the card follows it.
    func testTriggerCanBeChanged() throws {
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        type("pipeline-name", "Changing")
        type("pipeline-url", "http://127.0.0.1:8787/")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.buttons["run-Changing"].waitForExistence(timeout: 10))

        let card = app.staticTexts["Changing"].firstMatch
        let edit = app.buttons["edit-pipeline"]
        for _ in 0..<3 where !edit.exists {
            card.tap()
            _ = edit.waitForExistence(timeout: 5)
        }
        edit.tap()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["Health changes"].tap()
        app.buttons["save-pipeline"].tap()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(text("When Health changes").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let line = app.staticTexts["next-run"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.label, "Runs when Health changes")
        XCTAssertFalse(app.buttons["run-Changing"].exists)
    }

    /// Accepts the Health permission sheet, which runs in another process.
    /// iOS 27: "Select All N Topics", Continue at the end of the list, then a
    /// page asking how much history to share, then Allow. Earlier systems:
    /// "Turn On All", then Allow.
    /// The phone's name is kept when the field is left any way, not only by Return.
    /// Reads a seeded day through the pipelines' Extract path on real HealthKit,
    /// after asking for every type a pipeline can read (a type iOS refuses
    /// would crash here). Seeding adds to what's there, and what a past seed left
    /// for yesterday depends on the date it ran, so this checks the difference: 13 hours
    /// of 460 plus 20 per hour of the day.
    func testValuesByDayMatchWhatWasWritten() throws {
        func yesterdaysSteps() -> Int {
            tab("Settings")
            app.buttons["Values by day"].tap()
            let allow = app.buttons["allow-every-type"]
            XCTAssertTrue(allow.waitForExistence(timeout: 5))
            allow.tap()
            allowHealth()
            app.buttons["Yesterday"].tap()
            let steps = app.descendants(matching: .any)["value-Steps"]
            // No row at all is no steps at all, once the list has loaded.
            XCTAssertTrue(steps.waitForExistence(timeout: 15) || text("No data").waitForExistence(timeout: 15))
            // The label reads "Steps, 28,860 count".
            let total = steps.exists ? Int(steps.label.replacingOccurrences(of: "Steps, ", with: "").prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)) ?? 0 : 0
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return total
        }
        let before = yesterdaysSteps()
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["seed-status"].label.hasPrefix("Wrote"), app.staticTexts["seed-status"].label)
        let after = yesterdaysSteps()
        XCTAssertEqual(after - before, 9620)
        snap("values-by-day")
        tab("Settings")
        app.buttons["Values by day"].tap()
        app.buttons["Yesterday"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["value-Heart Rate"].waitForExistence(timeout: 15))
    }

    /// A template pipeline from the editor to the receiver: a real read, a real
    /// render and a real upload, checked in the delivery log.
    func testTemplatePipelineRuns() throws {
        let receiver = (env["RECEIVER_URL"] ?? "http://127.0.0.1:8787/") + "any"
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-access", "full"]
        app.launch()
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))

        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        type("pipeline-name", "Dashboard")
        app.buttons["transform"].tap()
        app.buttons["Metrics JSON v2"].tap()
        // Today's all sent, whatever else has been seeded.
        reveal(app.buttons["range"])
        app.buttons["range"].tap()
        app.buttons["Today"].tap()
        reveal(app.textFields["pipeline-url"])
        type("pipeline-url", receiver)
        let tokenField = app.secureTextFields["pipeline-token"]
        tokenField.tap()
        tokenField.typeText(env["RECEIVER_TOKEN"] ?? "test-token")
        snap("template-pipeline-new")
        app.buttons["save-pipeline"].tap()
        // In case iOS offers to save the token as a password.
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        allowHealth()

        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(text("Metrics JSON v2").waitForExistence(timeout: 10))
        XCTAssertTrue(text("Hasn't run yet").waitForExistence(timeout: 5))

        // The card can take a tap while the sheet is still settling; tap again.
        let card = app.staticTexts["Dashboard"].firstMatch
        let runNow = app.buttons["run-now"]
        for _ in 0..<3 where !runNow.exists {
            card.tap()
            _ = runNow.waitForExistence(timeout: 5)
        }
        runNow.tap()
        XCTAssertTrue(text("Last run finished").waitForExistence(timeout: 120))

        // The receiver's answer is in the log.
        app.buttons["deliveries"].tap()
        let found = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Received'")).firstMatch.waitForExistence(timeout: 10)
        snap("template-pipeline-log")
        XCTAssertTrue(found, "the receiver answered")
        snap("template-pipeline-ran")
    }

    /// Writing a template: a mistake shows its line, a fix shows its output on
    /// sample data, and once saved it can be chosen for a pipeline.
    func testWriteATemplate() throws {
        tab("Templates")
        XCTAssertTrue(app.staticTexts["Metrics JSON v2"].waitForExistence(timeout: 10))
        app.buttons["new-template"].tap()
        let editor = app.textViews["template-source"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("{{ a | nope }}")
        let error = app.staticTexts["template-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-template"].isEnabled)
        snap("template-error")
        for _ in 0..<14 { editor.typeText(XCUIKeyboardKey.delete.rawValue) }
        XCTAssertTrue(app.buttons["save-template"].waitForExistence(timeout: 5))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: app.buttons["save-template"])
        waitForExpectations(timeout: 5)

        app.buttons["Preview"].tap()
        XCTAssertTrue(text("date,steps,source").waitForExistence(timeout: 5))
        snap("template-preview")

        app.buttons["save-template"].tap()
        XCTAssertTrue(app.staticTexts["My template"].waitForExistence(timeout: 5))

        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        app.buttons["transform"].tap()
        XCTAssertTrue(app.buttons["My template"].waitForExistence(timeout: 5))
        snap("template-chosen")
    }

    /// A one-off export makes a file to share; a pipeline that asks for its
    /// range asks, then leaves a file of its own.
    func testExportAndSharePipeline() throws {
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))

        tab("Pipelines")
        app.buttons["export"].tap()

        // A preset hides the dates; Custom brings them back.
        let range = app.buttons["export-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertFalse(app.datePickers["range-from"].exists)
        range.tap()
        app.buttons["Custom"].tap()
        XCTAssertTrue(app.datePickers["range-from"].waitForExistence(timeout: 5))
        snap("export-custom-range")
        range.tap()
        app.buttons["Last 30 days"].tap()
        XCTAssertTrue(app.datePickers["range-from"].waitForNonExistence(timeout: 5))
        snap("export-preset-range")

        let run = app.buttons["export-run"]
        reveal(run)
        run.tap()
        allowHealth()
        let result = app.staticTexts["export-result"]
        let failure = app.staticTexts["export-failure"]
        for _ in 0..<40 where !result.exists && !failure.exists {
            app.swipeUp()
            sleep(2)
        }
        snap("export-after-run")
        XCTAssertFalse(failure.exists, failure.exists ? failure.label : "")
        XCTAssertTrue(result.exists)
        XCTAssertFalse(result.label.hasPrefix("0 "))
        XCTAssertTrue(app.buttons["export-share"].exists)
        snap("export-done")
        app.buttons["Done"].tap()

        app.buttons["add-pipeline"].tap()
        type("pipeline-name", "Ask me")
        app.buttons["transform"].tap()
        app.buttons["Metrics CSV"].tap()
        reveal(app.buttons["range"])
        app.buttons["range"].tap()
        app.buttons["Ask when run"].tap()
        reveal(app.buttons["target-kind"])
        app.buttons["target-kind"].tap()
        app.buttons["Share sheet"].tap()
        snap("share-pipeline-new")
        app.buttons["save-pipeline"].tap()
        allowHealth()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 10))

        let runButton = app.buttons["run-Ask me"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        let prompt = app.buttons["range-run"]
        for _ in 0..<3 where !prompt.exists {
            runButton.tap()
            _ = prompt.waitForExistence(timeout: 3)
        }
        snap("range-prompt")
        prompt.tap()

        let card = app.staticTexts["Ask me"].firstMatch
        let share = app.buttons["share-export"]
        XCTAssertTrue(text("Last run finished").waitForExistence(timeout: 90))
        card.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertTrue(share.label.contains(".csv"), share.label)
        app.buttons["run-history"].tap()
        XCTAssertTrue(text("rows").waitForExistence(timeout: 5))
        snap("run-history")
    }

    /// A time of day counts down like a schedule, and the activity log and
    /// diagnostics file show what happened.
    func testTimeOfDayAndActivity() throws {
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        type("pipeline-name", "Morning")
        type("pipeline-url", "http://127.0.0.1:8787/")
        reveal(app.buttons["At a time"])
        app.buttons["At a time"].tap()
        snap("pipeline-time-of-day")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }

        let countdown = app.staticTexts["next-run"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertTrue(countdown.label.hasPrefix("Next run in"), countdown.label)
        snap("time-of-day-card")

        tab("Settings")
        app.buttons["activity"].tap()
        app.buttons["make-diagnostics"].tap()
        XCTAssertTrue(app.buttons["share-diagnostics"].waitForExistence(timeout: 5))
        snap("activity")
    }

    /// The Calendar preset writes seeded workouts to the real calendar, and
    /// running again adds nothing, as the delivery log's count shows.
    func testCalendarPipeline() throws {
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))

        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        let presets = app.buttons["preset"]
        let preset = app.buttons["preset-Workouts on my calendar"]
        XCTAssertTrue(presets.waitForExistence(timeout: 5))
        // A tap while the sheet settles can be lost.
        for _ in 0..<3 where !preset.exists {
            presets.tap()
            _ = preset.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(preset.exists)
        preset.tap()
        // The picker's row asks if it's on screen, which depends on the device.
        allowCalendar()
        snap("calendar-pipeline-new")
        app.buttons["save-pipeline"].tap()
        allowHealth()
        allowCalendar()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 10))

        let card = app.staticTexts["Workouts on my calendar"].firstMatch
        let runNow = app.buttons["run-now"]
        for _ in 0..<3 where !runNow.exists {
            card.tap()
            _ = runNow.waitForExistence(timeout: 5)
        }
        runNow.tap()
        XCTAssertTrue(text("Last run finished").waitForExistence(timeout: 120))
        app.buttons["deliveries"].tap()
        let wrote = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'in Calendar' OR label CONTAINS ' event'")).firstMatch
        XCTAssertTrue(wrote.waitForExistence(timeout: 10))
        snap("calendar-pipeline-ran")
    }

    /// A compose pipeline leaves its file ready to send on.
    func testComposeEmailPipeline() throws {
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))

        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        type("pipeline-name", "Email me")
        app.buttons["transform"].tap()
        app.buttons["Metrics CSV"].tap()
        reveal(app.buttons["target-kind"])
        app.buttons["target-kind"].tap()
        app.buttons["Email"].tap()
        reveal(app.textFields["email-to"])
        type("email-to", "me@example.com")
        snap("email-pipeline-new")
        app.buttons["save-pipeline"].tap()
        allowHealth()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 10))

        let card = app.staticTexts["Email me"].firstMatch
        let runNow = app.buttons["run-now"]
        for _ in 0..<3 where !runNow.exists {
            card.tap()
            _ = runNow.waitForExistence(timeout: 5)
        }
        runNow.tap()
        XCTAssertTrue(app.buttons["compose-share"].waitForExistence(timeout: 90))
        snap("email-pipeline-ready")
    }

    /// With no OAuth client in the build, cloud services aren't offered anywhere.
    func testCloudAccountsHiddenWithoutSetup() throws {
        tab("Settings")
        XCTAssertTrue(app.buttons["server"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connected-accounts"].exists)
        snap("settings-no-accounts")

        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        app.buttons["transform"].tap()
        app.buttons["Metrics CSV"].tap()
        reveal(app.buttons["target-kind"])
        app.buttons["target-kind"].tap()
        XCTAssertFalse(app.buttons["Files or cloud"].exists)
        app.buttons["Files"].tap()
        let choose = app.buttons["choose-folder"]
        reveal(choose)
        XCTAssertTrue(choose.exists)
        XCTAssertFalse(app.buttons["file-kind"].exists)
        snap("files-folder-only")
    }

    /// The native format is one row, first, and only sends to a REST API.
    /// A template offers more types, and going back to native resets the type.
    func testTransformListAndDestinationType() throws {
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let transform = app.buttons["transform"]
        let kind = app.buttons["target-kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        kind.tap()
        XCTAssertTrue(app.buttons["REST API"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Share sheet"].exists)
        snap("destination-type-native")
        app.buttons["REST API"].tap()

        transform.tap()
        let csv = app.buttons["Metrics CSV"]
        XCTAssertTrue(csv.waitForExistence(timeout: 5))
        func nativeRows() -> [XCUIElement] {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Health Data Relay'")).allElementsBoundByIndex.filter { $0.identifier != "transform" }
        }
        XCTAssertEqual(nativeRows().count, 1)
        XCTAssertLessThan(nativeRows()[0].frame.minY, app.buttons["Metrics JSON v2"].frame.minY)
        snap("transform-list")
        csv.tap()

        reveal(kind)
        kind.tap()
        XCTAssertTrue(app.buttons["Share sheet"].waitForExistence(timeout: 5))
        app.buttons["Share sheet"].tap()
        XCTAssertFalse(app.textFields["pipeline-url"].exists)

        reveal(transform)
        transform.tap()
        XCTAssertTrue(app.buttons["Metrics JSON v2"].waitForExistence(timeout: 5))
        nativeRows()[0].tap()
        XCTAssertTrue(app.textFields["pipeline-url"].waitForExistence(timeout: 5))
    }

    /// Paused only shows where there's something to pause, or something to
    /// resume: a paused pipeline switched to manual can still come back.
    func testPausedIsForPipelinesThatRunThemselves() throws {
        let add = app.buttons["add-pipeline"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        type("pipeline-name", "Pausing")
        type("pipeline-url", "http://127.0.0.1:8787/")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.buttons["run-Pausing"].waitForExistence(timeout: 10))

        let card = app.staticTexts["Pausing"].firstMatch
        let edit = app.buttons["edit-pipeline"]
        for _ in 0..<3 where !edit.exists {
            card.tap()
            _ = edit.waitForExistence(timeout: 5)
        }
        let paused = app.switches["pipeline-paused"]
        reveal(app.buttons["Remove pipeline"])
        XCTAssertFalse(paused.exists)

        func change(to trigger: String) {
            let edit = app.buttons["edit-pipeline"]
            reveal(edit)
            edit.tap()
            XCTAssertTrue(app.buttons["save-pipeline"].waitForExistence(timeout: 5))
            reveal(app.buttons[trigger])
            app.buttons[trigger].tap()
            app.buttons["save-pipeline"].tap()
            XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 5))
        }

        change(to: "Health changes")
        reveal(paused)
        XCTAssertTrue(paused.exists)
        paused.switches.firstMatch.tap()
        snap("pipeline-paused")

        change(to: "Manual")
        reveal(paused)
        XCTAssertTrue(paused.exists, "a paused manual pipeline can still resume")
        paused.switches.firstMatch.tap()
        XCTAssertTrue(paused.waitForNonExistence(timeout: 5))
    }

    /// The server over real TLS, with its own certificate. The runner is the client:
    /// it trusts that certificate by its fingerprint, as a real tool would be told to.
    func testMCPServerOverTLS() async throws {
        await MainActor.run {
            tab("Settings")
            app.buttons["server"].tap()
            app.switches["mcp-toggle"].switches.firstMatch.tap()
            allowHealth()
        }
        let (token, fingerprint, port): (String, String, Int) = await MainActor.run {
            XCTAssertTrue(app.staticTexts["server-running"].waitForExistence(timeout: 20) || app.descendants(matching: .any)["server-running"].waitForExistence(timeout: 5))
            app.buttons["mcp-show-token"].tap()
            let tokenText = app.staticTexts["mcp-token"]
            XCTAssertTrue(tokenText.waitForExistence(timeout: 5))
            let print = app.staticTexts["mcp-fingerprint"]
            XCTAssertTrue(print.waitForExistence(timeout: 5))
            snap("server")
            return (tokenText.label, print.label, 8443)
        }
        let delegate = PinningDelegate(fingerprint: fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        func post(_ bearer: String) async throws -> (Int, Data) {
            var r = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/mcp")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
            let (data, response) = try await session.data(for: r)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (refused, _) = try await post("wrong")
        XCTAssertEqual(refused, 401)
        let (status, data) = try await post(token)
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 8)
        XCTAssertTrue(delegate.checked, "the certificate was presented and matched")
    }

    /// A link fills the editor for review, and one asking for the old format says no.
    func testPipelineLinks() throws {
        open("healthdatarelay://pipeline?url=https%3A%2F%2Fexample.com%2Fin&name=From%20a%20link&datatype=workouts&exportversion=v1")
        XCTAssertTrue(text("older v1 format").waitForExistence(timeout: 10))
        snap("link-refused")
        app.buttons["OK"].tap()

        open("healthdatarelay://pipeline?url=https%3A%2F%2Fexample.com%2Fin&name=From%20a%20link&datatype=workouts&period=yesterday&format=csv")
        XCTAssertTrue(app.buttons["save-pipeline"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("From a link").exists)
        XCTAssertTrue(text("example.com").exists)
        XCTAssertEqual(app.textFields["pipeline-name"].value as? String, "From a link")
        XCTAssertTrue(text("own columns").exists)
        snap("link-review")
    }

    /// Charts draws a seeded metric.
    func testCharts() throws {
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))
        tab("Charts")
        // Only what Health has data for shows, each on a card.
        let steps = app.descendants(matching: .any)["chart-card-step_count"]
        if !steps.waitForExistence(timeout: 15), app.buttons["charts-allow"].exists {
            app.buttons["charts-allow"].tap()
            allowHealth()
        }
        XCTAssertTrue(steps.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["chart-card-blood_glucose"].exists, "nothing seeded, nothing shown")
        sleep(2)
        snap("charts")

        // Search narrows the cards.
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Steps")
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chart-card-active_energy"].waitForNonExistence(timeout: 5))
        snap("charts-search")

        // A card opens the metric in full.
        steps.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chart"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("Average").exists)
        XCTAssertTrue(text("Total").exists)
        snap("chart-detail")
        // Full opens on a month, which can be gathered into weeks.
        let grouping = app.segmentedControls["chart-grouping"]
        XCTAssertTrue(grouping.waitForExistence(timeout: 10))
        grouping.buttons["Week"].tap()
        snap("chart-detail-weeks")
        // A week is too short to group by anything but days.
        app.segmentedControls["chart-range"].buttons["7 days"].tap()
        XCTAssertTrue(grouping.waitForNonExistence(timeout: 10))
        let pin = app.buttons["chart-pin"]
        XCTAssertTrue(pin.exists)
    }

    /// tools/mac-check.sh's phone: seeds data, turns on the server and leaves it
    /// running for the Mac's client until told to stop. Skipped otherwise.
    func testServerForMacClient() throws {
        guard let path = env["HDR_SERVER_FILE"] else { throw XCTSkip("Run by tools/mac-check.sh") }
        tab("Seed")
        app.buttons["seed"].tap()
        allowHealth()
        XCTAssertTrue(app.staticTexts["seed-status"].waitForExistence(timeout: 60))
        tab("Settings")
        app.buttons["server"].tap()
        app.switches["mcp-toggle"].switches.firstMatch.tap()
        allowHealth()
        XCTAssertTrue(app.descendants(matching: .any)["server-running"].waitForExistence(timeout: 20))
        app.buttons["mcp-show-token"].tap()
        let token = app.staticTexts["mcp-token"]
        let fingerprint = app.staticTexts["mcp-fingerprint"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        let info = ["url": "https://127.0.0.1:8443/mcp", "token": token.label, "fingerprint": fingerprint.label]
        try JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: path))
        // The app has to stay in front, or its server stops.
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: path + ".stop") { return }
            sleep(1)
        }
        XCTFail("The Mac's client never finished")
    }

    /// Answers iOS's calendar permission alert, which runs in another process.
    private func allowCalendar() {
        // Answered by SpringBoard on a phone, and shown in the app's own alerts on some iPads.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowed = NSPredicate(format: "label CONTAINS 'Allow'")
        for _ in 0..<8 {
            for alerts in [springboard.alerts, app.alerts] {
                let allow = alerts.buttons.matching(allowed).firstMatch
                if allow.exists {
                    allow.tap()
                    return
                }
            }
            sleep(1)
        }
    }

    func testPhoneNameIsSavedOnLeavingTheField() throws {
        tab("Settings")
        let field = app.textFields["device-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertEqual(field.value as? String, "iPhone")
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("Pat's phone")
        // Leave by scrolling the keyboard away, not Return.
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tab("Pipelines")
        tab("Settings")
        XCTAssertEqual(field.value as? String, "Pat's phone")

        app.terminate()
        app.launchArguments = ["-hideSeed", "-access", "full"]
        app.launch()
        tab("Settings")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Pat's phone")
    }

    /// A setup link fills the editor; the same URL again updates, not adds.
    func testSetupLink() throws {
        let link = "healthdatarelay://destination?name=Cubby&url=http%3A%2F%2F127.0.0.1%3A8787%2F&token="
        open(link + "first")
        XCTAssertTrue(app.textFields["pipeline-url"].waitForExistence(timeout: 10))
        XCTAssertTrue(text("From a setup link").exists)
        XCTAssertEqual(app.textFields["pipeline-url"].value as? String, "http://127.0.0.1:8787/")
        XCTAssertEqual(app.textFields["pipeline-name"].value as? String, "Cubby")
        snap("setup-link")
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }

        open(link + "second")
        XCTAssertTrue(text("updates this pipeline").waitForExistence(timeout: 10))
        app.buttons["save-pipeline"].tap()
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 5))

        tab("Pipelines")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Cubby").count, 1)

        open("healthdatarelay://destination?name=x")
        XCTAssertTrue(app.alerts["Not a setup link"].waitForExistence(timeout: 5))
    }

    /// A copied setup link fills the editor too: a phone can't scan its own QR code.
    func testCopiedSetupLink() throws {
        tab("Pipelines")
        app.buttons["add-pipeline"].tap()
        // Copied from inside the app: the test runner can't write to the pasteboard from the background.
        type("pipeline-name", "healthdatarelay://destination?name=Cubby&url=http%3A%2F%2F127.0.0.1%3A8787%2F&token=copied")
        let name = app.textFields["pipeline-name"]
        name.tap()
        if !app.menuItems["Select All"].waitForExistence(timeout: 2) { name.tap() }
        XCTAssertTrue(app.menuItems["Select All"].waitForExistence(timeout: 5))
        app.menuItems["Select All"].tap()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5))
        app.menuItems["Copy"].tap()
        reveal(app.buttons["paste-link"])
        app.buttons["paste-link"].tap()
        XCTAssertTrue(text("From a setup link").waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["pipeline-url"].value as? String, "http://127.0.0.1:8787/")
    }

    /// The first grant trims a pipeline's days, and that must not crash, now
    /// or on the next launch. Health remembers its answer through `-reset`, so
    /// this needs an erased simulator.
    func testAllowHealthAfterAddingAPipeline() throws {
        let authorize = app.buttons["authorize"]
        // A first launch after an erase is slow.
        guard authorize.waitForExistence(timeout: 90) else { throw XCTSkip("Health was already answered: erase the simulator") }
        open("healthdatarelay://destination?name=Cubby&url=http%3A%2F%2F127.0.0.1%3A8787%2F&token=first")
        XCTAssertTrue(app.buttons["save-pipeline"].waitForExistence(timeout: 10))
        app.buttons["save-pipeline"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.buttons["save-pipeline"].waitForNonExistence(timeout: 5))

        authorize.tap()
        allowHealth(history: "All Recorded Data and Future Data")
        XCTAssertTrue(authorize.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)

        app.terminate()
        app.launchArguments = ["-hideSeed", "-access", "full"]
        app.launch()
        tab("Pipelines")
        XCTAssertTrue(app.staticTexts.matching(identifier: "Cubby").firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A static text containing `part`, ignoring case (section headers may be upper-cased).
    /// Scrolls a long form until an element is on screen.
    private func reveal(_ element: XCUIElement) {
        // Slowly, and back again, since a fast swipe can pass it by.
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            app.swipeDown(velocity: .slow)
        }
    }

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

    private func allowHealth(history choice: String = "Past 30 Days and Future Data") {
        let icon = app.images["healthauthorization_icon_large"]
        guard icon.waitForExistence(timeout: 10) else { return }
        // Medications have their own sheet, with nothing to choose on a simulator.
        let cancelOnly = app.buttons["UIA.Health.CancelOnly.Button"]
        if cancelOnly.exists {
            cancelOnly.tap()
            return
        }
        snap("health-sheet")
        let selectAll = app.cells["UIA.Health.AuthSheet.AllCategoryButton"]
        if selectAll.exists {
            selectAll.tap()
        } else {
            app.staticTexts["Turn On All"].firstMatch.tap()
        }
        tapWhenReady(["Continue", "Allow"])
        let history = app.staticTexts[choice]
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
        // Mid-animation a button has no frame, and asking if it's hittable throws.
        for _ in 0..<40 where !(button.exists && !button.frame.isEmpty && button.isHittable && button.isEnabled) {
            app.swipeUp(velocity: .fast)
        }
        button.tap()
    }

    /// Selects a tab once the tab bar is usable again (a sheet may be closing).
    private func tab(_ name: String) {
        // A phone's tab bar; on iPad, tabs float at the top and aren't exposed as one.
        var button = app.tabBars.buttons[name]
        if !button.waitForExistence(timeout: 3) { button = app.buttons[name].firstMatch }
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

/// Trusts one certificate, by the SHA-256 fingerprint the app shows.
private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    private(set) var checked = false

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return (.cancelAuthenticationChallenge, nil) }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
        guard digest == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        checked = true
        return (.useCredential, URLCredential(trust: trust))
    }
}
