import Foundation
import AVFoundation
// SwiftPM builds libFLAC as its own C module. CocoaPods builds all engine
// subspecs into YuzicEngine, whose umbrella already exposes these headers.
#if canImport(CFLAC)
import CFLAC
#endif

/**
 FLAC, decoded by libFLAC rather than by Core Audio.

 Core Audio *can* open a `.flac`, which is why this reader took so long to
 exist. What it cannot do is stream one. Two properties make it unusable here,
 both measured rather than assumed — see `docs/architecture.md` §10:

 - **It seeks backwards whenever it likes.** A transcoded stream is
   forward-only (§10's second transport), so a parser that re-reads earlier
   bytes cannot be served at all. This is what made one 46MB 24-bit FLAC fail
   to play over cellular while the same track downloaded was fine: the first
   play of a lossless source hits a *cold* transcode, which Navidrome answers
   `200` with no length, and the engine correctly falls to the sequential
   transport — where Core Audio's backward seeks then die.
 - **Seeking costs the whole file.** Playing from 90% in touched 177% of the
   file, because it reads from the start to the seek point, some regions twice.
   Random access buys nothing, which defeats the ranged design for the format
   this app's audience mostly holds.

 libFLAC has neither problem. Its seek/tell/length callbacks may report
 `UNSUPPORTED`, and it then decodes strictly forward — measured on the failing
 track: 100% of the audio, zero seeks. When the source *is* seekable it uses
 the file's own SEEKTABLE, so the same 90% seek touched **1.1%** of the file
 rather than 177%.

 The shape below is `VorbisFileReader`'s: C callbacks over a `ByteSource`, with
 the two things a C callback cannot do — throwing, and distinguishing a stalled
 read from a finished file — carried across the boundary by hand.
 */
public final class FLACFileReader: TrackReader {

  public enum FLACError: Error {
    /// The decoder could not be created — allocation, nothing else.
    case decoderUnavailable
    /// Not a FLAC stream, or the headers are damaged.
    case notFLAC(String)
    /// Decoding failed after the stream opened.
    case readFailed(String)
    case seekFailed
  }

  private let source: ByteSource
  private var decoder: UnsafeMutablePointer<FLAC__StreamDecoder>?
  private var opened = false

  /// Where libFLAC believes it is in the byte stream. It drives the reads
  /// itself, so this is the callbacks' cursor rather than a playback position.
  private var byteOffset: Int64 = 0

  /// See `VorbisFileReader.sourceFailure`. libFLAC reads a short/zero read as
  /// end-of-stream exactly as `fread` does, so a stalled network is
  /// indistinguishable from a finished file unless the reason is carried out
  /// by hand.
  private var sourceFailure: Error?

  /// See `VorbisFileReader.sourceCancelled`. A seek abandons the read in
  /// flight on purpose; that is an ending, but not the track ending.
  private var sourceCancelled = false

  /// Frames handed to us by the write callback and not yet passed upward.
  /// libFLAC delivers a whole block at a time and will not be asked for a
  /// partial one, so anything the caller did not take is kept here.
  private var pending: AVAudioPCMBuffer?
  private var pendingOffset: AVAudioFrameCount = 0

  /// Set by the write callback so `read` knows a block arrived.
  private var lastBlockFrames: AVAudioFrameCount = 0

  public private(set) var totalFrames: Int64 = 0
  public private(set) var sampleRate: Double = 0
  public private(set) var channelCount: UInt32 = 0
  public private(set) var outputFormat: AVAudioFormat?

  /// Bits per sample as the file declares it. Kept because it is what the
  /// integer-to-float conversion divides by, and because a 24-bit file is the
  /// case that prompted this reader.
  public private(set) var bitsPerSample: UInt32 = 0

  public init(source: ByteSource) {
    self.source = source
  }

  deinit {
    if let decoder {
      FLAC__stream_decoder_finish(decoder)
      FLAC__stream_decoder_delete(decoder)
    }
  }

