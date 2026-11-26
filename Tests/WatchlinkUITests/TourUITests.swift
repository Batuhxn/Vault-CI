import XCTest

/// Walks the app in demo mode and photographs every screen and state, so the
/// UI can be reviewed without a phone in hand. Screenshots are kept as
/// attachments in the result bundle; CI exports them as an artifact.
///
/// The tour never fails on cosmetic things: missing elements are recorded and
/// the walk goes on, so one run shows as much as possible.
final class TourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
    }

    func testTourDefaultText() { tour(extraArguments: [], prefix: "std") }

    func testTourLargeText() {
        tour(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], prefix: "xl")
    }

    private func tour(extraArguments: [String], prefix: String) {
        app = XCUIApplication()
        app.launchArguments = ["-WLDemo", "-AppleLanguages", "(tr)", "-AppleLocale", "tr_TR"] + extraArguments
        app.launch()
        step = 0

        // Home
        _ = app.staticTexts["Bu hafta"].waitForExistence(timeout: 15)
        sleep(1)
        shot(prefix, "home")
        app.swipeUp()
        shot(prefix, "home-scrolled")
        app.swipeDown()

        // The whole week
        if tapIfExists(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Tüm hafta")).firstMatch) {
            sleep(1)
            shot(prefix, "agenda-week")
            _ = tapIfExists(app.buttons["Bitti"])
            sleep(1)
        }

        // Agenda settings sheet
        if tapIfExists(app.buttons["Takvim paylaşımı"]) {
            sleep(1)
            shot(prefix, "agenda-sheet")
            _ = tapIfExists(app.buttons["Bitti"])
            sleep(1)
        }

        // Chat
        _ = tapIfExists(app.tabBars.buttons["Sohbet"])
        sleep(2)
        shot(prefix, "chat")

        // Long-press menu on her message
        let nervous = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "gerginim")).firstMatch
        if nervous.waitForExistence(timeout: 5) {
            nervous.press(forDuration: 1.0)
            sleep(1)
            shot(prefix, "menu")
            if !tapIfExists(app.buttons["Yanıtla"]) { app.tap() }
            sleep(1)
            shot(prefix, "reply-bar")
        }

        // Type and send
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("Kahve molası verdim, sen nasılsın?")
            shot(prefix, "composing")
            _ = tapIfExists(app.buttons["Gönder"])
            sleep(2)
            shot(prefix, "sent")
        }

        // Voice: hold the mic for a moment, then release (sends)
        let mic = app.buttons["Sesli mesaj kaydet"].exists ? app.buttons["Sesli mesaj kaydet"] : app.otherElements["Sesli mesaj kaydet"]
        if mic.waitForExistence(timeout: 3) {
            app.swipeDown() // keyboard away
            mic.press(forDuration: 2.5)
            sleep(2)
            shot(prefix, "voice-sent")
        }

        // Older messages, photo viewer
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        shot(prefix, "chat-top")
        let photo = app.descendants(matching: .any)["Fotoğraf"].firstMatch
        if photo.exists && photo.isHittable {
            photo.tap()
            sleep(1)
            shot(prefix, "photo-viewer")
            _ = tapIfExists(app.buttons["Kapat"])
            sleep(1)
        }

        // Us (first close a message menu a stray long press may have opened)
        if app.buttons["Kopyala"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            sleep(1)
        }
        _ = tapIfExists(app.tabBars.buttons["Biz"])
        sleep(2)
        shot(prefix, "us")
        let openedMailDigest = tapIfExists(app.buttons["Mail Özeti"], timeout: 5)
        XCTAssertTrue(openedMailDigest)
        if openedMailDigest {
            let preview = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Cuma 14.00")).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            shot(prefix, "mail-digest")
            XCTAssertTrue(tapIfExists(app.buttons["Bitti"]))
        }
        // Timetable: imported from the SIS PDF fixture by the real reader.
        let openedTimetable = tapIfExists(app.buttons["Ders Programı"], timeout: 10)
        XCTAssertTrue(openedTimetable)
        if openedTimetable {
            XCTAssertTrue(app.staticTexts["PHYS 103L"].firstMatch.waitForExistence(timeout: 5), "fixture PDF not parsed")
            shot(prefix, "timetable")
            app.swipeUp()
            shot(prefix, "timetable-week")
            app.swipeDown()
            app.swipeDown()
            let course = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "EE 303")).firstMatch
            if tapIfExists(course, timeout: 5) {
                sleep(1)
                shot(prefix, "course")
                app.swipeUp()
                shot(prefix, "course-history")
                _ = tapIfExists(app.navigationBars.buttons.element(boundBy: 0))
                sleep(1)
            }
            XCTAssertTrue(tapIfExists(app.buttons["Bitti"]))
        }
        app.swipeUp()
        shot(prefix, "us-2")
        app.swipeUp()
        shot(prefix, "us-3")

        // Back home after activity
        _ = tapIfExists(app.tabBars.buttons["Ana Sayfa"])
        sleep(1)
        shot(prefix, "home-after")
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func shot(_ prefix: String, _ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%@-%02d-%@", prefix, step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
