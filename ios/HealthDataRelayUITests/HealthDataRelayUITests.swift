import CryptoKit
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
        app.launchArguments = ["-reset"]
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
        app.launchArguments = ["-hideSeed"]
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
        app.launchArguments = ["-reset"]
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

    /// With no OAuth client in the build, a cloud service says so rather than failing.
    func testCloudAccountsNeedSettingUp() throws {
        tab("Settings")
        app.buttons["connected-accounts"].tap()
        XCTAssertTrue(text("Not set up in this build").waitForExistence(timeout: 5))
        snap("connected-accounts")
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
        XCTAssertTrue(text("Average").waitForExistence(timeout: 30))
        snap("charts")
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
        app.launchArguments = ["-hideSeed"]
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

    private func allowHealth() {
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
