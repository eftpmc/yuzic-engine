import Foundation

/**
 Fetches byte ranges over HTTP.

 Synchronous on purpose. `AudioFile_ReadProc` has no async form, so somewhere a
 thread has to wait; doing it here keeps the waiting in one place, off the
 render thread, behind a producer that stays a few seconds ahead. A stall then
 costs buffer-ahead rather than a dropout.

 The interesting part is not the request, it is what happens when the server
 will not do ranges. A music server transcoding on the fly usually cannot: it
 does not know the length of a file it has not finished producing, so it answers
 200 with the whole body rather than 206 with a window. That is not an error and
 must not be treated as one — it is a different mode, and `rangesSupported`
 says which mode we are in so the cache can stop asking for windows it will
 never get.
 */
public final class HTTPByteFetcher: ByteFetcher, @unchecked Sendable {

  public enum HTTPFetchError: Error {
    case badStatus(Int)
    case noLength
    case transport(String)
  }

  private let url: URL
  private let headers: [String: String]
  private let session: URLSession
  private let timeout: TimeInterval

  /// False once the server has shown it ignores `Range`. Until the first probe
  /// this is nil — unknown, rather than assumed either way.
  public private(set) var rangesSupported: Bool?

  private var cachedLength: Int64?

  public init(
    url: URL,
    headers: [String: String] = [:],
    session: URLSession = .shared,
    timeout: TimeInterval = 30
  ) {
    self.url = url
    self.headers = headers
    self.session = session
    self.timeout = timeout
  }

  /**
   Total size, and the range-support probe in the same round trip.

   A one-byte ranged GET rather than HEAD: plenty of media servers answer HEAD
   differently from GET, or not at all, and the answer that matters is what a
   real ranged read will do. `Content-Range: bytes 0-0/12345` gives the length
   and proves ranges work at once.
   */
  public func contentLength() throws -> Int64 {
    if let cachedLength { return cachedLength }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

    let (_, response) = try perform(request)

    if response.statusCode == 206, let total = Self.totalFromContentRange(response) {
      rangesSupported = true
      cachedLength = total
      return total
    }

    // 200 means the server ignored the Range header and is sending everything.
    rangesSupported = false
    let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    guard let declared, declared > 0 else {
      // A transcoding endpoint often declines to say. Nothing above can work
      // without a length, so the caller has to fall back to downloading the
      // whole thing before playing.
      throw HTTPFetchError.noLength
    }
    cachedLength = declared
    return declared
  }

  public func fetch(_ range: Range<Int64>) throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

    if rangesSupported != false {
      // HTTP ranges are inclusive at both ends; ours are half-open.
      request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }

    let (data, response) = try perform(request)

    switch response.statusCode {
    case 206:
      rangesSupported = true
      return data
    case 200:
      // The server sent the whole file regardless of what we asked for. Slice
      // out the part wanted rather than failing: the read is still correct,
      // it just cost more than it should have.
      rangesSupported = false
      let start = min(Int(range.lowerBound), data.count)
      let end = min(Int(range.upperBound), data.count)
      return start < end ? data.subdata(in: start..<end) : Data()
    default:
      throw HTTPFetchError.badStatus(response.statusCode)
    }
  }

  private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), Error>?

    let task = session.dataTask(with: request) { data, response, error in
      if let error {
        result = .failure(HTTPFetchError.transport(String(describing: error)))
      } else if let http = response as? HTTPURLResponse {
        result = .success((data ?? Data(), http))
      } else {
        result = .failure(HTTPFetchError.transport("no response"))
      }
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    switch result {
    case .success(let pair): return pair
    case .failure(let error): throw error
    case nil: throw HTTPFetchError.transport("no result")
    }
  }

  /// `Content-Range: bytes 0-0/12345` → 12345.
  static func totalFromContentRange(_ response: HTTPURLResponse) -> Int64? {
    guard let header = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
    guard let slash = header.lastIndex(of: "/") else { return nil }
    let tail = header[header.index(after: slash)...]
    // "*" means the server knows the range but not the whole size.
    return Int64(tail.trimmingCharacters(in: .whitespaces))
  }
}