  /**
   Read the metadata blocks and learn the shape of the stream.

   Idempotent, like the other readers: the factory opens a reader before
   handing it over and the engine opens it again.
   */
  public func open() throws {
    guard !opened else { return }

    guard let decoder = FLAC__stream_decoder_new() else {
      throw FLACError.decoderUnavailable
    }
    self.decoder = decoder

    // The MD5 in STREAMINFO covers the whole decoded stream, so checking it
    // means buffering every sample to the end before any of it can be trusted.
    // Pointless for playback, and impossible for a stream.
    FLAC__stream_decoder_set_md5_checking(decoder, 0)

    let client = Unmanaged.passUnretained(self).toOpaque()

    /*
     Seek, tell and length are only offered when the source can actually serve
     them. On the sequential transport they report `UNSUPPORTED`, which makes
     libFLAC decode strictly forward — and that is the whole point of this
     reader. Offering them and failing the seek later would be worse than
     declining up front: libFLAC treats an *error* as a broken stream, where it
     treats `UNSUPPORTED` as a fact about the file and carries on.
     */
    let seekable = !source.isSequential

    let status = FLAC__stream_decoder_init_stream(
      decoder,
      { _, buffer, bytes, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        return reader.readBytes(into: buffer, bytes: bytes)
      },
      seekable ? { _, offset, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        reader.byteOffset = Int64(offset)
        return FLAC__STREAM_DECODER_SEEK_STATUS_OK
      } : nil,
      seekable ? { _, offset, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        offset!.pointee = FLAC__uint64(reader.byteOffset)
        return FLAC__STREAM_DECODER_TELL_STATUS_OK
      } : nil,
      seekable ? { _, length, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        let total = (try? reader.source.totalBytes()) ?? 0
        guard total > 0 else { return FLAC__STREAM_DECODER_LENGTH_STATUS_UNSUPPORTED }
        length!.pointee = FLAC__uint64(total)
        return FLAC__STREAM_DECODER_LENGTH_STATUS_OK
      } : nil,
      seekable ? { _, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        let total = (try? reader.source.totalBytes()) ?? 0
        return (total > 0 && reader.byteOffset >= total) ? 1 : 0
      } : nil,
      { _, frame, buffers, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        return reader.receive(frame: frame, buffers: buffers)
      },
      { _, metadata, client in
        let reader = Unmanaged<FLACFileReader>.fromOpaque(client!).takeUnretainedValue()
        reader.receive(metadata: metadata)
      },
      { _, _, _ in
        // Recoverable frame-level complaints — a lost sync, a bad header.
        // libFLAC resynchronises and carries on, so this is deliberately not
        // turned into a failure. A genuinely unreadable stream fails through
        // the decoder's state instead.
      },
      client
    )

    guard status == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
      // The raw value rather than libFLAC's own string table: that table is a
      // C array of pointers, which Swift declines to import. The numbers are
      // in `FLAC/stream_decoder.h` and this path is rare enough that a lookup
      // is acceptable — an unopenable stream is a broken file, not a state to
      // recover from.
      throw FLACError.notFLAC("init status \(status.rawValue)")
    }

    // Reads the metadata blocks, which is what fires the metadata callback and
    // fills in the stream's shape below.
    guard FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0 else {
      if let failure = sourceFailure { sourceFailure = nil; throw failure }
      throw FLACError.notFLAC(stateString())
    }
    if let failure = sourceFailure { sourceFailure = nil; throw failure }

    guard sampleRate > 0, channelCount > 0 else {
      throw FLACError.notFLAC("no STREAMINFO")
    }

