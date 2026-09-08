import XCTest
@testable import YuzicEngineCore

/**
 The disk cache.

 A cache is only useful if it is honest, so most of what follows is about the
 ways it could lie: claiming a range it does not hold, serving bytes from a
 hole, keeping a sidecar whose audio has gone, or reporting space it has not
 actually freed. A cache that merely *usually* works produces bugs that look
 like corrupt audio, which is the hardest kind to trace back to here.
 */
final class DiskCacheTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-cache-tests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeCache(maxBytes: Int64 = 1_000_000) throws -> DiskCache {
    try DiskCache(directory: directory, maxBytes: maxBytes)
  }

  private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 251) })
  }

  // MARK: - Holding what it says it holds

  func testReadsBackWhatWasWritten() throws {
    let cache = try makeCache()
    let payload = bytes(512)
    cache.write("t1", offset: 0, data: payload, totalBytes: 2048)
    XCTAssertEqual(cache.read("t1", range: 0..<512), payload)
  }

  func testServesASubrangeOfWhatItHolds() throws {
    let cache = try makeCache()
    let payload = bytes(512)
    cache.write("t1", offset: 0, data: payload, totalBytes: 2048)
    XCTAssertEqual(cache.read("t1", range: 100..<200), payload.subdata(in: 100..<200))
  }

  func testRefusesARangeItOnlyPartlyHolds() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(512), totalBytes: 2048)
    // The second half was never fetched. Serving zeroes here is the failure
    // that sounds like a corrupt file rather than a cache miss.
    XCTAssertNil(cache.read("t1", range: 0..<1024))
  }

  func testRefusesAcrossAHole() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(256), totalBytes: 2048)
    cache.write("t1", offset: 1024, data: bytes(256, seed: 9), totalBytes: 2048)
    XCTAssertNil(cache.read("t1", range: 0..<1280))
    // But either side on its own is fine.
    XCTAssertNotNil(cache.read("t1", range: 0..<256))
    XCTAssertNotNil(cache.read("t1", range: 1024..<1280))
  }

  func testWritingEitherSideOfAHoleClosesIt() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(256), totalBytes: 2048)
    cache.write("t1", offset: 512, data: bytes(256), totalBytes: 2048)
    XCTAssertNil(cache.read("t1", range: 0..<768))
    cache.write("t1", offset: 256, data: bytes(256), totalBytes: 2048)
    XCTAssertNotNil(cache.read("t1", range: 0..<768))
  }

  /**
   A write that fails is not recorded as a write that happened.

   The file is truncated to its full size the moment the entry is created, so
   the bytes a failed write did not deliver are not missing — they are zeros,
   and they are exactly as long as the real ones. The index used to record the
   range as present regardless, and `read` only rejects a *short* read, never a
   zeroed one. The parser was then handed silence, and because the sidecar is
   persisted the entry survived a restart: a track broken forever, looking like
   a corrupt library rather than a disk that had filled up.

   Forced with `RLIMIT_FSIZE`, which is what a full disk looks like from inside
   a process — the open succeeds and the write returns EFBIG. `SIGXFSZ` is
   ignored first, or exceeding the limit kills the test runner instead of
   returning an error.
   */
  func testAFailedWriteIsNotRecordedAsPresent() throws {
    let cache = try makeCache()

    // A successful write first, so the entry and its file exist.
    cache.write("track", offset: 0, data: bytes(64), totalBytes: 40_000)
    XCTAssertNotNil(cache.read("track", range: 0..<64), "setup failed: the good write did not land")

    let previous = signal(SIGXFSZ, SIG_IGN)
    var limits = rlimit()
    getrlimit(RLIMIT_FSIZE, &limits)
    let originalLimit = limits.rlim_cur
    defer {
      limits.rlim_cur = originalLimit
      setrlimit(RLIMIT_FSIZE, &limits)
      signal(SIGXFSZ, previous)
    }

    // Anything written past 4KB now fails at the write, not at the open.
    limits.rlim_cur = 4096
    guard setrlimit(RLIMIT_FSIZE, &limits) == 0 else {
      throw XCTSkip("could not lower RLIMIT_FSIZE on this machine")
    }

    cache.write("track", offset: 20_000, data: bytes(64, seed: 9), totalBytes: 40_000)

    XCTAssertNil(cache.read("track", range: 20_000..<20_064),
                 "the cache recorded a range it never managed to write — a later read "
                 + "would be served zeros as though they were audio")
  }

  func testAMissIsNilRatherThanEmpty() throws {
    let cache = try makeCache()
    XCTAssertNil(cache.read("never-seen", range: 0..<10))
    XCTAssertNil(cache.ranges(for: "never-seen"))
  }

  // MARK: - Surviving a relaunch

  func testRangesSurviveReopening() throws {
    let first = try makeCache()
    first.write("t1", offset: 128, data: bytes(256), totalBytes: 4096)

    // A new instance over the same directory is what a relaunch looks like.
    let second = try makeCache()
    let held = second.ranges(for: "t1")
    XCTAssertEqual(held?.total, 4096)
    XCTAssertEqual(held?.present.ranges, [128..<384])
    XCTAssertNotNil(second.read("t1", range: 128..<384))
  }

  func testASidecarWithoutItsAudioIsDiscarded() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(128), totalBytes: 128)
    // Half-deleted pairs happen: a purge interrupted, a crash mid-write. The
    // index must not report bytes that cannot be read.
    let audio = directory.appendingPathComponent("t1.audio")
    try FileManager.default.removeItem(at: audio)

    let reopened = try makeCache()
    XCTAssertNil(reopened.ranges(for: "t1"))
    XCTAssertEqual(reopened.stats().entryCount, 0)
  }

  // MARK: - Eviction

  func testEvictingOneTrackLeavesTheOthers() throws {
    let cache = try makeCache()
    cache.write("keep", offset: 0, data: bytes(128), totalBytes: 128)
    cache.write("drop", offset: 0, data: bytes(128), totalBytes: 128)

    cache.evict("drop")
    XCTAssertNil(cache.read("drop", range: 0..<128))
    XCTAssertNotNil(cache.read("keep", range: 0..<128))
    XCTAssertEqual(cache.stats().entryCount, 1)
  }

  func testClearRemovesEverythingIncludingTheFiles() throws {
    let cache = try makeCache()
    cache.write("a", offset: 0, data: bytes(128), totalBytes: 128)
    cache.write("b", offset: 0, data: bytes(128), totalBytes: 128)

    cache.clear()
    XCTAssertEqual(cache.stats().entryCount, 0)
    XCTAssertEqual(cache.stats().usedBytes, 0)
    // Reporting freed space while leaving the bytes on disk is the specific
    // dishonesty worth a test: the user asked for their storage back.
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(left.isEmpty, "left behind: \(left)")
  }

  func testExceedingTheBudgetEvictsTheLeastRecentlyUsed() throws {
    let cache = try makeCache(maxBytes: 300)
    cache.write("old", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)
    cache.write("new", offset: 0, data: bytes(200), totalBytes: 200)

    // 400 bytes against a 300 budget: the older one goes.
    XCTAssertNil(cache.read("old", range: 0..<200))
    XCTAssertNotNil(cache.read("new", range: 0..<200))
  }

  /**
   Reading refreshes recency, so it is *used* rather than *written* that
   decides. Needs three entries to show it: with two, the one being read is
   still older than the one being written, and both policies would evict the
   same thing.

   Without this, a track on repeat would be evicted while it played.
   */
  func testReadingSomethingKeepsItAliveAheadOfSomethingOlder() throws {
    let cache = try makeCache(maxBytes: 500)
    cache.write("a", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)
    cache.write("b", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)

    // `a` is the oldest by write time, and now the newest by use.
    _ = cache.read("a", range: 0..<200)
    Thread.sleep(forTimeInterval: 0.01)

    // 600 bytes against 500: exactly one has to go, and it should be `b`.
    cache.write("c", offset: 0, data: bytes(200), totalBytes: 200)

    XCTAssertNotNil(cache.read("a", range: 0..<200), "reading it should have saved it")
    XCTAssertNil(cache.read("b", range: 0..<200), "b was the least recently used")
    XCTAssertNotNil(cache.read("c", range: 0..<200))
  }

  func testLoweringTheBudgetEvictsImmediately() throws {
    let cache = try makeCache(maxBytes: 1_000_000)
    cache.write("a", offset: 0, data: bytes(400), totalBytes: 400)
    XCTAssertEqual(cache.stats().usedBytes, 400)

    cache.configure(maxBytes: 100)
    XCTAssertEqual(cache.stats().usedBytes, 0)
    XCTAssertEqual(cache.stats().maxBytes, 100)
  }

  // MARK: - Stats

  func testStatsCountOnlyBytesActuallyHeld() throws {
    let cache = try makeCache()
    // A ten-megabyte track with one kilobyte fetched is one kilobyte of cache,
    // not ten megabytes — the file is sparse and the holes cost nothing.
    cache.write("t1", offset: 0, data: bytes(1024), totalBytes: 10_000_000)
    XCTAssertEqual(cache.stats().usedBytes, 1024)
    XCTAssertEqual(cache.stats().entryCount, 1)
  }

  func testIdsThatLookLikePathsDoNotEscapeTheDirectory() throws {
    let cache = try makeCache()
    cache.write("../../etc/passwd", offset: 0, data: bytes(16), totalBytes: 16)
    XCTAssertNotNil(cache.read("../../etc/passwd", range: 0..<16))
    // Whatever it was named, it landed here and nowhere else.
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(left.count, 2)
  }
}
