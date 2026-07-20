import XCTest
@testable import ReunioesLogic

final class MeetingTrimLogicTests: XCTestCase {

    // MARK: Selection normalization

    func testSelectionNormalizesReversedDrag() {
        let sel = MeetingTrimLogic.Selection(0.8, 0.2)
        XCTAssertEqual(sel.startFraction, 0.2)
        XCTAssertEqual(sel.endFraction, 0.8)
    }

    func testSelectionClampsOutOfBounds() {
        let sel = MeetingTrimLogic.Selection(-0.5, 1.7)
        XCTAssertEqual(sel.startFraction, 0)
        XCTAssertEqual(sel.endFraction, 1)
    }

    // MARK: Time range mapping

    func testTimeRangeMapsFractionsToSeconds() {
        let sel = MeetingTrimLogic.Selection(0.25, 0.75)
        let range = MeetingTrimLogic.timeRange(sel, duration: 1000)
        XCTAssertEqual(range?.start, 250)
        XCTAssertEqual(range?.end, 750)
    }

    func testTimeRangeRejectsTooShortSelection() {
        // 0.4s on a 100s track is below the 0.5s minimum.
        let sel = MeetingTrimLogic.Selection(0.5, 0.504)
        XCTAssertNil(MeetingTrimLogic.timeRange(sel, duration: 100))
    }

    func testTimeRangeRejectsZeroDuration() {
        let sel = MeetingTrimLogic.Selection(0, 1)
        XCTAssertNil(MeetingTrimLogic.timeRange(sel, duration: 0))
    }

    // MARK: Trimmed id

    func testTrimmedIdUsesFirstFreeSuffix() {
        XCTAssertEqual(MeetingTrimLogic.trimmedId(original: "20260716_110056", existing: []),
                       "20260716_110056_r1")
        XCTAssertEqual(MeetingTrimLogic.trimmedId(original: "20260716_110056",
                                                  existing: ["20260716_110056_r1", "20260716_110056_r2"]),
                       "20260716_110056_r3")
    }

    func testTrimmedIdIgnoresOtherMeetings() {
        XCTAssertEqual(MeetingTrimLogic.trimmedId(original: "20260716_110056",
                                                  existing: ["20260715_190258_r1"]),
                       "20260716_110056_r1")
    }

    // MARK: Labels and title

    func testLabelBelowOneHour() {
        XCTAssertEqual(MeetingTrimLogic.label(0), "00:00")
        XCTAssertEqual(MeetingTrimLogic.label(754), "12:34")
        XCTAssertEqual(MeetingTrimLogic.label(3599), "59:59")
    }

    func testLabelFromOneHourUp() {
        XCTAssertEqual(MeetingTrimLogic.label(3600), "1:00:00")
        XCTAssertEqual(MeetingTrimLogic.label(3754), "1:02:34")
        XCTAssertEqual(MeetingTrimLogic.label(6209), "1:43:29")
    }

    func testLabelClampsNegative() {
        XCTAssertEqual(MeetingTrimLogic.label(-5), "00:00")
    }

    func testTrimmedTitle() {
        XCTAssertEqual(MeetingTrimLogic.trimmedTitle(base: "Reunião cliente", start: 754, end: 900),
                       "Reunião cliente (recorte 12:34-15:00)")
    }
}
