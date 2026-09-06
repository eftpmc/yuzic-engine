import Foundation

/// Produces a byte stream from the beginning, once. No ranges, no seeking.
public protocol StreamProducer: AnyObject {
  /// Begin delivering. `onData` is called repeatedly off the caller's thread;
  /// `onFinish` once, with an error if the stream broke.
  func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void)
  func stop()
}

/**
 A byte source over a stream that arrives in order and cannot be seeked.

 This is the transcoded path. The server answers `accept-ranges: none` with no
 length, because it is encoding as it sends — measured against a real Navidrome,
 not assumed; see `spikes/ios-reader`.

 What still works, and it is most of what matters:

 - Playing from the start, which is what almost every listen is.
 - Seeking **backwards**, or anywhere already received, because every byte that
   arrives is kept. Random access over the part of the file that exists.
 - Reading slightly ahead of the write head, by waiting for it.

 What cannot work is a seek far past what has arrived. There is no range to
 request; the only way to reach that point is to ask the server for a new
 stream starting there, with Subsonic's `timeOffset`. That is a *reconnection*,
 not a read — the byte offsets of the new stream have nothing to do with the old
 one — so it is handled a layer up by replacing the source and reopening the
 reader, not smuggled in here.

 The user chose this when they chose a bitrate cap, and a slower seek is the
 honest consequence of that choice rather than something to paper over by
 quietly downloading the lossless original instead.
 */
public final class StreamingByteSource: ByteSource {

  private let producer: StreamProducer
  private let estimatedBytes: Int64

  private let lock = NSCondition()
  private var buffer = Data()
  private var finished = false
  private var failure: Error?
  private var cancelled = false
  private var started = false

  /**
   `estimatedBytes` is what `GetSizeProc` reports until the stream ends.

   It has to be *something* — the parser asks before any bytes arrive. The host
   knows the track's duration and the bitrate it asked for, so
   `duration × bitrate` is available and close. Erring high is deliberate:
   reading past the real end returns nothing, which the parser treats as
   end-of-file, whereas under-reporting makes it stop early and truncate the
   track.
   */
  public init(producer: StreamProducer, estimatedBytes: Int64) {
    self.producer = producer
    self.estimatedBytes = max(1, estimatedBytes)
  }

  deinit { producer.stop() }

  public func totalBytes() throws -> Int64 {
    lock.lock(); defer { lock.unlock() }
    // Once the stream has ended the true size is known, and it is better than
    // the estimate — a parser that seeks relative to the end wants the real one.
    return finished ? Int64(buffer.count) : estimatedBytes
  }

  public func availableBytes(from offset: Int64) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    return max(0, Int64(buffer.count) - offset)
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.broadcast()
    lock.unlock()
    producer.stop()
  }

  public func resume() {
    lock.lock(); cancelled = false; lock.unlock()
  }

  public func read(offset: Int64, count: Int) throws -> Data {
    guard offset >= 0 else { throw ByteSourceError.outOfBounds }
    startIfNeeded()

    lock.lock()
    defer { lock.unlock() }

    let wantedEnd = offset + Int64(count)
    // Wait for the write head to pass what was asked for. A reader slightly
    // ahead of the download is the normal case, not an error.
    while Int64(buffer.count) < wantedEnd && !finished && !cancelled && failure == nil {
      lock.wait()
    }

    if cancelled { throw ByteSourceError.cancelled }
    if let failure { throw ByteSourceError.fetchFailed(String(describing: failure)) }

    guard offset < Int64(buffer.count) else { return Data() }
    let end = min(Int(wantedEnd), buffer.count)
    return buffer.subdata(in: Int(offset)..<end)
  }

  private func startIfNeeded() {
    lock.lock()
    guard !started else { lock.unlock(); return }
    started = true
    lock.unlock()

    producer.begin(
      onData: { [weak self] chunk in
        guard let self else { return }
        self.lock.lock()
        self.buffer.append(chunk)
        self.lock.broadcast()
        self.lock.unlock()
      },
      onFinish: { [weak self] error in
        guard let self else { return }
        self.lock.lock()
        self.failure = error
        self.finished = true
        self.lock.broadcast()
        self.lock.unlock()
      }
    )
  }
}

/**
 A `StreamProducer` over an ordinary HTTP GET.

 No `Range` header at all: this is for the endpoint that already said it will
 not honour one, and sending it anyway invites a server to answer 206 for part
 of a stream it is generating, which nobody wants.
 */
public final class HTTPStreamProducer: NSObject, StreamProducer, URLSessionDataDelegate {

  private let request: URLRequest
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var onData: ((Data) -> Void)?
  private var onFinish: ((Error?) -> Void)?

  public init(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    self.request = request
    super.init()
  }

  public func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
    self.onData = onData
    self.onFinish = onFinish
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    self.session = session
    task = session.dataTask(with: request)
    task?.resume()
  }

  public func stop() {
    task?.cancel()
    session?.invalidateAndCancel()
    session = nil
  }

  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    onData?(data)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    onFinish?(error)
  }
}

/// Builds the URL for restarting a transcoded stream partway in.
///
/// Subsonic's answer to seeking when ranges are unavailable, confirmed working
/// against a real server. The result is a *different* stream, so whoever calls
/// this has to replace the source and reopen the reader rather than treating it
/// as a seek.
public func streamURL(base: URL, timeOffsetSeconds: Int) -> URL {
  guard timeOffsetSeconds > 0,
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    return base
  }
  var items = components.queryItems ?? []
  items.removeAll { $0.name == "timeOffset" }
  items.append(URLQueryItem(name: "timeOffset", value: String(timeOffsetSeconds)))
  components.queryItems = items
  return components.url ?? base
}
