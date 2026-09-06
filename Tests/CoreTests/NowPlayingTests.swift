import XCTest
import MediaPlayer
@testable import YuzicEngineCore

/**
 The dictionary iOS reads off the lock screen.

 Testable because building it is separated from handing it to a system
 singleton — the singleton needs an app, the decisions do not, and the decisions
 are where this goes wrong.
 */
final class NowPlayingTests: XCTestCase {

  private func snapshot(
    isPlaying: Bool = true, durationSec: Double = 240, positionSec: Double = 30,
    rate: Double = 1.0, isLive: Bool = false, artist: String? = "Boards of Canada"
  ) -> NowPlayingInfo.Snapshot {
    .init(
      title: "Roygbiv", artist: artist, album: "Music Has the Right to Children",
      durationSec: durationSec, positionSec: positionSec,
      isPlaying: isPlaying, rate: rate, isLive: isLive)
  }

  func testCarriesTheMetadata() {
    let info = NowPlayingInfo.build(from: snapshot())
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Roygbiv")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Boards of Canada")
    XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Music Has the Right to Children")
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 30)
  }

  func testRateIsZeroWhenPaused() {
    let paused = NowPlayingInfo.build(from: snapshot(isPlaying: false))
    // Left at 1.0 while paused, iOS keeps advancing the displayed time over
    // audio that is not playing — the clock runs away from the music.
    XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)

    let playing = NowPlayingInfo.build(from: snapshot(isPlaying: true))
    XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
  }

  func testPlaybackSpeedIsReportedAsTheRate() {
    // Someone listening to a podcast at 1.5× should see the lock-screen timer
    // run at 1.5×, which is what iOS extrapolates from this.
    let info = NowPlayingInfo.build(from: snapshot(rate: 1.5))
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
  }

  func testALiveStreamHasNoDurationAndSaysSo() {
    let info = NowPlayingInfo.build(from: snapshot(durationSec: 0, isLive: true))
    // A duration on a stream with no end draws a scrubber that lies, and lets
    // the user drag it somewhere that does not exist.
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
  }

  func testAnUnknownDurationIsOmittedRatherThanSentAsZero() {
    let info = NowPlayingInfo.build(from: snapshot(durationSec: 0))
    // Zero would draw a scrubber pinned at the end for the whole track.
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
  }

  func testEmptyMetadataIsOmittedRatherThanSentBlank() {
    let info = NowPlayingInfo.build(from: snapshot(artist: ""))
    // An empty string renders as a blank line under the title; absent renders
    // as nothing, which is what "we do not know" should look like.
    XCTAssertNil(info[MPMediaItemPropertyArtist])
  }

  func testPositionIsCarriedExactlyForSeeking() {
    let info = NowPlayingInfo.build(from: snapshot(positionSec: 123.456))
    // iOS extrapolates from this fix point using the rate, so it has to be the
    // real position at the moment of the update rather than a rounded one.
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 123.456)
  }
}
