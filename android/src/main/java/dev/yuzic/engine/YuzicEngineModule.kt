package dev.yuzic.engine

import android.content.ComponentName
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import com.google.common.util.concurrent.ListenableFuture
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

/**
 * The Expo module surface — the thin part. Everything of substance lives in
 * [AudioGraph], [PlaybackQueue] and [PlaybackService]; this file only translates.
 *
 * Expo Modules rather than Nitro because nothing high-frequency crosses this
 * bridge: audio never does, commands are rare, and progress is emitted about
 * once a second. What is large is the *integration* surface — background audio
 * mode, the CarPlay entitlement and scene, the Android foreground service and
 * notification channel — and that is config-plugin work, which is where the
 * Expo Modules API is markedly better. See docs/architecture.md.
 *
 * Function names, argument shapes and event names are the same strings as
 * `ios/YuzicEngineModule.swift`. They are the contract `src/AudioEngine.ts`
 * describes, and a divergence here is a platform-specific bug in the host, which
 * is the worst kind to find.
 */
@UnstableApi
class YuzicEngineModule : Module() {

  private val queue get() = PlaybackService.queue
  private var controllerFuture: ListenableFuture<MediaController>? = null

  override fun definition() = ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { options: SetupOptions? ->
      configureAudioSession(options?.pauseOnBecomingNoisy ?: true)
      PlaybackService.eventSink = { name, body -> sendEvent(name, body) }
    }

    AsyncFunction("teardown") {
      // The sink goes first. Between here and the service actually stopping,
      // the session may still fire — and sending an event into a JS context
      // that is being torn down is a crash rather than a no-op.
      PlaybackService.eventSink = null
      controllerFuture?.let { MediaController.releaseFuture(it) }
      controllerFuture = null
      TrackHeaders.clear()
    }

