import XCTest
@testable import YuzicEngineCore

/**
 The bookkeeping under the cache. Pure, so it is cheap to be thorough — and
 worth being thorough about, because a wrong answer here is a click in the audio
 once in a while, which is close to impossible to track down after the fact.
 */
final class ByteRangeSetTests: XCTestCase {

  func testMergesTouchingRanges() {
    var set = ByteRangeSet()
    set.insert(0..<10)
    set.insert(10..<20)
    // Adjacent is one range, not two. Keeping them apart would grow the set
    // without bound over a sequential download.
    XCTAssertEqual(set.ranges, [0..<20])
  }

  func testMergesOverlappingRanges() {
    var set = ByteRangeSet()
    set.insert(0..<100)
    set.insert(50..<150)
    XCTAssertEqual(set.ranges, [0..<150])
  }

  func testKeepsDisjointRangesApart() {
    var set = ByteRangeSet()
    set.insert(0..<10)
    set.insert(100..<110)
    XCTAssertEqual(set.ranges, [0..<10, 100..<110])
  }

  func testFillingAGapCoalescesBothSides() {
    var set = ByteRangeSet()
    set.insert(0..<10)
    set.insert(20..<30)
    set.insert(10..<20)
    XCTAssertEqual(set.ranges, [0..<30])
  }

  func testInsertionOrderDoesNotMatter() {
    var forwards = ByteRangeSet()
    for start in stride(from: Int64(0), to: 100, by: 10) { forwards.insert(start..<(start + 10)) }

    var backwards = ByteRangeSet()
    for start in stride(from: Int64(90), through: 0, by: -10) { backwards.insert(start..<(start + 10)) }

    XCTAssertEqual(forwards.ranges, backwards.ranges)
    XCTAssertEqual(forwards.ranges, [0..<100])
  }

  func testContainsNeedsEveryByte() {
    let set = ByteRangeSet([0..<10, 20..<30])
    XCTAssertTrue(set.contains(0..<10))
    XCTAssertTrue(set.contains(2..<8))
    XCTAssertFalse(set.contains(5..<25))   // spans the hole
    XCTAssertFalse(set.contains(0..<11))
    XCTAssertTrue(set.contains(5..<5))     // empty asks for nothing
  }

  func testContiguousBytesStopsAtTheHole() {
    let set = ByteRangeSet([0..<100, 200..<300])
    XCTAssertEqual(set.contiguousBytes(from: 0), 100)
    XCTAssertEqual(set.contiguousBytes(from: 40), 60)
    XCTAssertEqual(set.contiguousBytes(from: 100), 0)   // in the hole
    XCTAssertEqual(set.contiguousBytes(from: 250), 50)
  }

  func testFirstGapFindsWhatIsMissing() {
    let set = ByteRangeSet([0..<100, 200..<300])
    XCTAssertEqual(set.firstGap(from: 0, limit: 100), nil)
    XCTAssertEqual(set.firstGap(from: 0, limit: 150), 100..<150)
    XCTAssertEqual(set.firstGap(from: 120, limit: 260), 120..<200)
    XCTAssertEqual(set.firstGap(from: 200, limit: 300), nil)
    XCTAssertEqual(set.firstGap(from: 250, limit: 400), 300..<400)
  }

  func testEmptyInsertsAreIgnored() {
    var set = ByteRangeSet()
    set.insert(10..<10)
    XCTAssertTrue(set.isEmpty)
  }

  func testTotalBytesCountsOnlyWhatIsPresent() {
    XCTAssertEqual(ByteRangeSet([0..<100, 200..<300]).totalBytes, 200)
  }
}
