import XCTest
@testable import YuzicEngineCore

/**
 How loud a track plays.

 Arithmetic, and testable precisely because it is kept out of the graph. The
 cases that matter are the ones where the obvious implementation sounds worse
 than doing nothing at all.
 */
final class ReplayGainTests: XCTestCase {

  private func track(db: Double? = nil, peak: Double? = nil) -> Track {
    Track(
      id: "t", uri: "https://example.test/t", title: "T",
      replayGainDb: db, replayGainPeak: peak
    )
  }

  func testOffLeavesEverythingAlone() {
    let gain = ReplayGain.linearGain(for: track(db: -6), settings: .off)
    XCTAssertEqual(gain, 1.0)
  }

  func testMinusSixDbHalvesAmplitude() {
    let gain = ReplayGain.linearGain(for: track(db: -6.02), settings: .init(mode: .track))
    XCTAssertEqual(gain, 0.5, accuracy: 0.005)
  }

  func testPreampIsAddedToTheTagFigure() {
    let gain = ReplayGain.linearGain(
      for: track(db: -6.02), settings: .init(mode: .track, preampDb: 6.02)
    )
    XCTAssertEqual(gain, 1.0, accuracy: 0.01)
  }

  func testAHotMasterIsNotPushedIntoClipping() {
    // The failure this prevents: a quiet master gets a positive figure, the
    // gain pushes samples past full scale, and loudness normalisation makes
    // the track sound *worse* than leaving it alone.
    let gain = ReplayGain.linearGain(
      for: track(db: 6, peak: 0.99), settings: .init(mode: .track)
    )
    XCTAssertEqual(Double(gain), 1.0 / 0.99, accuracy: 0.001)
  }

  func testHeadroomIsNotUsedToInventLoudness() {
    // A peak of 0.5 leaves 6 dB spare, but the tags did not ask for it.
    let gain = ReplayGain.linearGain(
      for: track(db: -6.02, peak: 0.5), settings: .init(mode: .track)
    )
    XCTAssertEqual(gain, 0.5, accuracy: 0.005)
  }

  func testClippingGuardCanBeTurnedOff() {
    let gain = ReplayGain.linearGain(
      for: track(db: 6, peak: 0.99),
      settings: .init(mode: .track, preventClipping: false)
    )
    XCTAssertEqual(Double(gain), pow(10.0, 6.0 / 20.0), accuracy: 0.001)
  }

  func testAnUntaggedTrackGetsItsOwnSetting() {
    // Not the same as a tag of zero: "leave this alone" and "this needs no
    // adjustment" are different statements about a file, and a library that is
    // half-adjusted sounds more uneven than one that is not adjusted at all.
    let gain = ReplayGain.linearGain(
      for: track(), settings: .init(mode: .track, preampDb: 12, untaggedPreampDb: -6.02)
    )
    XCTAssertEqual(gain, 0.5, accuracy: 0.005)
  }

  func testAnUntaggedTrackDefaultsToUnchanged() {
    let gain = ReplayGain.linearGain(for: track(), settings: .init(mode: .track))
    XCTAssertEqual(gain, 1.0, accuracy: 0.001)
  }

  func testAnAbsurdTagCannotSilenceATrack() {
    // Broken taggers write figures like -60 dB, and one inaudible track in a
    // library gets reported as a bug in the player rather than in the file.
    let gain = ReplayGain.linearGain(for: track(db: -60), settings: .init(mode: .track))
    XCTAssertEqual(gain, 0.05, accuracy: 0.001)
  }

  func testAZeroPeakIsIgnoredRatherThanDividedBy() {
    let gain = ReplayGain.linearGain(
      for: track(db: 0, peak: 0), settings: .init(mode: .track)
    )
    XCTAssertEqual(gain, 1.0, accuracy: 0.001)
  }
}
