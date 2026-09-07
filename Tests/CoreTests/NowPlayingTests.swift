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

  // MARK: - Artwork

  /**
   The lock screen showing the wrong album.

   `update` deliberately keeps the outgoing track's cover while a new one
   loads, so the screen does not flicker to grey between tracks. That is right
   while something is on its way and wrong the moment nothing is — a track with
   no art would otherwise keep the previous track's cover indefinitely, which
   does not look like a bug. It looks like art that loaded.
   */
  func testATrackWithNoArtworkClearsTheOldCover() {
    XCTAssertEqual(artworkAction(for: nil, currentlyLoaded: "https://a/1.jpg"), .clear)
  }

  /// An empty string is a missing cover, not a URL to fetch.
  func testAnEmptyUriIsTreatedAsNoArtwork() {
    XCTAssertEqual(artworkAction(for: "", currentlyLoaded: "https://a/1.jpg"), .clear)
  }

  func testANewCoverIsLoaded() {
    XCTAssertEqual(
      artworkAction(for: "https://a/2.jpg", currentlyLoaded: "https://a/1.jpg"),
      .load("https://a/2.jpg")
    )
  }

  /**
   The same cover twice is left alone.

   Two tracks off one album share an artwork URL, and refetching would replace
   the image with an identical one — a visible flicker on the lock screen at
   every track change within an album, which is the common case.
   */
  func testTheSameCoverIsKeptRatherThanRefetched() {
    XCTAssertEqual(
      artworkAction(for: "https://a/1.jpg", currentlyLoaded: "https://a/1.jpg"),
      .keep
    )
  }

  func testTheFirstCoverIsLoadedWhenNothingIsShowing() {
    XCTAssertEqual(artworkAction(for: "https://a/1.jpg", currentlyLoaded: nil), .load("https://a/1.jpg"))
  }

  /// Nothing showing and nothing to show is not a clear-and-redraw.
  func testNoArtworkAndNothingLoadedStillClears() {
    XCTAssertEqual(artworkAction(for: nil, currentlyLoaded: nil), .clear)
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
