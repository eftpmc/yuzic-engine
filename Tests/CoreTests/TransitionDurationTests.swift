import XCTest
@testable import YuzicEngineCore

/**
 The same conformance table as `src/transitionDuration.test.ts`, run against the
 Swift implementation.

 Two hand-written copies of a rule agree right up until someone edits one of
 them. Keeping the cases identical on both sides is what makes "the platforms
 behave the same" a claim that can fail loudly rather than a hope.

 When a case is added to one table, add it to the other.
 */
final class TransitionDurationTests: XCTestCase {

  private func song(
    durationSec: Double? = 240,
    followsPrevious: Bool = false,
    continuous: Bool = false
  ) -> Track {
    Track(
      id: "t", uri: "file:///t.flac", title: "T",
      durationSec: durationSec,
      followsPrevious: followsPrevious,
      continuous: continuous
    )
  }

  private func queue(
    _ crossfade: CrossfadeSettings? = CrossfadeSettings(durationSec: 8, mode: .gaplessAware)
  ) -> PlaybackQueue {
    let queue = PlaybackQueue()
    queue.crossfade = crossfade
    return queue
  }

  func testFadesBetweenTwoOrdinaryTracks() {
    XCTAssertEqual(queue().transitionDuration(from: song(), to: song(), userInitiated: false), 8)
  }

  func testCutsWhenCrossfadeIsOffOrZero() {
    XCTAssertEqual(queue(nil).transitionDuration(from: song(), to: song(), userInitiated: false), 0)
    let zero = CrossfadeSettings(durationSec: 0, mode: .gaplessAware)
    XCTAssertEqual(queue(zero).transitionDuration(from: song(), to: song(), userInitiated: false), 0)
  }

  // A stream with no end has no finish line to start a fade before.

  func testCannotFadeOutOfAContinuousStream() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(continuous: true), to: song(), userInitiated: false), 0)
  }

  func testCannotFadeIntoAContinuousStream() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(), to: song(continuous: true), userInitiated: false), 0)
  }

  // A deliberate segue is a cut, not a fade.

  func testHardCutsIntoATrackThatFollowsThePrevious() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(), to: song(followsPrevious: true), userInitiated: false), 0)
  }

  func testAlwaysModeFadesThroughASegueOnPurpose() {
    let always = CrossfadeSettings(durationSec: 8, mode: .always)
    XCTAssertEqual(
      queue(always).transitionDuration(from: song(), to: song(followsPrevious: true), userInitiated: false), 8)
  }

  // A skip is immediate.

  func testCutsWhenTheUserPressedNext() {
    XCTAssertEqual(queue().transitionDuration(from: song(), to: song(), userInitiated: true), 0)
  }

  func testHonoursAnExplicitOptOutOfImmediateSkip() {
    let fades = CrossfadeSettings(durationSec: 8, mode: .gaplessAware, skipIsImmediate: false)
    XCTAssertEqual(queue(fades).transitionDuration(from: song(), to: song(), userInitiated: true), 8)
  }

  // The fade is clamped to half the shorter track.

  func testClampsAgainstAShortOutgoingTrack() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(durationSec: 3), to: song(), userInitiated: false), 1.5)
  }

  func testClampsAgainstAShortIncomingTrack() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(), to: song(durationSec: 10), userInitiated: false), 5)
  }

  func testDoesNotLengthenTheFadeForLongTracks() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(durationSec: 3600), to: song(durationSec: 3600), userInitiated: false), 8)
  }

  // An unknown duration is not a zero duration.

  func testUsesTheFullFadeWhenNeitherLengthIsKnown() {
    let unknown = song(durationSec: nil)
    XCTAssertEqual(queue().transitionDuration(from: unknown, to: unknown, userInitiated: false), 8)
  }

  func testStillClampsAgainstTheLengthItDoesKnow() {
    XCTAssertEqual(
      queue().transitionDuration(from: song(durationSec: nil), to: song(durationSec: 4), userInitiated: false), 2)
  }

  func testCutsWhenThereIsNothingToFadeInto() {
    XCTAssertEqual(queue().transitionDuration(from: song(), to: nil, userInitiated: false), 0)
  }

  // The queue's own accessors, which the table above bypasses.

  func testActiveAndNextFollowTheIndex() {
    let queue = PlaybackQueue()
    queue.set([song(), song(durationSec: 10), song()], startIndex: 1)
    XCTAssertEqual(queue.activeIndex, 1)
    XCTAssertEqual(queue.activeTrack?.durationSec, 10)
    XCTAssertEqual(queue.nextTrack?.durationSec, 240)
  }

  func testStartIndexIsClampedIntoTheQueue() {
    let queue = PlaybackQueue()
    queue.set([song(), song()], startIndex: 99)
    XCTAssertEqual(queue.activeIndex, 1)

    let empty = PlaybackQueue()
    empty.set([], startIndex: 5)
    XCTAssertEqual(empty.activeIndex, 0)
    XCTAssertNil(empty.activeTrack)
  }
}