    // Everything downstream is stereo float32 non-interleaved, matching the
    // other readers and what `AVAudioPlayerNode` wants.
    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
      channels: 2, interleaved: false)

    opened = true
  }

  public func seek(toFrame frame: Int64) throws {
    guard opened, let decoder else { return }
    // Declining rather than failing: on the sequential transport there is
    // nothing to seek within, and the layer above answers a seek by
    // reconnecting the stream with `timeOffset` instead.
    guard !source.isSequential else { throw FLACError.seekFailed }
    dropPending()
    guard FLAC__stream_decoder_seek_absolute(decoder, FLAC__uint64(max(0, frame))) != 0 else {
      // A failed seek leaves the decoder in SEEK_ERROR, from which nothing can
      // be read until it is reset. Upstream requires flush-or-reset here.
      FLAC__stream_decoder_flush(decoder)
      throw FLACError.seekFailed
    }
  }

  /**
   Decode up to `frames` frames.

   libFLAC hands back one block at a time through the write callback, and a
   block is whatever size the encoder chose — 4608 frames for the track this
   was written for. So this drives the decoder until it has enough, keeping
   whatever overshoots for the next call.
   */
  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard opened, let decoder, let format = outputFormat,
          let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let outChannels = out.floatChannelData else { return nil }

    var filled: AVAudioFrameCount = 0

    while filled < frames {
      // Anything left from the previous block goes first.
      if let held = pending, let heldChannels = held.floatChannelData {
        let available = held.frameLength - pendingOffset
        let take = min(available, frames - filled)
        for channel in 0..<2 {
          outChannels[channel].advanced(by: Int(filled))
            .update(from: heldChannels[channel].advanced(by: Int(pendingOffset)), count: Int(take))
        }
        filled += take
        pendingOffset += take
        if pendingOffset >= held.frameLength { dropPending() }
        continue
      }

      // Decode one more block.
      lastBlockFrames = 0
      let ok = FLAC__stream_decoder_process_single(decoder)

      // Asked before the result is interpreted, for the same reason every
      // other reader here does it: a source that could not serve makes the
      // decoder report a clean end of stream, and 0 means "the file ended"
      // only once this is nil.
      if let failure = sourceFailure {
        sourceFailure = nil
        throw failure
      }
      if sourceCancelled {
        sourceCancelled = false
        break
      }
      guard ok != 0 else { throw FLACError.readFailed(stateString()) }

      let state = FLAC__stream_decoder_get_state(decoder)
      if state == FLAC__STREAM_DECODER_END_OF_STREAM { break }
      // A block that produced nothing and did not end the stream is a metadata
      // block or a resync; go round again rather than treating it as the end.
      if lastBlockFrames == 0 && pending == nil { continue }
    }

    out.frameLength = filled
    return filled > 0 ? out : nil
  }

  /**
   How much beyond `frame` is already fetched, in frames.

   Converted from bytes by the stream's own ratio. FLAC is variable-rate per
   block, so this is an estimate — it feeds a progress bar, where being a
   little out is invisible and being expensive would not be.
   */
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 {
    guard opened, sampleRate > 0, totalFrames > 0 else { return 0 }
    let totalBytes = (try? source.totalBytes()) ?? 0
    guard totalBytes > 0 else { return 0 }
    let bytesAhead = source.availableBytes(from: byteOffset)
    let framesPerByte = Double(totalFrames) / Double(totalBytes)
    return Int64(Double(bytesAhead) * framesPerByte)
  }

  public var isSequential: Bool { source.isSequential }

  public func cancelPendingReads() { source.cancel() }
  public func resumePendingReads() { source.resume() }

  // MARK: - libFLAC's stream, over a ByteSource

  private func dropPending() {
    pending = nil
    pendingOffset = 0
  }

  private func stateString() -> String {
    guard let decoder else { return "no decoder" }
    return String(cString: FLAC__stream_decoder_get_resolved_state_string(decoder))
  }

  private func readBytes(
    into buffer: UnsafeMutablePointer<FLAC__byte>?,
    bytes: UnsafeMutablePointer<Int>?
  ) -> FLAC__StreamDecoderReadStatus {
    guard let buffer, let bytes, bytes.pointee > 0 else {
      return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }
    let wanted = bytes.pointee

    let data: Data
    do {
      data = try source.read(offset: byteOffset, count: wanted)
    } catch ByteSourceError.cancelled {
      sourceCancelled = true
      bytes.pointee = 0
      return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
    } catch {
      sourceFailure = error
      bytes.pointee = 0
      // ABORT rather than END_OF_STREAM: a source that could not serve has not
      // finished, and reporting an ending here is the exact relabelling of
      // failure as success that cost this engine two separate bugs.
      return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }

    if data.isEmpty {
      let total = (try? source.totalBytes()) ?? 0
      // Empty at or past a *known* end is the end. A sequential source's
      // `totalBytes` is an estimate until the producer finishes, so the length
      // only counts when it is real — the same rule `AudioFileReader.readProc`
      // applies.
      let lengthIsKnown = source.isFinished || !source.isSequential
      if total > 0 && byteOffset >= total && lengthIsKnown {
        bytes.pointee = 0
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
      }
      sourceFailure = ByteSourceError.fetchFailed("empty read at \(byteOffset) of \(total)")
      bytes.pointee = 0
      return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }

    data.copyBytes(to: buffer, count: data.count)
    bytes.pointee = data.count
    byteOffset += Int64(data.count)
    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
  }

  private func receive(metadata: UnsafePointer<FLAC__StreamMetadata>?) {
    guard let metadata, metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
    let info = metadata.pointee.data.stream_info
    sampleRate = Double(info.sample_rate)
    bitsPerSample = info.bits_per_sample
    // A mono source is widened to stereo by the conversion below rather than
    // special-cased in the graph, matching `AudioFileReader`.
    channelCount = max(1, min(2, info.channels))
    totalFrames = Int64(info.total_samples)
  }

  /**
   One decoded block, converted to the float32 the graph runs on.

   libFLAC hands back **signed integers in the file's own bit depth**, left
   aligned in `FLAC__int32`. Dividing by the full-scale value for that depth is
   the whole conversion — and it has to use the *file's* depth, not a fixed
   one: the track this reader was written for is 24-bit, where dividing by
   32768 as a 16-bit file would want overflows by 256x.
   */
  private func receive(
    frame: UnsafePointer<FLAC__Frame>?,
    buffers: UnsafePointer<UnsafePointer<FLAC__int32>?>?
  ) -> FLAC__StreamDecoderWriteStatus {
    guard let frame, let buffers, let format = outputFormat else {
      return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }
    let count = AVAudioFrameCount(frame.pointee.header.blocksize)
    guard count > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
          let out = buffer.floatChannelData else {
      return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }
    buffer.frameLength = count

    // The depth of *this* frame, which is authoritative over STREAMINFO — they
    // agree in every normal file, and where they do not, the frame is what was
    // actually encoded.
    let depth = frame.pointee.header.bits_per_sample
    let scale = Float(1.0 / Double(Int64(1) << (depth - 1)))

    let sourceChannels = Int(frame.pointee.header.channels)
    for channel in 0..<2 {
      // Mono is widened by pointing both output channels at the one input.
      let index = min(channel, sourceChannels - 1)
      guard index >= 0, let plane = buffers[index] else {
        // Nothing to copy: leave silence rather than abort the whole stream.
        out[channel].update(repeating: 0, count: Int(count))
        continue
      }
      let target = out[channel]
      for sample in 0..<Int(count) {
        target[sample] = Float(plane[sample]) * scale
      }
    }

    pending = buffer
    pendingOffset = 0
    lastBlockFrames = count
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
  }
}
