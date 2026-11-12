import XCTest
@testable import HearNoteCore

final class WhisperLanguageSelectionPolicyTests: XCTestCase {
    func testExplicitChineseAndEnglishRemainFixedAcrossAllWindows() {
        var chinese = WhisperLanguageSelectionPolicy(locale: "zh-CN")
        var english = WhisperLanguageSelectionPolicy(locale: "en_US")
        XCTAssertEqual(chinese.language(coreStart: 0, audioEnd: 3), "zh")
        chinese.observe(language: "en", coreStart: 0, audioEnd: 3)
        XCTAssertEqual(chinese.language(coreStart: 12, audioEnd: 25), "zh")
        XCTAssertEqual(english.language(coreStart: 0, audioEnd: 3), "en")
        XCTAssertFalse(chinese.restrictToChineseEnglish)
        XCTAssertFalse(english.restrictToChineseEnglish)
    }

    func testOnlyIdenticalMixedSnapshotReusesLanguageAndNewAudioCanSwitch() {
        var mixed = WhisperLanguageSelectionPolicy(locale: "zh-en")
        XCTAssertTrue(mixed.restrictToChineseEnglish)
        XCTAssertNil(mixed.language(coreStart: 0, audioEnd: 3))
        mixed.observe(language: "zh", coreStart: 0, audioEnd: 3)
        mixed.observe(language: "en", coreStart: 0, audioEnd: 3)
        XCTAssertEqual(mixed.language(coreStart: 0, audioEnd: 3), "zh")
        XCTAssertNil(mixed.language(coreStart: 0, audioEnd: 6))
        mixed.observe(language: "en", coreStart: 0, audioEnd: 6)
        XCTAssertEqual(mixed.language(coreStart: 0, audioEnd: 6), "en")
        XCTAssertNil(mixed.language(coreStart: 12, audioEnd: 15))
    }

    func testLanguageCandidatesAndSourcesStayIndependent() {
        var microphone = WhisperLanguageSelectionPolicy(locale: "zh-en")
        var system = WhisperLanguageSelectionPolicy(locale: "zh-en")
        _ = microphone.language(coreStart: 0, audioEnd: 3)
        _ = system.language(coreStart: 0, audioEnd: 3)
        microphone.observe(language: "hi", coreStart: 0, audioEnd: 3)
        XCTAssertNil(microphone.language(coreStart: 0, audioEnd: 3))
        microphone.observe(language: "zh", coreStart: 0, audioEnd: 3)
        system.observe(language: "en", coreStart: 0, audioEnd: 3)
        XCTAssertEqual(microphone.language(coreStart: 0, audioEnd: 3), "zh")
        XCTAssertEqual(system.language(coreStart: 0, audioEnd: 3), "en")
    }
}
