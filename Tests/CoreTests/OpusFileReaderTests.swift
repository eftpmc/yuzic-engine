import XCTest
import AVFoundation
import COgg
import COpus
@testable import YuzicEngineCore

/**
 The Opus decoder, against a real Ogg Opus bitstream.

 The fixture is built here rather than checked in. libopus encodes the
 packets; the Ogg container around them is assembled by hand, because
 `libopusenc` — the library that normally does that — is a separate project
 and vendoring a third one to write a test fixture is a worse trade than
 writing the two header packets out.

 Both headers are specified in RFC 7845, and getting either wrong is caught
 immediately: `op_open_callbacks` refuses the stream.
 */
final class OpusFileReaderTests: XCTestCase {

  /// A 440Hz tone as Ogg Opus. Always 48kHz — Opus has no other rate.
  private func encodeTone(seconds: Double = 2, channels: Int = 2) -> Data {
    let rate: Int32 = 48_000
    var error: Int32 = 0
    guard let encoder = opus_encoder_create(rate, Int32(channels), OPUS_APPLICATION_AUDIO, &error),
          error == OPUS_OK else { return Data() }
    defer { opus_encoder_destroy(encoder) }

    var stream = ogg_stream_state()
    ogg_stream_init(&stream, 0x59555A43)  // any serial; fixed so runs are identical
    defer { ogg_stream_clear(&stream) }

    var output = Data()
    func drain(flush: Bool) {
      var page = ogg_page()
      while true {
        let got = flush ? ogg_stream_flush(&stream, &page) : ogg_stream_pageout(&stream, &page)
        if got == 0 { break }
        output.append(page.header, count: page.header_len)
        output.append(page.body, count: page.body_len)
      }
    }

    func put(_ bytes: [UInt8], packetNumber: Int64, granule: Int64, last: Bool = false) {
      var buffer = bytes
      buffer.withUnsafeMutableBufferPointer { raw in
        var packet = ogg_packet(
          packet: raw.baseAddress,
          bytes: raw.count,
          b_o_s: packetNumber == 0 ? 1 : 0,
          e_o_s: last ? 1 : 0,
          granulepos: granule,
          packetno: packetNumber
        )
        ogg_stream_packetin(&stream, &packet)
      }
    }

    // OpusHead, RFC 7845 §5.1. The pre-skip is the encoder's own lookahead;
    // reporting it wrong shifts every timestamp in the file.
    // 312 samples, libopus's lookahead at 48kHz. Declared as a constant
    // because `opus_encoder_ctl` is variadic and Swift cannot call it at all —
    // and it is safe to do so here: the pre-skip only tells the decoder how
    // much of the start to trim, so a small mismatch shifts the output by a
    // few milliseconds. These tests assert length within 2000 frames and
    // amplitude away from the start, neither of which that reaches.
    let lookahead: Int32 = 312
    var head: [UInt8] = Array("OpusHead".utf8)
    head += [1, UInt8(channels)]
    head += [UInt8(lookahead & 0xFF), UInt8((lookahead >> 8) & 0xFF)]
    head += [0x80, 0xBB, 0x00, 0x00]   // 48000, little-endian
    head += [0, 0]                     // output gain
    head += [0]                        // channel mapping family 0
    put(head, packetNumber: 0, granule: 0)
    drain(flush: true)                 // the header gets a page to itself

    // OpusTags, RFC 7845 §5.2: vendor string, then a comment count of zero.
    let vendor = Array("yuzic-engine tests".utf8)
    var tags: [UInt8] = Array("OpusTags".utf8)
    tags += withUnsafeBytes(of: UInt32(vendor.count).littleEndian) { Array($0) }
    tags += vendor
    tags += withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }
    put(tags, packetNumber: 1, granule: 0)
    drain(flush: true)

