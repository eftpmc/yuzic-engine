import Foundation
import AVFoundation
#if canImport(COpus)
import COgg
import COpus
#endif

/**
 An Ogg Opus decoder, for the same reason `VorbisFileReader` exists.

 Core Audio has a raw Opus decoder (`kAudioFormatOpus`) and no Ogg container
 to put it in, so a `.opus` file off a Subsonic server — which is Opus in Ogg
 — cannot be opened at all. The app worked around it by having the server
 transcode to MP3, which plays and throws away the quality that choosing
 Original was meant to keep.

 `opusfile` does the container and the decode. Its callbacks take a stream,
 and `ByteSource` already is one, so this reuses the same cache, ranged
 requests and cancellation as every other reader here.

 **Frames are always at 48kHz.** Opus decodes to 48kHz whatever the source was
 recorded at — the format has no other output rate — so `sampleRate` reports
 48000 and every frame count here is in those units. That is what the rest of
 the engine wants anyway: `TrackReader` is defined in source frames at
 `sampleRate`, and for Opus those are the same thing.
 */
public final class OpusFileReader: TrackReader {

  public enum OpusError: Error {
    /// Not an Ogg Opus stream, or the headers are damaged. Carries
    /// opusfile's own code, which distinguishes "not opus" from "truncated".
    case notOpus(Int32)
    case seekFailed(Int32)
    case readFailed(Int32)
  }

  /// Opus always decodes at 48kHz. Not a choice this makes.
  private static let outputRate: Double = 48_000

  private let source: ByteSource
  private var file: OpaquePointer?
  private var byteOffset: Int64 = 0

  /**
   Why the stream callback stopped serving bytes, when it was not the end.

   `readBytes` is a C callback and cannot throw: opusfile reads 0 as end of
   stream, and there is no other way out of it. So a failure is recorded here
   and raised by `read` on the way back up, which is the first place a Swift
   error can exist again.

   Without it a stalled network reads exactly like a finished file — the same
   fault `AudioFileReader.readProc` carried, where a stall was relabelled
   end-of-file before it left the callback and the engine advanced to the next
   track with nothing thrown anywhere. Only the Core Audio path was fixed;
   this is the same bug in the Ogg path.

   Touched only from the decode queue, like `byteOffset`.
   */
  private var sourceFailure: Error?

  /**
   Whether the callback returned 0 because a read was cancelled on purpose.

   Carried separately from `sourceFailure` because the two unwind differently:
   a failure is raised, a cancellation is the end of the read and nothing more.
   Needed because opusfile does not take a mid-stream 0 as a clean end of
   stream the way vorbisfile does — it reports `OP_EBADLINK`, which without
   this would surface a deliberate seek as a decode error.
   */
  private var sourceCancelled = false

  public private(set) var totalFrames: Int64 = 0
  public private(set) var sampleRate: Double = 0
  public private(set) var channelCount: UInt32 = 0
  public private(set) var outputFormat: AVAudioFormat?

  public init(source: ByteSource) {
    self.source = source
  }

  deinit {
    if let file { op_free(file) }
  }

