package dev.yuzic.engine

import android.os.Handler
import android.os.Looper

/**
 * Stops playback after a while, with a fade rather than a cut.
 *
 * A direct port of `ios/Core/SleepTimer.swift`, and kept close to it on
 * purpose: the timing rule below is observable product behaviour, not an iOS
 * detail, so a change to one should read as an obvious omission in the other.
 *
 * Native, and not a `setTimeout` up in JavaScript, for the reason that governs
 * everything else here: the app is backgrounded and its JS suspended for
 * exactly the period a sleep timer is meant to span. A timer that only fires
 * while the screen is on is not a sleep timer.
 *
 * A `Handler` on the main looper rather than a `CoroutineScope` or a
 * `WorkManager` job, for two different reasons. The fade has to be applied on
 * the player's own thread anyway, so arriving there is free. And this is
 * deliberately *not* durable across process death: a sleep timer that survives
 * the app being killed and starts fading a later session's music is a bug, not
 * a feature.
 */
class SleepTimer(private val onFire: (fadeSeconds: Double) -> Unit) {

  companion object {
    /**
     * How long the music takes to disappear at the end. Long enough to be
     * gentle, short enough not to feel like a fault.
     */
    const val FADE_OUT_SECONDS: Double = 8.0
  }

  private val handler = Handler(Looper.getMainLooper())
  private var pending: Runnable? = null

  /** When the music will have finished fading. Null when nothing is scheduled. */
  var firesAtMillis: Long? = null
    private set

  val remainingSeconds: Double?
    get() = firesAtMillis?.let { maxOf(0.0, (it - System.currentTimeMillis()) / 1000.0) }

  fun schedule(afterSeconds: Double) {
    cancel()
    if (afterSeconds <= 0) return

    // Fire early by the fade length so the music has *finished* fading when the
    // requested time arrives, rather than starting to fade then. Asking for
    // twenty minutes and still hearing something at twenty-and-a-bit is the
    // wrong reading of the request.
    val fade = minOf(FADE_OUT_SECONDS, afterSeconds / 2)
    val delay = maxOf(0.1, afterSeconds - fade)

    firesAtMillis = System.currentTimeMillis() + (afterSeconds * 1000).toLong()
    val task = Runnable {
      firesAtMillis = null
      pending = null
      onFire(fade)
    }
    pending = task
    handler.postDelayed(task, (delay * 1000).toLong())
  }

  fun cancel() {
    pending?.let { handler.removeCallbacks(it) }
    pending = null
    firesAtMillis = null
  }
}