    // 20ms frames, which is Opus's default and what every encoder emits.
    let frameSize = 960
    let totalFrames = Int(Double(rate) * seconds)
    var pcm = [Float](repeating: 0, count: frameSize * channels)
    var encoded = [UInt8](repeating: 0, count: 4000)
    var phase = 0.0
    var packetNumber: Int64 = 2
    var granule = Int64(lookahead)
    var written = 0

    while written < totalFrames {
      for frame in 0..<frameSize {
        phase += 2.0 * Double.pi * 440.0 / Double(rate)
        let sample = Float(0.5 * sin(phase))
        for channel in 0..<channels { pcm[frame * channels + channel] = sample }
      }
      let count = encoded.withUnsafeMutableBufferPointer { out -> Int32 in
        guard let base = out.baseAddress else { return 0 }
        return opus_encode_float(encoder, pcm, Int32(frameSize), base, Int32(out.count))
      }
      guard count > 0 else { break }

      written += frameSize
      granule += Int64(frameSize)
      let last = written >= totalFrames
      put(Array(encoded[0..<Int(count)]), packetNumber: packetNumber, granule: granule, last: last)
      packetNumber += 1
      drain(flush: last)
    }

    return output
  }

  /// The whole file in memory, behind the interface the network uses.
  private final class MemorySource: ByteSource {
    private let blob: Data
    init(_ blob: Data) { self.blob = blob }
    func totalBytes() throws -> Int64 { Int64(blob.count) }
    func read(offset: Int64, count: Int) throws -> Data {
      let start = min(Int(offset), blob.count)
      return blob.subdata(in: start..<min(start + count, blob.count))
    }
    func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(blob.count) - offset) }
    func cancel() {}
    func resume() {}
  }

  private func makeReader() -> OpusFileReader {
    OpusFileReader(source: MemorySource(encodeTone()))
  }

  func testTheFixtureIsAValidOggOpusStream() {
    let data = encodeTone(seconds: 0.5)
    XCTAssertGreaterThan(data.count, 1000, "the encoder produced nothing to decode")
    XCTAssertEqual(HTTPTrackReaderFactory.oggCodec(MemorySource(data)), .opus)
  }

  func testReadsTheStreamShapeFromTheHeaders() throws {
    let reader = makeReader()
    try reader.open()

    // Always 48kHz. Opus has no other output rate, whatever was encoded.
    XCTAssertEqual(reader.sampleRate, 48_000)
    XCTAssertEqual(reader.channelCount, 2)
    XCTAssertEqual(Double(reader.totalFrames), 96_000, accuracy: 2_000)
  }

  /**
   Audio comes out, and it is the tone that went in.

   RMS rather than sample equality: Opus is lossy, so asserting the samples
   came back unchanged would be asserting the wrong thing. A 0.5-amplitude
   sine has an RMS near 0.354.
   */
  func testDecodesAudioRatherThanSilence() throws {
    let reader = makeReader()
    try reader.open()

    // Past the pre-skip, which is encoder lookahead and legitimately quiet.
    try reader.seek(toFrame: 24_000)
    let decoded = try XCTUnwrap(try reader.read(frames: 8192))
    XCTAssertGreaterThan(decoded.frameLength, 0)

    var sum: Float = 0
    let data = decoded.floatChannelData![0]
    for index in 0..<Int(decoded.frameLength) { sum += data[index] * data[index] }
    let rms = sqrt(sum / Float(decoded.frameLength))
    XCTAssertEqual(rms, 0.354, accuracy: 0.1, "decoded signal was not the tone that was encoded")
  }

  func testEndOfStreamIsNilAndNotAnError() throws {
    let reader = makeReader()
    try reader.open()

    var total: AVAudioFrameCount = 0
    while let buffer = try reader.read(frames: 16_384), buffer.frameLength > 0 {
      total += buffer.frameLength
      if total > 400_000 { XCTFail("read past the end of a two-second file"); return }
    }
    XCTAssertEqual(Double(total), 96_000, accuracy: 2_000)
  }

  func testSeekingMovesThePlayhead() throws {
    let reader = makeReader()
    try reader.open()

    try reader.seek(toFrame: 48_000)
    XCTAssertGreaterThan(try XCTUnwrap(try reader.read(frames: 4096)).frameLength, 0)

    try reader.seek(toFrame: 0)
    XCTAssertGreaterThan(try XCTUnwrap(try reader.read(frames: 4096)).frameLength, 0)
  }

  func testOpeningSomethingThatIsNotOpusFails() {
    let reader = OpusFileReader(source: MemorySource(Data(repeating: 0x41, count: 8192)))
    XCTAssertThrowsError(try reader.open())
  }

  // MARK: - A source that stops serving is not a file that ended

  /**
   Serves the whole file until told to stop, then behaves as instructed.

   The switch is thrown *after* `open()`, because that is the real shape of the
   fault: the headers are read on a working connection and the stall arrives
   during playback. Failing from the first byte would only test `open`, which
   already reports for itself.
   */
  private final class FlakySource: ByteSource {
    enum Mode { case serving, throwsFetchFailed, throwsCancelled, returnsEmpty }

    private let blob: Data
    var mode: Mode = .serving

    init(_ blob: Data) { self.blob = blob }

    func totalBytes() throws -> Int64 { Int64(blob.count) }

    func read(offset: Int64, count: Int) throws -> Data {
      switch mode {
      case .throwsFetchFailed: throw ByteSourceError.fetchFailed("stalled")
      case .throwsCancelled: throw ByteSourceError.cancelled
      case .returnsEmpty: return Data()
      case .serving:
        let start = min(Int(offset), blob.count)
        return blob.subdata(in: start..<min(start + count, blob.count))
      }
    }

    func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(blob.count) - offset) }
    func cancel() {}
    func resume() {}
  }

  /// Reads until something throws or the stream ends. Returns the error, if any.
  private func drain(_ reader: OpusFileReader) -> Error? {
    for _ in 0..<512 {
      do {
        guard let buffer = try reader.read(frames: 4096), buffer.frameLength > 0 else {
          return nil
        }
      } catch {
        return error
      }
    }
    return nil
  }

  /**
   The bug this guards: opusfile's read callback cannot throw, and answers 0
   for end of stream. A source that could not serve returned 0 too, so a
   stalled network arrived as a cleanly finished file — `read` returned nil,
   `TrackPlayback` set `reachedEnd`, and the engine advanced to the next track
   with nothing thrown anywhere. The same fault `AudioFileReader` carried, in
   the Ogg path, found after that one was fixed.
   */
  /**
   Opens on a working source, decodes a little, and only then stalls.

   The fixture is long for a unit test on purpose. At two seconds opusfile has
   read the whole file before the first buffer comes back, so the stall lands
   *at* the end — where the reader is right to call it the end, and the test
   passes whatever the code does. Thirty seconds leaves file left to read.
   */
  private func stalling(_ mode: FlakySource.Mode) throws -> Error? {
    let source = FlakySource(encodeTone(seconds: 30))
    let reader = OpusFileReader(source: source)
    try reader.open()

    XCTAssertNotNil(try reader.read(frames: 4096),
                    "the fixture did not decode before the stall was introduced")

    source.mode = mode
    return drain(reader)
  }

  func testAStalledSourceThrowsRatherThanReadingAsTheEnd() throws {
    XCTAssertNotNil(try stalling(.throwsFetchFailed),
                    "a source that stopped serving reported the file as finished")
  }

  func testASourceServingNothingBeforeTheEndThrows() throws {
    XCTAssertNotNil(try stalling(.returnsEmpty),
                    "an empty read before the end reported the file as finished")
  }

  /**
   The other half, and the reason the callback cannot simply throw on
   everything: a seek abandons the read in flight on purpose. That is not a
   failure, and unwinding it as end of stream is what lets the parser recover.
   */
  func testACancelledReadIsStillTreatedAsTheEnd() throws {
    XCTAssertNil(try stalling(.throwsCancelled),
                 "a deliberate cancellation was raised as a failure")
  }
}
