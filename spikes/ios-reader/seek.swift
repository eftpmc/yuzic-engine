import AVFoundation
import AudioToolbox

/**
 Spike item 1: does Apple's decoder ignore the seek structures in the file?

 The claim under test is that FLAC and MP3 decode from byte zero rather than
 using SEEKTABLE / the Xing TOC, making seek cost linear in distance. If true,
 a self-hosted FLAC library gets an unusable scrubber, and we bundle libFLAC on
 day one rather than discovering it later.

 Method: open the file fresh for every measurement (so nothing is warm in the
 decoder), seek to a fraction of the way in, read one buffer, and time the
 seek+read pair. WAV and ALAC are the controls — both should be effectively
 instant at any position, because both are seekable by arithmetic.
 */

let files = ["tone.wav", "tone.flac", "tone.m4a"]
let fractions = [0.1, 0.5, 0.9]
let readFrames: AVAudioFrameCount = 4096

func measure(path: String, fraction: Double) -> (seconds: Double, ok: Bool) {
  guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
    return (0, false)
  }
  let target = AVAudioFramePosition(Double(file.length) * fraction)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readFrames) else {
    return (0, false)
  }

  let start = DispatchTime.now().uptimeNanoseconds
  file.framePosition = target
  do {
    try file.read(into: buffer, frameCount: readFrames)
  } catch {
    return (0, false)
  }
  let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

  return (elapsed, buffer.frameLength > 0)
}

print("")
print("seek + first read, cold open each time (20 min file, 44.1kHz stereo)")
print("")
print("format      10%         50%         90%")
print("------      ---         ---         ---")

for path in files {
  let ext = (path as NSString).pathExtension.uppercased()
  var row = ext.padding(toLength: 12, withPad: " ", startingAt: 0)
  for fraction in fractions {
    // Three runs, keep the best: we are measuring decoder work, and the first
    // run also pays page-cache faults that have nothing to do with the claim.
    var best = Double.infinity
    var ok = true
    for _ in 0..<3 {
      let result = measure(path: path, fraction: fraction)
      if !result.ok { ok = false }
      best = min(best, result.seconds)
    }
    let cell = ok ? String(format: "%.4fs", best) : "FAILED"
    row += cell.padding(toLength: 12, withPad: " ", startingAt: 0)
  }
  print(row)
}
print("")
