import XCTest

class LaunchUITests: XCTestCase {

    private let app: XCUIApplication = XCUIApplication()

    override func setUp() {
        super.setUp()
        
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        
        waitForExistenseOfMainScreen()
        checkSlowAndFrozenFrames()
    }
    
    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testBreadcrumbData() {
        let breadcrumbLabel = app.staticTexts["breadcrumbLabel"]
        XCTAssertTrue(breadcrumbLabel.waitForExistence(), "Breadcrumb label not found.")
        XCTAssertEqual(breadcrumbLabel.label, "{ category: ui.lifecycle, parentViewController: UINavigationController, beingPresented: false, window_isKeyWindow: true, is_window_rootViewController: false }")
      }

    func testLoremIpsum() {
        app.buttons["loremIpsumButton"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(), "Lorem Ipsum not loaded.")
    }
    
    func testNavigationTransaction() {
        app.buttons["testNavigationTransactionButton"].tap()
        XCTAssertTrue(app.images.firstMatch.waitForExistence(), "Navigation transaction not loaded.")
        assertApp()
    }
    
    func testShowNib() {
        app.buttons["showNibButton"].tap()
        XCTAssertTrue(app.buttons["lonelyButton"].waitForExistence(), "Nib ViewController not loaded.")
        assertApp()
    }
    
    func testUiClickTransaction() {
        app.buttons["uiClickTransactionButton"].tap()
    }
    
    func testCaptureError() {
        app.buttons["Error"].tap()
    }
    
    func testCaptureException() {
        app.buttons["NSException"].tap()
    }
    
    func testShowTableView() {
        app.buttons["showTableViewButton"].tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(), "TableView not loaded.")
        assertApp()
    }
    
    func testSplitView() {
        app.buttons["showSplitViewButton"].tap()
        
        let app = XCUIApplication()
        XCTAssertTrue(app.navigationBars["iOS_Swift.SecondarySplitView"].buttons["Root ViewController"].waitForExistence(), "SplitView not loaded.")
        
        // This validation is currently not working on iOS 10.
        if #available(iOS 11.0, *) {
            assertApp()
        }
    }
        
    private func waitForExistenseOfMainScreen() {
        XCTAssertTrue(app.buttons["captureMessageButton"].waitForExistence(), "Home Screen doesn't exist.")
    }
    
    private func checkSlowAndFrozenFrames() {
        let frameStatsLabel = app.staticTexts["framesStatsLabel"]
        XCTAssertTrue(frameStatsLabel.waitForExistence(), "Frame statistics message not found.")
        
        let frameStatsAsStringArray = frameStatsLabel.label.components(separatedBy: CharacterSet.decimalDigits.inverted)
        let frameStats = frameStatsAsStringArray.filter { $0 != "" }.map { Int($0) }
        
        XCTAssertEqual(3, frameStats.count)
        guard let totalFrames = frameStats[0] else { XCTFail("No total frames found."); return }
        guard let slowFrames = frameStats[1] else { XCTFail("No slow frames found."); return }
        guard let frozenFrames = frameStats[1] else { XCTFail("No frozen frames found."); return }

        let slowFramesPercentage = Double(slowFrames) / Double(totalFrames)
        XCTAssertTrue(0.5 > slowFramesPercentage, "Too many slow frames.")
        
        let frozenFramesPercentage = Double(frozenFrames) / Double(totalFrames)
        XCTAssertTrue(0.5 > frozenFramesPercentage, "Too many frozen frames.")
    }
    
    private func assertApp() {
        let confirmation = app.staticTexts["ASSERT_MESSAGE"]
        let errorMessage = app.staticTexts["ASSERT_ERROR"]
        XCTAssertTrue(confirmation.waitForExistence(), "Assertion Message Not Found")
        
        XCTAssertTrue(confirmation.label == "ASSERT: SUCCESS", errorMessage.label)
    }
    
}

extension XCUIElement {

    @discardableResult
    func waitForExistence() -> Bool {
        self.waitForExistence(timeout: TimeInterval(10))
    }
}
