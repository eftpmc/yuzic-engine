import AVFoundation

// A long file of actual varying audio. Silence or a pure tone can be encoded
// into almost nothing, which would let a decoder skip work a real track makes
// it do — the point of the measurement is decode cost, so the content has to
// be worth decoding.

let minutes = Double(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20)
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tone.wav"

let sampleRate = 44_100.0
let frames = AVAudioFrameCount(sampleRate * 60 * minutes)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!

let settings: [String: Any] = [
  AVFormatIDKey: kAudioFormatLinearPCM,
  AVSampleRateKey: sampleRate,
  AVNumberOfChannelsKey: 2,
  AVLinearPCMBitDepthKey: 16,
  AVLinearPCMIsFloatKey: false,
  AVLinearPCMIsBigEndianKey: false,
]

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

let chunk = AVAudioFrameCount(sampleRate) // one second at a time
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
var written: AVAudioFrameCount = 0
var phase = 0.0

while written < frames {
  let count = min(chunk, frames - written)
  buffer.frameLength = count
  let left = buffer.floatChannelData![0]
  let right = buffer.floatChannelData![1]
  for i in 0..<Int(count) {
    // Sweeping frequency plus noise: broadband, so the encoder cannot cheat.
    let t = (Double(written) + Double(i)) / sampleRate
    let freq = 220.0 + 660.0 * (0.5 + 0.5 * sin(t / 30.0))
    phase += 2.0 * Double.pi * freq / sampleRate
    let noise = Double.random(in: -0.15...0.15)
    let sample = Float(0.35 * sin(phase) + noise)
    left[i] = sample
    right[i] = sample * 0.9
  }
  try file!.write(from: buffer)
  written += count
}

// AVAudioFile finalises the header when it deallocates. Let it go before
// the process exits, or the data-chunk size stays zero and the file reads
// as empty despite being on disk at full size.
file = nil

print("wrote \(outPath): \(Int(minutes)) min, \(frames) frames")
