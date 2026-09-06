import type { CrossfadeOptions, Track } from './types';

/**
 * How long the transition out of `current` into `next` should take. Zero is a
 * cut.
 *
 * **This function is the specification, not the implementation.** Nothing at
 * runtime calls it: the decision is made natively, because it has to happen
 * while the app is backgrounded and its JavaScript is suspended. It lives here
 * so the rules exist once in a form that can be executed and tested, and so
 * `ios/PlaybackQueue.swift` and `android/…/PlaybackQueue.kt` have something to
 * be correct *against* rather than being two hand-written copies that agree
 * only until someone edits one of them.
 *
 * That is not a hypothetical worry. This project exists partly because yuzic
 * had two server adapters that differed by a brand constant and had already
 * begun to drift; the fix there was one implementation plus a test asserting
 * the two surfaces match. Same disease here, and the same medicine: when a
 * conformance harness exists, it runs `transitionDuration.test.ts`'s table
 * against each platform. Until then, the table is at least reviewable.
 *
 * The four rules are fixed rather than configurable because each one is a bug,
 * not a preference, when it goes the other way. See docs/architecture.md §6.
 */
export function transitionDuration(
  current: Track | null,
  next: Track | null,
  crossfade: CrossfadeOptions | null,
  userInitiated: boolean
): number {
  if (!crossfade || crossfade.durationSec <= 0) return 0;
  if (!current || current.continuous) return 0;
  if (!next || next.continuous) return 0;

  // A skip should feel immediate. A fade is for a track that ended.
  if (userInitiated && (crossfade.skipIsImmediate ?? true)) return 0;

  // Mastered to run straight out of the previous track — fading doubles a seam
  // that was cut to butt exactly.
  if (crossfade.mode === 'gapless-aware' && next.followsPrevious) return 0;

  // An absent duration means "the host does not know yet", not "zero", so it
  // must not clamp the fade to nothing.
  const shortest = Math.min(
    current.durationSec ?? Number.POSITIVE_INFINITY,
    next.durationSec ?? Number.POSITIVE_INFINITY
  );
  if (!Number.isFinite(shortest)) return crossfade.durationSec;

  return Math.min(crossfade.durationSec, shortest / 2);
}
