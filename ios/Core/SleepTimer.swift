import Foundation

/**
 Stops playback after a while, with a fade rather than a cut.

 Native, and not a `setTimeout` up in JavaScript, for the reason that governs
 everything else here: the app is backgrounded and its JS suspended for exactly
 the period a sleep timer is meant to span. A timer that only fires while the
 screen is on is not a sleep timer.

 The fade at the end is not decoration. Music cutting off mid-bar is the thing
 that wakes people, which defeats the entire purpose of the feature.
 */
public final class SleepTimer {

  /// How long the music takes to disappear at the end. Long enough to be
  /// gentle, short enough not to feel like a fault.
  public static let fadeOutSeconds: TimeInterval = 8

  private var timer: Timer?
  private let onFire: (TimeInterval) -> Void

  /// `onFire` is handed the fade duration and is expected to fade and pause.
  public init(onFire: @escaping (TimeInterval) -> Void) {
    self.onFire = onFire
  }

  deinit { timer?.invalidate() }

  public private(set) var firesAt: Date?

  public var remainingSeconds: TimeInterval? {
    guard let firesAt else { return nil }
    return max(0, firesAt.timeIntervalSinceNow)
  }

  public func schedule(after seconds: TimeInterval) {
    cancel()
    guard seconds > 0 else { return }

    // Fire early by the fade length so the music has *finished* fading when the
    // requested time arrives, rather than starting to fade then. Asking for
    // twenty minutes and still hearing something at twenty-and-a-bit is the
    // wrong reading of the request.
    let fade = min(Self.fadeOutSeconds, seconds / 2)
    let delay = max(0.1, seconds - fade)

    firesAt = Date().addingTimeInterval(seconds)
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      guard let self else { return }
      self.firesAt = nil
      self.timer = nil
      self.onFire(fade)
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  public func cancel() {
    timer?.invalidate()
    timer = nil
    firesAt = nil
  }
}
