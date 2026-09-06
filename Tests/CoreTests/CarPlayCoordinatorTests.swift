import XCTest
@testable import YuzicEngineCore

/**
 What a tap in the car actually does.

 This is the whole reason the coordinator holds no CarPlay types: the decision
 worth getting right — that choosing a track inside an album queues the album —
 is testable here, and the scene delegate is left with nothing but drawing.
 */
final class CarPlayCoordinatorTests: XCTestCase {

  private func track(_ id: String) -> Track {
    Track(id: id, uri: "https://example.test/\(id)", title: id)
  }

  private func library() -> BrowseNode {
    BrowseNode(id: "root", title: "Library", children: [
      BrowseNode(id: "album:1", title: "First", children: [
        BrowseNode(id: "t:1", title: "One", playable: track("t:1")),
        BrowseNode(id: "t:2", title: "Two", playable: track("t:2")),
        BrowseNode(id: "t:3", title: "Three", playable: track("t:3")),
      ]),
      BrowseNode(id: "empty", title: "Nothing here"),
    ])
  }

  /// Captures what the engine was asked to play.
  private func coordinator() -> (CarPlayCoordinator, () -> ([Track], Int)?) {
    let coordinator = CarPlayCoordinator.shared
    var captured: ([Track], Int)?
    coordinator.setRoot(library())
    coordinator.setPlayHandler { tracks, index in captured = (tracks, index) }
    return (coordinator, { captured })
  }

  override func tearDown() {
    // Order matters, and finding that out was the point. The coordinator is a
    // singleton — CarPlay constructs its scene delegate itself, so there is
    // nowhere to inject one — which means state survives between tests.
    // Clearing the root first fires the *previous* test's change handler
    // during teardown, and an expectation fulfilled twice is a crash, not a
    // failure. Detach the handler before touching anything it observes.
    CarPlayCoordinator.shared.setRootChangeHandler(nil)
    CarPlayCoordinator.shared.setPlayHandler(nil)
    CarPlayCoordinator.shared.setRoot(nil)
    super.tearDown()
  }

  func testChoosingATrackQueuesItsAlbumAndStartsThere() {
    // Playing one track and stopping is the wrong reading of a tap. The album
    // is the context the driver believes they are in, and they cannot pick a
    // follow-up track while driving.
    let (coordinator, captured) = self.coordinator()
    coordinator.select("t:2")
    let (tracks, index) = captured()!
    XCTAssertEqual(tracks.map(\.id), ["t:1", "t:2", "t:3"])
    XCTAssertEqual(index, 1)
  }

  func testChoosingAnAlbumPlaysItFromTheTop() {
    let (coordinator, captured) = self.coordinator()
    coordinator.select("album:1")
    let (tracks, index) = captured()!
    XCTAssertEqual(tracks.map(\.id), ["t:1", "t:2", "t:3"])
    XCTAssertEqual(index, 0)
  }

  func testChoosingAnEmptyNodePlaysNothing() {
    // Rather than clearing the queue and stopping whatever is currently on.
    let (coordinator, captured) = self.coordinator()
    coordinator.select("empty")
    XCTAssertNil(captured())
  }

  func testUnknownIdIsIgnored() {
    let (coordinator, captured) = self.coordinator()
    coordinator.select("nope")
    XCTAssertNil(captured())
  }

  func testSelectingWithNoTreeIsHarmless() {
    let coordinator = CarPlayCoordinator.shared
    coordinator.setRoot(nil)
    var called = false
    coordinator.setPlayHandler { _, _ in called = true }
    coordinator.select("t:1")
    XCTAssertFalse(called)
  }

  func testSettingTheRootNotifiesAConnectedScene() {
    // A library that loads after the car connects has to appear on its own;
    // otherwise the driver backs out and re-enters to refresh it.
    let coordinator = CarPlayCoordinator.shared
    let notified = expectation(description: "root change")
    coordinator.setRootChangeHandler { notified.fulfill() }
    coordinator.setRoot(library())
    wait(for: [notified], timeout: 1.0)
  }
}
