import XCTest
@testable import YuzicEngineCore

/// A fetcher over an in-memory blob that counts what was asked for. Stands in
/// for the network so these tests are deterministic and fast.
final class FakeFetcher: ByteFetcher, @unchecked Sendable {
  let blob: Data
  private(set) var fetched: [Range<Int64>] = []
  /// Set to fail the next fetch, to exercise the error path.
  var failNext = false

  init(bytes: Int) {
    var data = Data(count: bytes)
    for index in 0..<bytes { data[index] = UInt8(index % 251) }
    blob = data
  }

  func contentLength() throws -> Int64 { Int64(blob.count) }

  func fetch(_ range: Range<Int64>) throws -> Data {
    if failNext {
      failNext = false
      throw ByteSourceError.fetchFailed("injected")
    }
    fetched.append(range)
    let end = min(Int(range.upperBound), blob.count)
    guard Int(range.lowerBound) < end else { return Data() }
    return blob.subdata(in: Int(range.lowerBound)..<end)
  }

  var bytesFetched: Int64 { fetched.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}

final class CachedByteSourceTests: XCTestCase {

  private func makeSource(bytes: Int = 1_000_000, window: Int64 = 64 * 1024)
    -> (CachedByteSource, FakeFetcher) {
    let fetcher = FakeFetcher(bytes: bytes)
    return (CachedByteSource(fetcher: fetcher, windowBytes: window), fetcher)
  }

  func testReadsReturnTheRightBytes() throws {
    let (source, fetcher) = makeSource()
    let data = try source.read(offset: 1000, count: 256)
    XCTAssertEqual(data, fetcher.blob.subdata(in: 1000..<1256))
  }

  func testSizeIsReportedInFullBeforeAnythingIsFetched() throws {
    let (source, _) = makeSource(bytes: 1_000_000)
    // The lie the whole design rests on: the parser is told the file is whole
    // so that a seek to the end is an ordinary read.
    XCTAssertEqual(try source.totalBytes(), 1_000_000)
    XCTAssertEqual(source.availableBytes(from: 0), 0)
  }

  func testSmallReadsShareOneWindowedFetch() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    // A parser asks for a few bytes at a time; a request per read would be
    // thousands of round trips per track.
    for offset in stride(from: Int64(0), to: 8192, by: 512) {
      _ = try source.read(offset: offset, count: 512)
    }
    XCTAssertEqual(fetcher.fetched.count, 1)
    XCTAssertEqual(fetcher.fetched.first, 0..<65536)
  }

  func testFetchesAreWindowAligned() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 70_000, count: 16)
    // Rounded down to the window boundary rather than starting at the read.
    XCTAssertEqual(fetcher.fetched.first?.lowerBound, 65536)
  }

  func testSeekingForwardDoesNotFetchTheSkippedRegion() throws {
    let (source, fetcher) = makeSource(bytes: 1_000_000, window: 64 * 1024)
    _ = try source.read(offset: 0, count: 128)
    _ = try source.read(offset: 900_000, count: 128)

    // The point of random access: jumping to the end costs one window, not the
    // 900KB in between. This is precisely what Apple's FLAC decoder does *not*
    // do, which is why FLAC needs libFLAC rather than Core Audio.
    XCTAssertEqual(fetcher.bytesFetched, 128 * 1024)
    XCTAssertFalse(fetcher.fetched.contains { $0.lowerBound > 100_000 && $0.upperBound < 800_000 })
  }

  func testAlreadyPresentBytesAreNotRefetched() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 0, count: 1024)
    let afterFirst = fetcher.fetched.count
    _ = try source.read(offset: 0, count: 1024)
    _ = try source.read(offset: 2048, count: 1024)
    XCTAssertEqual(fetcher.fetched.count, afterFirst)
  }

  func testReadPastTheEndReturnsEmptyRatherThanFailing() throws {
    let (source, _) = makeSource(bytes: 4096)
    XCTAssertTrue(try source.read(offset: 4096, count: 128).isEmpty)
    // A read that straddles the end is truncated, which Core Audio treats as
    // end-of-file rather than an error.
    XCTAssertEqual(try source.read(offset: 4000, count: 500).count, 96)
  }

  func testTailPrefetchGrabsTheEndFirst() throws {
    let (source, fetcher) = makeSource(bytes: 1_000_000, window: 64 * 1024)
    try source.prefetchTail(bytes: 128 * 1024)

    // Without this an ALAC or AAC file will not open at all until the whole
    // thing has landed: moov sits at the tail of a non-faststart file, and the
    // spike watched the open fail with two of its first ten reads past the
    // fetched region.
    XCTAssertGreaterThan(source.availableBytes(from: 1_000_000 - 128 * 1024), 0)
    XCTAssertTrue(fetcher.fetched.allSatisfy { $0.lowerBound >= 800_000 })
  }

  func testCancellingUnblocksAReadInsteadOfHanging() throws {
    let (source, _) = makeSource()
    source.cancel()
    XCTAssertThrowsError(try source.read(offset: 0, count: 128)) { error in
      XCTAssertEqual(error as? ByteSourceError, .cancelled)
    }
    // And a cancelled source can be put back to work, since a seek cancels the
    // in-flight read and then immediately wants a new one.
    source.resume()
    XCTAssertEqual(try source.read(offset: 0, count: 128).count, 128)
  }

  func testAFailedFetchSurfacesRatherThanSpinning() throws {
    let (source, fetcher) = makeSource()
    fetcher.failNext = true
    XCTAssertThrowsError(try source.read(offset: 0, count: 128))
  }

  func testAvailableBytesTracksWhatLanded() throws {
    let (source, _) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 0, count: 16)
    XCTAssertEqual(source.availableBytes(from: 0), 65536)
    XCTAssertEqual(source.availableBytes(from: 65536), 0)
  }
}
