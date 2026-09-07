import XCTest
@testable import YuzicEngineCore

/**
 Queue editing, and the one rule it all serves: the active index keeps pointing
 at the same track.

 Worth testing rather than eyeballing because every case is an off-by-one in a
 different direction, and the symptom of getting one wrong is not a crash — it
 is the music jumping to a different song because someone dragged an unrelated
 row. That is the kind of bug that gets reported as "it randomly skips".
 */
final class PlaybackQueueEditingTests: XCTestCase {

  private func makeQueue(_ count: Int, active: Int = 0) -> PlaybackQueue {
    let queue = PlaybackQueue()
    queue.set((0..<count).map { track("t\($0)") }, startIndex: active)
    return queue
  }

  private func track(_ id: String) -> Track {
    Track(id: id, uri: "https://example/\(id)", title: id)
  }

  private func ids(_ queue: PlaybackQueue) -> [String] { queue.tracks.map(\.id) }

  // MARK: insert

  func testInsertingBeforeTheActiveTrackKeepsItPlaying() {
    let queue = makeQueue(4, active: 2)
    queue.insert([track("new")], at: 0)
    XCTAssertEqual(queue.activeIndex, 3)
    XCTAssertEqual(queue.activeTrack?.id, "t2")
  }

  func testInsertingAfterTheActiveTrackLeavesTheIndexAlone() {
    let queue = makeQueue(4, active: 1)
    queue.insert([track("new")], at: 3)
    XCTAssertEqual(queue.activeIndex, 1)
    XCTAssertEqual(queue.activeTrack?.id, "t1")
  }

  func testInsertingAtTheActiveIndexPushesItDown() {
    // "Play this next" inserts *at* the playhead, and the playing track must
    // not be displaced by it.
    let queue = makeQueue(3, active: 1)
    queue.insert([track("new")], at: 1)
    XCTAssertEqual(ids(queue), ["t0", "new", "t1", "t2"])
    XCTAssertEqual(queue.activeTrack?.id, "t1")
  }

  func testAnOutOfRangeInsertAppendsRatherThanThrowing() {
    let queue = makeQueue(2)
    queue.insert([track("new")], at: 99)
    XCTAssertEqual(ids(queue), ["t0", "t1", "new"])
  }

  // MARK: remove

  func testRemovingBeforeTheActiveTrackKeepsItPlaying() {
    let queue = makeQueue(4, active: 2)
    queue.remove(at: 0)
    XCTAssertEqual(queue.activeTrack?.id, "t2")
  }

  func testRemovingAfterTheActiveTrackLeavesTheIndexAlone() {
    let queue = makeQueue(4, active: 1)
    queue.remove(at: 3)
    XCTAssertEqual(queue.activeIndex, 1)
    XCTAssertEqual(queue.activeTrack?.id, "t1")
  }

  func testRemovingThePlayingTrackSlidesTheNextOneIntoPlace() {
    let queue = makeQueue(4, active: 1)
    queue.remove(at: 1)
    XCTAssertEqual(queue.activeIndex, 1)
    XCTAssertEqual(queue.activeTrack?.id, "t2")
  }

  func testRemovingTheLastTrackWhileItPlaysClampsRatherThanDangling() {
    let queue = makeQueue(3, active: 2)
    queue.remove(at: 2)
    XCTAssertEqual(queue.activeIndex, 1)
    XCTAssertNotNil(queue.activeTrack)
  }

  func testEmptyingTheQueueByRemovalLeavesNothingActive() {
    let queue = makeQueue(1)
    queue.remove(at: 0)
    XCTAssertTrue(queue.tracks.isEmpty)
    XCTAssertNil(queue.activeTrack)
  }

  // MARK: move

  func testMovingThePlayingTrackFollowsIt() {
    let queue = makeQueue(4, active: 0)
    queue.move(from: 0, to: 3)
    XCTAssertEqual(queue.activeIndex, 3)
    XCTAssertEqual(queue.activeTrack?.id, "t0")
  }

  func testMovingAnEarlierTrackPastTheActiveOnePullsItBack() {
    let queue = makeQueue(4, active: 2)
    queue.move(from: 0, to: 3)
    XCTAssertEqual(queue.activeTrack?.id, "t2")
  }

  func testMovingALaterTrackBeforeTheActiveOnePushesItAlong() {
    let queue = makeQueue(4, active: 1)
    queue.move(from: 3, to: 0)
    XCTAssertEqual(queue.activeTrack?.id, "t1")
  }

  func testMovingSomethingEntirelyBelowTheActiveTrackLeavesItAlone() {
    let queue = makeQueue(5, active: 0)
    queue.move(from: 3, to: 4)
    XCTAssertEqual(queue.activeIndex, 0)
    XCTAssertEqual(queue.activeTrack?.id, "t0")
  }

  // MARK: repeat

  func testRepeatOffStopsAtTheEnd() {
    let queue = makeQueue(3, active: 2)
    queue.repeatMode = .off
    XCTAssertNil(queue.nextIndex)
  }

  func testRepeatAllWrapsToTheStart() {
    let queue = makeQueue(3, active: 2)
    queue.repeatMode = .all
    XCTAssertEqual(queue.nextIndex, 0)
  }

  func testRepeatOneReturnsTheSameTrackSoACrossfadeStillHasSomethingToFadeInto() {
    let queue = makeQueue(3, active: 1)
    queue.repeatMode = .one
    XCTAssertEqual(queue.nextIndex, 1)
    XCTAssertEqual(queue.nextTrack?.id, "t1")
  }

  func testAnEmptyQueueHasNoNextUnderAnyRepeatMode() {
    let queue = PlaybackQueue()
    for mode in [RepeatMode.off, .one, .all] {
      queue.repeatMode = mode
      XCTAssertNil(queue.nextIndex, "\(mode)")
    }
  }
}
