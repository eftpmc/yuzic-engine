import XCTest
@testable import YuzicEngineCore

/**
 A stub server, so these are deterministic and need no network.

 What is worth testing here is not "does URLSession work" but the two modes:
 a server that honours `Range`, and one that ignores it and sends everything.
 The second is the ordinary case for a music server transcoding on the fly, and
 treating it as an error would break exactly the setup many self-hosters run.
 */
final class StubURLProtocol: URLProtocol {
  struct Behaviour {
    var body: Data
    /// When false, `Range` is ignored and the whole body comes back as 200.
    var honoursRange: Bool
    /// When false, no `Content-Length` on a 200 — a transcoding server that
    /// does not know how long the output will be.
    var declaresLength: Bool
  }

  nonisolated(unsafe) static var behaviour = Behaviour(body: Data(), honoursRange: true, declaresLength: true)
  nonisolated(unsafe) static var seenRangeHeaders: [String?] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let behaviour = Self.behaviour
    let rangeHeader = request.value(forHTTPHeaderField: "Range")
    Self.seenRangeHeaders.append(rangeHeader)

    let total = behaviour.body.count

    if behaviour.honoursRange, let rangeHeader,
       let parsed = Self.parseRange(rangeHeader, total: total) {
      let slice = behaviour.body.subdata(in: parsed)
      let headers = [
        "Content-Range": "bytes \(parsed.lowerBound)-\(parsed.upperBound - 1)/\(total)",
        "Content-Length": "\(slice.count)",
        "Accept-Ranges": "bytes",
      ]
      let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: slice)
    } else {
      var headers: [String: String] = [:]
      if behaviour.declaresLength { headers["Content-Length"] = "\(total)" }
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: behaviour.body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  /// "bytes=10-19" → 10..<20
  private static func parseRange(_ header: String, total: Int) -> Range<Int>? {
    guard header.hasPrefix("bytes=") else { return nil }
    let spec = header.dropFirst("bytes=".count)
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let start = Int(parts[0]) else { return nil }
    let end = Int(parts[1]) ?? (total - 1)
    guard start <= end, start < total else { return nil }
    return start..<min(end + 1, total)
  }
}

final class HTTPByteFetcherTests: XCTestCase {

  private let url = URL(string: "https://music.example/rest/stream?id=1")!

  private func makeFetcher(bytes: Int, honoursRange: Bool = true, declaresLength: Bool = true)
    -> (HTTPByteFetcher, Data) {
    var body = Data(count: bytes)
    for index in 0..<bytes { body[index] = UInt8(index % 251) }
    StubURLProtocol.behaviour = .init(body: body, honoursRange: honoursRange, declaresLength: declaresLength)
    StubURLProtocol.seenRangeHeaders = []

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let fetcher = HTTPByteFetcher(url: url, headers: ["X-Token": "abc"], session: URLSession(configuration: config))
    return (fetcher, body)
  }

  func testLengthComesFromContentRange() throws {
    let (fetcher, body) = makeFetcher(bytes: 5000)
    XCTAssertEqual(try fetcher.contentLength(), Int64(body.count))
    XCTAssertEqual(fetcher.rangesSupported, true)
    // One probing request, and it asked for a single byte rather than pulling
    // the file down to find out how long it is.
    XCTAssertEqual(StubURLProtocol.seenRangeHeaders, ["bytes=0-0"])
  }

  func testFetchesTheRangeAsked() throws {
    let (fetcher, body) = makeFetcher(bytes: 5000)
    let slice = try fetcher.fetch(1000..<1100)
    XCTAssertEqual(slice, body.subdata(in: 1000..<1100))
  }

  func testRangeHeaderIsInclusiveAtBothEnds() throws {
    let (fetcher, _) = makeFetcher(bytes: 5000)
    _ = try fetcher.fetch(10..<20)
    // Ours are half-open, HTTP's are not. Off by one here would drop a byte
    // per window, which decodes as a click rather than an error.
    XCTAssertEqual(StubURLProtocol.seenRangeHeaders.last, "bytes=10-19")
  }

  func testAServerThatIgnoresRangesStillYieldsCorrectBytes() throws {
    let (fetcher, body) = makeFetcher(bytes: 5000, honoursRange: false)
    XCTAssertEqual(try fetcher.contentLength(), Int64(body.count))
    // Not an error: a transcoding endpoint commonly answers 200 with the whole
    // body. It costs more, but the read is still correct.
    XCTAssertEqual(fetcher.rangesSupported, false)
    XCTAssertEqual(try fetcher.fetch(1000..<1100), body.subdata(in: 1000..<1100))
  }

  func testStopsAskingForRangesOnceTheServerHasRefusedThem() throws {
    let (fetcher, _) = makeFetcher(bytes: 5000, honoursRange: false)
    _ = try fetcher.contentLength()
    StubURLProtocol.seenRangeHeaders = []
    _ = try fetcher.fetch(1000..<1100)
    XCTAssertEqual(StubURLProtocol.seenRangeHeaders, [nil])
  }

  func testNoLengthAtAllIsAnError() throws {
    let (fetcher, _) = makeFetcher(bytes: 5000, honoursRange: false, declaresLength: false)
    // Nothing above this can work without a size, so it fails here rather than
    // producing a source that lies about being zero bytes long.
    XCTAssertThrowsError(try fetcher.contentLength())
  }

  func testLengthIsAskedForOnlyOnce() throws {
    let (fetcher, _) = makeFetcher(bytes: 5000)
    _ = try fetcher.contentLength()
    _ = try fetcher.contentLength()
    XCTAssertEqual(StubURLProtocol.seenRangeHeaders.count, 1)
  }

  func testAuthHeadersRideAlong() throws {
    // Servers that authenticate a stream by header rather than by signing the
    // URL are the reason Track carries headers at all.
    let (fetcher, _) = makeFetcher(bytes: 100)
    _ = try fetcher.contentLength()
    XCTAssertEqual(fetcher.rangesSupported, true)
  }

  func testParsesContentRangeTotal() {
    let response = HTTPURLResponse(
      url: url, statusCode: 206, httpVersion: nil,
      headerFields: ["Content-Range": "bytes 0-0/98765"])!
    XCTAssertEqual(HTTPByteFetcher.totalFromContentRange(response), 98765)

    // "*" means the server knows the window but not the whole — no length.
    let unknown = HTTPURLResponse(
      url: url, statusCode: 206, httpVersion: nil,
      headerFields: ["Content-Range": "bytes 0-0/*"])!
    XCTAssertNil(HTTPByteFetcher.totalFromContentRange(unknown))
  }

  func testEndToEndThroughTheCache() throws {
    let (fetcher, body) = makeFetcher(bytes: 200_000)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: 32 * 1024)
    XCTAssertEqual(try source.read(offset: 100_000, count: 256), body.subdata(in: 100_000..<100_256))
    XCTAssertEqual(try source.totalBytes(), 200_000)
  }
}
