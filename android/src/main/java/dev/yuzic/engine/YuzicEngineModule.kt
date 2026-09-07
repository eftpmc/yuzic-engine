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
      // Honoured, unlike on iOS, which declares the same field and then ticks
      // at a hardcoded 250ms regardless. Worth not copying: the host asked.
      progressIntervalMs = (options?.progressIntervalMs ?: 1000).coerceAtLeast(100).toLong()
      onMain { startObserving() }
    }

    AsyncFunction("teardown") {
      // The sink goes first. Between here and the service actually stopping,
      // the session may still fire — and sending an event into a JS context
      // that is being torn down is a crash rather than a no-op.
      PlaybackService.eventSink = null
      onMain { stopObserving() }
      sleepTimer.cancel()
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

    // MARK: queue editing
    //
    // The queue object keeps the index rule (see PlaybackQueue), and the player
    // is edited through Media3's own timeline operations rather than by pushing
    // the whole queue again. That difference is the whole point: `setMediaItems`
    // restarts the current item from zero, so re-pushing on every edit would
    // restart the song whenever anything else in the list moved.

    AsyncFunction("insertAt") { index: Int, tracks: List<TrackRecord> ->
      if (tracks.isNotEmpty()) {
        val at = index.coerceIn(0, queue.tracks.size)
        queue.insert(tracks, at)
        tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
        onMain {
          PlaybackService.graph?.activeVoice?.player
            ?.addMediaItems(at, tracks.map { it.toMediaItem() })
        }
        sendEvent("onQueueChange", emptyMap<String, Any?>())
      }
    }

    AsyncFunction("removeAt") { index: Int ->
      if (index in queue.tracks.indices) {
        queue.remove(index)
        onMain { PlaybackService.graph?.activeVoice?.player?.removeMediaItem(index) }
        sendEvent("onQueueChange", emptyMap<String, Any?>())
      }
    }

    AsyncFunction("move") { from: Int, to: Int ->
      if (from in queue.tracks.indices) {
        val destination = to.coerceIn(0, queue.tracks.size - 1)
        if (from != destination) {
          queue.move(from, destination)
          onMain { PlaybackService.graph?.activeVoice?.player?.moveMediaItem(from, destination) }
          sendEvent("onQueueChange", emptyMap<String, Any?>())
        }
      }
    }

    AsyncFunction("clearQueue") {
      queue.clear()
      onMain { PlaybackService.graph?.activeVoice?.player?.clearMediaItems() }
      TrackHeaders.clear()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    // The only call that sends tracks *back* across the bridge, which is why it
    // is a device probe rather than a unit test: a declared shape that
    // typechecks and then throws at runtime is this module's recorded history.
    AsyncFunction("getQueue") {
      queue.tracks.map { it.toMap() }
    }

    AsyncFunction("setRepeatMode") { mode: String ->
      queue.repeatMode = mode
      // Media3 owns the timeline, so repeat is its decision to make rather than
      // something this module arranges by hand. The queue keeps its own copy
      // because `nextTrack` — and therefore the crossfade — has to agree.
      val media3 = when (mode) {
        "one" -> Player.REPEAT_MODE_ONE
        "all" -> Player.REPEAT_MODE_ALL
        else -> Player.REPEAT_MODE_OFF
      }
      onMain {
        PlaybackService.graph?.let { graph ->
          graph.voiceA.player.repeatMode = media3
          graph.voiceB.player.repeatMode = media3
        }
      }
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

    // Both voices, for the same reason the equalizer sets both: during a
    // crossfade the pair is audible together, and a speed applied to one of
    // them would be heard as the two drifting apart.
    AsyncFunction("setSpeed") { speed: Double ->
      val rate = speed.coerceIn(0.25, 4.0).toFloat()
      onMain {
        PlaybackService.graph?.let { graph ->
          graph.voiceA.player.setPlaybackSpeed(rate)
          graph.voiceB.player.setPlaybackSpeed(rate)
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
      userVolume = volume.coerceIn(0.0, 1.0).toFloat()
      onMain { applyVolume() }
    }

    // MARK: sleep timer

    AsyncFunction("sleepAfter") { seconds: Double -> sleepTimer.schedule(seconds) }
    AsyncFunction("cancelSleep") { sleepTimer.cancel() }

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
          // Absolute, on the same timeline as the position — matching iOS, and
          // for the reason it gives: a buffering bar is drawn against the same
          // scale as the progress bar. Media3's `bufferedPosition` is already
          // absolute, so this is the raw figure rather than a difference.
          "bufferedSec" to it.bufferedPosition.coerceAtLeast(0) / 1000.0,
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

    /**
     * Loudness normalisation, from the host's tags.
     *
     * Folded into the player's volume together with the user's setting, because
     * both are static multipliers and there is only one channel free — the fade
     * processor is the crossfade's and must stay that way. Recomputed on the
     * active track whenever either half changes.
     */
    AsyncFunction("setReplayGain") { options: ReplayGainRecord ->
      replayGain = ReplayGainSettings(
        mode = ReplayGainMode.from(options.mode),
        preampDb = options.preampDb,
        untaggedPreampDb = options.untaggedPreampDb,
        preventClipping = options.preventClipping,
      )
      onMain { applyVolume() }
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

    /**
     * Take the tree the way the bridge actually sends it.
     *
     * `(title, flatNodes)`, not one nested record: an Expo `Record` cannot
     * contain itself, so `src/browseTree.ts` flattens to a list with parent
     * references and the native side rebuilds. This declared the nested shape
     * and would have thrown on the first call — the arity alone is wrong.
     *
     * Worth noting how it survived: the two platforms were compared by
     * function *name*, and the names matched. Signatures are the other half.
     */
    AsyncFunction("setBrowseTree") { title: String, nodes: List<FlatBrowseNodeRecord> ->
      PlaybackService.browseRoot = buildBrowseTree(title, nodes)
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

  /** The same cap iOS uses, for the same reason: a bad parent id must not recurse forever. */
  private val BROWSE_MAX_DEPTH = 16

  private val main = Handler(Looper.getMainLooper())

  /**
   * The two static multipliers that share `ExoPlayer.volume`.
   *
   * Held here rather than read back off the player, because the product of the
   * pair is what the player stores — asking it for the volume would give the
   * product and there would be no way to change one without inventing the
   * other.
   */
  private var userVolume: Float = 1.0f
  private var replayGain: ReplayGainSettings = ReplayGainSettings.OFF

  /**
   * Fade the music out, then pause — not the other way round, and not a cut.
   *
   * Music stopping mid-bar is the thing that wakes people, which defeats the
   * whole feature. The pause is scheduled for the end of the fade rather than
   * chained to a completion callback because `FadeAudioProcessor` has none: it
   * ramps in the audio thread and nothing tells anyone when it arrives.
   */
  private val sleepTimer = SleepTimer { fadeSeconds ->
    val graph = PlaybackService.graph ?: return@SleepTimer
    // Linear, explicitly: this is one voice going to silence with nothing to
    // sum against, so equal power would hold it near full volume for half the
    // fade and then drop it. Sleep is the case that curve is worst for.
    graph.ramp(graph.activeVoice, 0f, fadeSeconds, AudioGraph.FadeCurve.LINEAR)
    main.postDelayed({
      graph.activeVoice.player.pause()
      // Put the fade back where it was found. Without this, pressing play the
      // next morning starts a track at zero gain and looks like a dead player
      // — the same bug the iOS engine calls out at PlaybackEngine.swift:163.
      graph.ramp(graph.activeVoice, 1f, 0.0, AudioGraph.FadeCurve.LINEAR)
    }, (fadeSeconds * 1000).toLong())
  }

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
  /**
   * Rebuild the nested tree from the flat list, mirroring `BrowseTree.build`
   * in `ios/Core/BrowseTree.swift` rule for rule.
   *
   * The rules are the ones architecture.md §11 states, and each is a decision
   * rather than a detail:
   *
   * - **Duplicate ids keep the first.** Selection resolves by id, so the
   *   alternative is a car playing something other than what it displayed.
   * - **Orphans are dropped, not promoted.** A half-loaded library should show
   *   less, not show a flat pile of tracks where albums were expected. Falling
   *   out of the grouping rather than being handled: a node whose parent is
   *   not in `childrenByParent` is simply never assembled.
   * - **Depth is capped**, at the same 16 as iOS, so a tree that references
   *   itself through a bad parent id cannot recurse forever.
   */
  private fun buildBrowseTree(title: String, flat: List<FlatBrowseNodeRecord>): BrowseNodeRecord {
    val seen = mutableSetOf<String>()
    val childrenByParent = mutableMapOf<String, MutableList<FlatBrowseNodeRecord>>()
    val roots = mutableListOf<FlatBrowseNodeRecord>()

    for (node in flat) {
      if (!seen.add(node.id)) continue
      val parentId = node.parentId
      if (parentId != null) {
        childrenByParent.getOrPut(parentId) { mutableListOf() }.add(node)
      } else {
        roots.add(node)
      }
    }

    fun assemble(node: FlatBrowseNodeRecord, depth: Int): BrowseNodeRecord =
      BrowseNodeRecord().apply {
        id = node.id
        // Qualified: the enclosing function's `title` parameter is nearer in
        // scope than this record's field, and is a val.
        this.title = node.title
        subtitle = node.subtitle
        artworkUri = node.artworkUri
        playable = node.playable
        children = if (depth >= BROWSE_MAX_DEPTH) emptyList()
        else childrenByParent[node.id].orEmpty().map { assemble(it, depth + 1) }
      }

    return BrowseNodeRecord().apply {
      id = "root"
      this.title = title
      children = roots.map { assemble(it, 1) }
    }
  }

  // MARK: - Telling the host what happened
  //
  // Until this existed, `onProgress`, `onStateChange` and `onTrackChange` were
  // declared in `Events(...)` and emitted by nothing, so a host on Android
  // could ask where it was and never be told. The three come from two places:
  // Media3 pushes state and track transitions, and position has to be polled
  // because no player anywhere reports it continuously.

  private var progressIntervalMs: Long = 1000
  private var lastState: String? = null
  /**
   * How long the current track has actually been audible.
   *
   * Two values rather than a start time, for the same two reasons the iOS
   * engine keeps them (`PlaybackEngine.listenedAccumulated`): a start time
   * measures wall clock, and a paused player is not listening. This figure is
   * `previousListenedSec`, which hosts judge scrobble thresholds against, so
   * counting a pause submits plays to Last.fm and ListenBrainz for music
   * nobody heard.
   *
   * `listeningSinceMillis` is 0 while nothing is audible.
   */
  private var listenedAccumulatedMillis: Long = 0
  private var listeningSinceMillis: Long = 0
  private var observing = false

  private val ticker = object : Runnable {
    override fun run() {
      emitProgress()
      main.postDelayed(this, progressIntervalMs)
    }
  }

  private val playerListener = object : Player.Listener {
    override fun onPlaybackStateChanged(state: Int) = emitStateIfChanged()

    /**
     * Open or close the listening stretch as audio starts and stops.
     *
     * Asks whether *any* voice is playing rather than trusting this callback's
     * own argument, because this listener is attached to both. During a
     * crossfade the pair overlaps, and the outgoing voice reporting `false` at
     * the end of a fade does not mean the listener stopped hearing anything —
     * taking it at face value would stop the clock while the incoming track
     * plays on.
     */
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      if (anyVoicePlaying()) openListeningStretch() else closeListeningStretch()
      emitStateIfChanged()
    }
    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = emitStateIfChanged()

    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
      // A queue being loaded is not a track change. Media3 fires this with
      // PLAYLIST_CHANGED when `setMediaItems` first takes a queue, so without
      // this every `setQueue` announces a change to index 0 carrying a
      // `previousListenedSec` measured from a track nobody played.
      //
      // `_SEEK` is deliberately left alone. A seek across an item boundary
      // does change the item, so callers that track "what is playing" need it;
      // it is not an *advance*, so `previousListenedSec` means something
      // different there. Suppressing it would be a second bug rather than a
      // fix for this one.
      if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED) return
      val player = PlaybackService.graph?.activeVoice?.player ?: return
      syncActiveIndexFrom(player)
      // Before the payload is built, because the new track's loudness has to be
      // right from its first sample rather than corrected once it is audible.
      applyVolume()

      val listened = listenedSeconds()
      resetListened()

      val payload = mutableMapOf<String, Any?>("index" to player.currentMediaItemIndex)
      mediaItem?.mediaId?.let { payload["id"] = it }
      listened?.let { payload["previousListenedSec"] = it }
      sendEvent("onTrackChange", payload)
    }

    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
      sendEvent(
        "onError",
        mapOf(
          "code" to "PLAYBACK_FAILED",
          "message" to (error.message ?: error.errorCodeName),
        ),
      )
    }
  }

  /** Main thread only — both the listener and the ticker touch the player. */
  private fun startObserving() {
    if (observing) return
    val graph = PlaybackService.graph ?: return
    // Both voices, because during a crossfade the one that matters changes
    // halfway through and a listener on only the foreground player would go
    // quiet for the second half of every transition.
    graph.voiceA.player.addListener(playerListener)
    graph.voiceB.player.addListener(playerListener)
    observing = true
    // Deliberately *not* started here. This used to set the origin at setup,
    // so the first track change reported the time since the engine was set up
    // rather than the time anyone spent listening — two runs of the same
    // scenario reported 15.3s and 33.8s, which varied with how long the tester
    // took to press play. The clock starts when audio does, in
    // `onIsPlayingChanged`.
    resetListened()
    main.postDelayed(ticker, progressIntervalMs)
  }

  /** True while either voice is producing audio. Main thread only. */
  private fun anyVoicePlaying(): Boolean {
    val graph = PlaybackService.graph ?: return false
    return graph.voiceA.player.isPlaying || graph.voiceB.player.isPlaying
  }

  /** Start counting. Idempotent, so an already-open stretch is not restarted. */
  private fun openListeningStretch() {
    if (listeningSinceMillis == 0L) listeningSinceMillis = System.currentTimeMillis()
  }

  /** Bank the open stretch. Idempotent, so a second pause cannot count it twice. */
  private fun closeListeningStretch() {
    if (listeningSinceMillis == 0L) return
    listenedAccumulatedMillis += System.currentTimeMillis() - listeningSinceMillis
    listeningSinceMillis = 0L
  }

  /**
   * Played seconds for the track that is ending, or null if it never played.
   *
   * Null rather than zero: a host cannot tell a track nobody heard from one
   * heard for under half a second if both arrive as 0.0, and only one of those
   * should ever be considered for a scrobble.
   */
  private fun listenedSeconds(): Double? {
    val open = if (listeningSinceMillis > 0) System.currentTimeMillis() - listeningSinceMillis else 0L
    val total = listenedAccumulatedMillis + open
    return if (total > 0) total / 1000.0 else null
  }

  /** Zero the count for a new track, keeping the clock running if audio is. */
  private fun resetListened() {
    listenedAccumulatedMillis = 0
    listeningSinceMillis = if (anyVoicePlaying()) System.currentTimeMillis() else 0L
  }

  private fun stopObserving() {
    val graph = PlaybackService.graph
    graph?.voiceA?.player?.removeListener(playerListener)
    graph?.voiceB?.player?.removeListener(playerListener)
    main.removeCallbacks(ticker)
    observing = false
    lastState = null
  }

  /**
   * Only on an actual change, matching the iOS engine, where `state` emits from
   * a `didSet` guarded on inequality. Media3 fires its callbacks more often
   * than the state changes — `onPlayWhenReadyChanged` alone repeats for every
   * pause reason — and a host re-rendering on each one is a cost it did not ask
   * for.
   */
  private fun emitStateIfChanged() {
    val player = PlaybackService.graph?.activeVoice?.player ?: return
    val state = stateName(player)
    if (state == lastState) return
    lastState = state
    sendEvent("onStateChange", mapOf("state" to state))
  }

  private fun emitProgress() {
    val player = PlaybackService.graph?.activeVoice?.player ?: return
    val duration = player.duration
    sendEvent(
      "onProgress",
      mapOf(
        "positionSec" to player.currentPosition.coerceAtLeast(0) / 1000.0,
        "durationSec" to if (duration == androidx.media3.common.C.TIME_UNSET) 0.0 else duration / 1000.0,
        // Absolute, as in `getProgress` and on iOS — see Progress.bufferedSec.
        "bufferedSec" to player.bufferedPosition.coerceAtLeast(0) / 1000.0,
      ),
    )
  }

  /**
   * Push `user volume × the active track's replay gain` to both players.
   *
   * Both, because during a crossfade two of them are audible and leaving one
   * behind makes the change lurch halfway through the fade. Main thread only.
   */
  private fun applyVolume() {
    val graph = PlaybackService.graph ?: return
    val track = queue.activeTrack
    val gain = if (track == null) 1.0f else ReplayGain.linearGain(track, replayGain)
    val level = userVolume * gain
    graph.voiceA.player.volume = level
    graph.voiceB.player.volume = level
  }

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

    // `onMain`, like every other player touch — this is the rule stated in the
    // transport section above, and these four lines were the one place that
    // broke it.
    //
    // It survived because of *when* it fails. On the first `setup()` of a
    // process the service does not exist yet (it is started by the
    // `buildAsync` below), so `graph` is null, the block is skipped, and
    // nothing is touched from the wrong thread. Every call after that finds a
    // graph and throws `Player is accessed on the wrong thread` — which broke
    // the idempotency the comment below promises, and meant only the first
    // probe of an app launch could run.
    onMain {
      PlaybackService.graph?.let { graph ->
        graph.voiceA.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
        graph.voiceB.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
      }
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
  private fun pushQueueToPlayer() = onMain {
    val graph = PlaybackService.graph ?: return@onMain
    val player = graph.activeVoice.player
    player.setMediaItems(queue.tracks.map { it.toMediaItem() }, queue.activeIndex, 0L)
    player.prepare()
    // The active track changed, so its replay gain did too. Set before anything
    // is audible rather than after: a track arriving at the wrong loudness and
    // being corrected a moment later is exactly what the feature is meant to
    // prevent.
    applyVolume()
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

/**
 * One node on the way across the bridge, as `FlatBrowseNode` in
 * `src/browseTree.ts` sends it.
 *
 * Flat because an Expo `Record` cannot contain itself — `@Field` has no way to
 * describe recursion — so the tree travels as a list with parent references
 * and is rebuilt on this side. A bridge artifact, not a shape anyone designs
 * against.
 */
class FlatBrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var parentId: String? = null
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  @Field var playable: TrackRecord? = null
}

class ReplayGainRecord : Record {
  @Field var mode: String = "off"
  @Field var preampDb: Double = 0.0
  @Field var untaggedPreampDb: Double = 0.0
  @Field var preventClipping: Boolean = true
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
 * The shape `getQueue` sends back to JS.
 *
 * Built by hand rather than returning the `Record`, because what crosses here
 * has to match `Track` in `src/types.ts` exactly — the host reads these back
 * after every edit — and an omitted field is a silent null on the other side
 * rather than a compile error on this one. Nulls are kept rather than dropped
 * so the absent fields are visible in the payload.
 */
fun TrackRecord.toMap(): Map<String, Any?> = mapOf(
  "id" to id, "uri" to uri, "title" to title, "artist" to artist,
  "album" to album, "artworkUri" to artworkUri, "durationSec" to durationSec,
  "headers" to headers, "followsPrevious" to followsPrevious,
  "replayGainDb" to replayGainDb, "replayGainPeak" to replayGainPeak,
  "continuous" to continuous,
)

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