  public func open() throws {
    guard file == nil else { return }

    var callbacks = OpusFileCallbacks(
      read: { handle, buffer, count in
        let reader = Unmanaged<OpusFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return reader.readBytes(into: buffer, count: count)
      },
      seek: { handle, offset, whence in
        let reader = Unmanaged<OpusFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return reader.seekBytes(to: offset, whence: whence)
      },
      tell: { handle in
        let reader = Unmanaged<OpusFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return reader.byteOffset
      },
      // Nothing to close: the `ByteSource` is owned by whoever built it.
      close: nil
    )

    var status: Int32 = 0
    let handle = Unmanaged.passUnretained(self).toOpaque()
    guard let opened = op_open_callbacks(handle, &callbacks, nil, 0, &status) else {
      throw OpusError.notOpus(status)
    }
    file = opened

    channelCount = UInt32(max(1, op_channel_count(opened, -1)))
    sampleRate = Self.outputRate
    // -1 for a stream whose length is not known, which the engine already
    // reads as "no finish line, draw no progress bar".
    let total = op_pcm_total(opened, -1)
    totalFrames = total > 0 ? Int64(total) : 0

    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channelCount),
      interleaved: false
    )
  }

  public func seek(toFrame frame: Int64) throws {
    guard let file else { return }
    let status = op_pcm_seek(file, ogg_int64_t(max(0, frame)))
    guard status == 0 else { throw OpusError.seekFailed(status) }
  }

  /**
   Decode up to `frames` frames.

   `op_read_float` hands back *interleaved* float, unlike vorbisfile's planar
   output, so this de-interleaves into the buffer's channel planes. It also
   returns one packet at a time — fewer frames than asked for is normal and is
   not end of stream — so it loops until the buffer is full or the stream ends.
   */
  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard let file, let format = outputFormat,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let channels = buffer.floatChannelData else { return nil }

    let channelCount = Int(self.channelCount)
    var scratch = [Float](repeating: 0, count: 5760 * channelCount)
    var filled: AVAudioFrameCount = 0

    while filled < frames {
      let room = Int(frames - filled)
      let decoded: Int32 = scratch.withUnsafeMutableBufferPointer { raw in
        // opusfile counts this argument in *samples*, not frames, and will
        // not split a packet — so it needs room for a whole one (120ms at
        // 48kHz, 5760 frames) or it returns OP_EBADLINK.
        op_read_float(file, raw.baseAddress, Int32(min(raw.count, room * channelCount)), nil)
      }

      // Asked before `decoded` is interpreted: a source that could not serve
      // makes opusfile report a clean end of stream, so 0 here means "the file
      // ended" only once this is nil.
      if let failure = sourceFailure {
        sourceFailure = nil
        throw failure
      }

      // Before `decoded` is judged at all: a cancelled read reaches opusfile
      // as a 0 and comes back as OP_EBADLINK, which is not a broken file.
      if sourceCancelled {
        sourceCancelled = false
        break
      }

      if decoded == 0 { break }
      if decoded < 0 { throw OpusError.readFailed(decoded) }

      let count = Int(decoded)
      for frame in 0..<count {
        for channel in 0..<channelCount {
          channels[channel][Int(filled) + frame] = scratch[frame * channelCount + channel]
        }
      }
      filled += AVAudioFrameCount(count)
    }

    buffer.frameLength = filled
    return filled > 0 ? buffer : nil
  }

  /// See `VorbisFileReader` — the same average-bitrate estimate, for the same
  /// reason: a progress bar does not need an exact byte-to-frame map, and
  /// getting one would mean seeking.
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 {
    guard file != nil, totalFrames > 0 else { return 0 }
    let totalBytes = (try? source.totalBytes()) ?? 0
    guard totalBytes > 0 else { return 0 }
    let bytesAhead = source.availableBytes(from: byteOffset)
    return Int64(Double(bytesAhead) * (Double(totalFrames) / Double(totalBytes)))
  }

  public func cancelPendingReads() { source.cancel() }
  public func resumePendingReads() { source.resume() }

  // MARK: - opusfile's stream, over a ByteSource

  private func readBytes(into buffer: UnsafeMutablePointer<UInt8>?, count: Int32) -> Int32 {
    guard let buffer, count > 0 else { return 0 }

    let data: Data
    do {
      data = try source.read(offset: byteOffset, count: Int(count))
    } catch ByteSourceError.cancelled {
      // Abandoned on purpose by a seek. Not a failure — but opusfile will turn
      // the 0 into OP_EBADLINK, so it has to be remembered to be told apart
      // from a real decode error on the way back up.
      sourceCancelled = true
      return 0
    } catch {
      sourceFailure = error
      return 0
    }

    if data.isEmpty {
      // Empty *at or past* the end is the end. Empty before it is a source
      // that could not serve, which must not read as the song finishing.
      let total = (try? source.totalBytes()) ?? 0
      if !(total > 0 && byteOffset >= total) {
        sourceFailure = ByteSourceError.fetchFailed(
          "empty read at \(byteOffset) of \(total)"
        )
      }
      return 0
    }

    data.copyBytes(to: buffer, count: data.count)
    byteOffset += Int64(data.count)
    return Int32(data.count)
  }

  private func seekBytes(to offset: ogg_int64_t, whence: Int32) -> Int32 {
    let total = (try? source.totalBytes()) ?? 0
    let target: Int64
    switch whence {
    case SEEK_SET: target = Int64(offset)
    case SEEK_CUR: target = byteOffset + Int64(offset)
    case SEEK_END: target = total + Int64(offset)
    default: return -1
    }
    guard target >= 0 else { return -1 }
    byteOffset = target
    return 0
  }
}