    // MARK: queue
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the notification still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { tracks: List<TrackRecord>, startIndex: Int? ->
      queue.set(tracks, startIndex ?: 0)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      pushQueueToPlayer()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    AsyncFunction("append") { tracks: List<TrackRecord> ->
      queue.append(tracks)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      pushQueueToPlayer()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    AsyncFunction("getActiveIndex") {
      queue.activeIndex
    }

    // MARK: transport
    //
    // Everything here goes through the *active voice's* ExoPlayer, which is
    // holding the whole queue — see `pushQueueToPlayer`. So skipping and seeking
    // are Media3's own timeline operations rather than anything this engine has
    // to arrange, which is the half of §1's bill Android does not have to pay.
    //
    // All of it via `onPlayer`, because a player may only be touched on the
    // thread that built it and an `AsyncFunction` body is not that thread.

    AsyncFunction("play") { onPlayer { it.play() } }
    AsyncFunction("pause") { onPlayer { it.pause() } }
    AsyncFunction("stop") { onPlayer { it.stop() } }

    AsyncFunction("seekTo") { positionSec: Double ->
      onPlayer { it.seekTo((positionSec * 1000).toLong()) }
    }

    AsyncFunction("skipToNext") {
      onPlayer {
        it.seekToNextMediaItem()
        syncActiveIndexFrom(it)
      }
    }

    AsyncFunction("skipToPrevious") {
      // Media3's own "previous" rewinds to the head of the current track first
      // when far enough in, which is the platform convention and what the car's
      // button is expected to do. Deliberately not overridden to always change
      // track: that would be this engine disagreeing with every other player on
      // the device.
      onPlayer {
        it.seekToPreviousMediaItem()
        syncActiveIndexFrom(it)
      }
    }

    AsyncFunction("skipToIndex") { index: Int ->
      onPlayer {
        if (index in queue.tracks.indices) {
          it.seekTo(index, 0L)
          syncActiveIndexFrom(it)
        }
      }
    }

    /**
     * The user's volume, which is not the fade and not the track's own gain.
     *
     * Written to [ExoPlayer.setVolume] on *both* voices. Both, because during a
     * crossfade two players are producing audio and setting one would make the
     * change audible as a lurch halfway through the fade. The fade itself rides
     * on `FadeAudioProcessor`, so this cannot fight it — which is the separation
     * [AudioGraph.Voice] exists to keep.
     */
    AsyncFunction("setVolume") { volume: Double ->
      val clamped = volume.coerceIn(0.0, 1.0).toFloat()
      onMain {
        PlaybackService.graph?.let {
          it.voiceA.player.volume = clamped
          it.voiceB.player.volume = clamped
        }
      }
    }

    // MARK: reading the state, rather than waiting to be told

    AsyncFunction("getState") { readPlayer("idle") { stateName(it) } }

    /**
     * Asked rather than waited for — the same reason as iOS. A screen mounting
     * mid-track would otherwise show zero until the next tick.
     */
    AsyncFunction("getProgress") {
      readPlayer(mapOf("positionSec" to 0.0, "durationSec" to 0.0, "bufferedSec" to 0.0)) {
        mapOf(
          "positionSec" to it.currentPosition.coerceAtLeast(0) / 1000.0,
          // Media3 says TIME_UNSET for a duration it does not know yet, and for
          // a live stream. The contract says 0 there, not a negative sentinel
          // leaking into a progress bar.
          "durationSec" to it.duration.let { ms -> if (ms == androidx.media3.common.C.TIME_UNSET) 0.0 else ms / 1000.0 },
          // Buffered is reported from the current position, not from zero,
          // because what a buffering indicator means is "how much runway is
          // left" — see Progress.bufferedSec in src/types.ts.
          "bufferedSec" to ((it.bufferedPosition - it.currentPosition).coerceAtLeast(0)) / 1000.0,
        )
      }
    }

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { bands: List<EqBandRecord> ->
      PlaybackService.graph?.setEqualizer(
        bands.map {
          AudioGraph.Band(
            frequencyHz = it.frequencyHz.toFloat(),
            gainDb = it.gainDb.toFloat(),
            q = (it.q ?: 1.0).toFloat(),
          )
        }
      )
    }

    AsyncFunction("setCrossfade") { options: CrossfadeRecord? ->
      queue.crossfade = options
    }

    AsyncFunction("setSampleRateMode") { mode: String ->
      // Enforced rather than merely recorded: overlapping sources have to share
      // a rate, so matching the source and crossfading are mutually exclusive.
      // The engine resolves the contradiction instead of leaving two settings
      // to fight, and tells the host it did.
      //
      // Android reaches the same conclusion by a different route than iOS. There
      // is no `setPreferredSampleRate` here, so nothing stops the engine
      // mechanically — but honouring the source rate means letting one
      // AudioTrack dictate the output configuration, and the second voice would
      // be resampled into it silently, which is exactly the thing the mode is
      // asked for to avoid. Refusing is more honest than pretending.
      if (mode == "match-source" && queue.crossfade != null) {
        queue.crossfade = null
        sendEvent(
          "onError",
          mapOf(
            "code" to "CROSSFADE_DISABLED",
            "message" to "Crossfade turned off: matching the source sample rate cannot overlap two tracks.",
          ),
        )
      }
      queue.sampleRateMode = mode
    }

    // MARK: platform surfaces
    //
    // These two have no counterpart in ios/YuzicEngineModule.swift yet — it is a
    // partial file and stops before them. They are declared here anyway because
    // [PlaybackService] has no other way to be handed a browse tree, and a
    // MediaLibraryService with no root is invisible in the car. Names and
    // argument shapes are taken from `src/AudioEngine.ts` so that the iOS
    // implementations, when they land, have nothing to negotiate.

    AsyncFunction("setBrowseTree") { root: BrowseNodeRecord ->
      PlaybackService.browseRoot = root
    }

    AsyncFunction("clearBrowseTree") {
      PlaybackService.browseRoot = null
    }

    AsyncFunction("setCommands") { commands: List<String> ->
      PlaybackService.enabledCommands = commands.toSet()
      // Deliberately not re-issued to already-connected controllers. Media3 asks
      // for the command set once, at connect; a car that is already connected
      // keeps the set it was given until it reconnects. Forcing a reconnect to
      // apply a new set would drop the notification mid-track, which is a worse
      // trade than a stale button.
    }
  }

  // MARK: - Reaching the player
  //
  // ExoPlayer checks the calling thread on every method and throws if it is not
  // the one the player was built on. That is the service's main thread, because
  // `PlaybackService.onCreate` is where the graph is made. An Expo
  // `AsyncFunction` body runs on a background dispatcher, so *every* call has to
  // hop — there is no such thing as a cheap read here.

  private val main = Handler(Looper.getMainLooper())

  /** Fire-and-forget onto the active voice. Does nothing before `setup`. */
  private fun onPlayer(block: (ExoPlayer) -> Unit) {
    onMain { PlaybackService.graph?.activeVoice?.player?.let(block) }
  }

  private fun onMain(block: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
  }

  /**
   * Read something off the player and wait for it.
   *
   * Blocking, which is why it is only used by the two imperative getters and
   * never on a path that runs per frame. The timeout is not a nicety: if the
   * main thread is wedged, returning the default late is survivable and
   * deadlocking the JS call is not.
   */
  private fun <T> readPlayer(fallback: T, block: (ExoPlayer) -> T): T {
    val player = PlaybackService.graph?.activeVoice?.player ?: return fallback
    if (Looper.myLooper() == Looper.getMainLooper()) return block(player)

    var result = fallback
    val done = CountDownLatch(1)
    main.post {
      try {
        result = block(player)
      } finally {
        done.countDown()
      }
    }
    done.await(1, TimeUnit.SECONDS)
    return result
  }

  /**
   * Media3's playback state, in the vocabulary `PlaybackState` in src/types.ts
   * uses.
   *
   * `READY` splits on `playWhenReady`, because Media3 calls a paused track ready
   * and the host's word for that is "paused". Collapsing the two is how a play
   * button ends up showing the wrong glyph.
   */
  private fun stateName(player: ExoPlayer): String = when (player.playbackState) {
    Player.STATE_IDLE -> "idle"
    Player.STATE_BUFFERING -> "buffering"
    Player.STATE_READY -> if (player.playWhenReady) "playing" else "paused"
    Player.STATE_ENDED -> "ended"
    else -> "idle"
  }

  /**
   * Keep [PlaybackQueue.activeIndex] level with the player after a skip.
   *
   * The queue is the thing `getActiveIndex` answers from and the thing the
   * transition rules read, but Media3 owns the timeline and moves the playhead
   * itself. Without this the two disagree the moment anyone presses next, and
   * the crossfade rules start reasoning about the wrong pair of tracks.
   */
  private fun syncActiveIndexFrom(player: ExoPlayer) {
    val index = player.currentMediaItemIndex
    if (index in queue.tracks.indices && index != queue.activeIndex) {
      queue.set(queue.tracks, index)
    }
  }

  /**
   * The Android counterpart to claiming the audio session.
   *
   * There is no session to claim — focus is requested per playback by the
   * `AudioAttributes` the service sets — so what this actually does is start
   * the service. Connecting a `MediaController` is the sanctioned way: it binds
   * the service, which is what makes it survivable, and Media3 promotes it to
   * the foreground itself once something is playing. Calling
   * `startForegroundService` directly instead is the usual route to an
   * `ForegroundServiceDidNotStartInTimeException`.
   *
   * `pauseOnBecomingNoisy` is honoured on the players rather than here; it is
   * passed down so the two platforms take the same argument even though Android
   * spends it in a different place.
   */
  private fun configureAudioSession(pauseOnBecomingNoisy: Boolean) {
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
    PlaybackService.graph?.let { graph ->
      graph.voiceA.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
      graph.voiceB.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
    }

    // Idempotent, as the contract in src/AudioEngine.ts requires: a second call
    // reconfigures rather than restarting, because tearing the session down
    // mid-playback is audible.
    if (controllerFuture != null) return

    val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
    controllerFuture = MediaController.Builder(context, token).buildAsync()
  }

  /**
   * Hand the queue to the foreground voice.
   *
   * Only the foreground one. The idle voice is loaded with a single item during
   * the preload window and exists to overlap, so giving it the whole timeline
   * would have it advancing through the queue in parallel — two playheads on the
   * same list, which is not what the pair is for.
   */
  private fun pushQueueToPlayer() {
    val graph = PlaybackService.graph ?: return
    val player = graph.activeVoice.player
    player.setMediaItems(queue.tracks.map { it.toMediaItem() }, queue.activeIndex, 0L)
    player.prepare()
  }
}

// MARK: - Records
//
// Shapes crossing the bridge. Kept flat and optional-tolerant: a host that
// omits a field means "no information", which is not the same as a zero — the
// replay-gain pair is exactly that distinction.
//
// These mirror the `Record` structs at the bottom of ios/YuzicEngineModule.swift
// field for field. Where Swift can say `Double?` and mean absent, Kotlin says
// `Double?` too, and neither is allowed to quietly default to 0.

class SetupOptions : Record {
  @Field var progressIntervalMs: Int = 1000
  @Field var pauseOnBecomingNoisy: Boolean = true
}

class TrackRecord : Record {
  @Field var id: String = ""
  @Field var uri: String = ""
  @Field var title: String = ""
  @Field var artist: String? = null
  @Field var album: String? = null
  @Field var artworkUri: String? = null
  @Field var durationSec: Double? = null
  @Field var headers: Map<String, String>? = null
  @Field var followsPrevious: Boolean = false
  @Field var replayGainDb: Double? = null
  @Field var replayGainPeak: Double? = null
  @Field var continuous: Boolean = false
}

class EqBandRecord : Record {
  @Field var frequencyHz: Double = 0.0
  @Field var gainDb: Double = 0.0
  @Field var q: Double? = null
}

class CrossfadeRecord : Record {
  @Field var durationSec: Double = 0.0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Boolean = true
}

/**
 * A node of the browse tree. Recursive, which Expo's record converter handles,
 * and which the iOS side does not yet declare — the tree arrives whole either
 * way, so the shape is dictated by `BrowseNode` in src/types.ts rather than by
 * either platform.
 */
class BrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  @Field var children: List<BrowseNodeRecord>? = null
  @Field var playable: TrackRecord? = null
}

/**
 * A track as Media3 sees it.
 *
 * The cache key is the host's `MediaId`, not the URI. Subsonic and Jellyfin both
 * hand out URLs carrying a token that rotates, so keying the cache on the URI
 * would re-download the same audio every session and the LRU would fill with
 * duplicates of one album.
 */
@UnstableApi
fun TrackRecord.toMediaItem(): MediaItem = MediaItem.Builder()
  .setMediaId(id)
  .setUri(Uri.parse(uri))
  .setCustomCacheKey(id)
  .setMediaMetadata(
    MediaMetadata.Builder()
      .setTitle(title)
      .setArtist(artist)
      .setAlbumTitle(album)
      .setArtworkUri(artworkUri?.let { Uri.parse(it) })
      .setIsBrowsable(false)
      .setIsPlayable(true)
      .build()
  )
  .build()
