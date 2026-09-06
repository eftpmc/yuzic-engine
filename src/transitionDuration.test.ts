import { transitionDuration } from './transitionDuration';
import type { CrossfadeOptions, Track } from './types';

const song = (over: Partial<Track> = {}): Track => ({
  id: 't', uri: 'file:///t.flac', title: 'T', durationSec: 240, ...over,
});

const fade = (over: Partial<CrossfadeOptions> = {}): CrossfadeOptions => ({
  durationSec: 8, mode: 'gapless-aware', ...over,
});

/**
 * The conformance table. Both native implementations must agree with every row
 * here; when a harness exists to drive them, it runs exactly these cases.
 */
describe('transitionDuration', () => {
  it('fades for the configured time between two ordinary tracks', () => {
    expect(transitionDuration(song(), song(), fade(), false)).toBe(8);
  });

  it('cuts when crossfade is off or zero', () => {
    expect(transitionDuration(song(), song(), null, false)).toBe(0);
    expect(transitionDuration(song(), song(), fade({ durationSec: 0 }), false)).toBe(0);
  });

  describe('a stream with no end cannot fade', () => {
    it('not out of one', () => {
      expect(transitionDuration(song({ continuous: true }), song(), fade(), false)).toBe(0);
    });
    it('and not into one', () => {
      expect(transitionDuration(song(), song({ continuous: true }), fade(), false)).toBe(0);
    });
  });

  describe('a deliberate segue is a cut, not a fade', () => {
    it('hard-cuts into a track that follows the previous one', () => {
      expect(transitionDuration(song(), song({ followsPrevious: true }), fade(), false)).toBe(0);
    });

    it('but "always" mode fades even there, which is what it is for', () => {
      const always = fade({ mode: 'always' });
      expect(transitionDuration(song(), song({ followsPrevious: true }), always, false)).toBe(8);
    });
  });

  describe('a skip is immediate', () => {
    it('cuts when the user pressed next', () => {
      expect(transitionDuration(song(), song(), fade(), true)).toBe(0);
    });

    it('defaults to immediate when the host said nothing', () => {
      const { skipIsImmediate: _omitted, ...withoutFlag } = fade({ skipIsImmediate: true });
      expect(transitionDuration(song(), song(), withoutFlag as CrossfadeOptions, true)).toBe(0);
    });

    it('honours an explicit opt-out', () => {
      expect(transitionDuration(song(), song(), fade({ skipIsImmediate: false }), true)).toBe(8);
    });
  });

  describe('the fade is clamped to half the shorter track', () => {
    it('clamps against a short outgoing track', () => {
      expect(transitionDuration(song({ durationSec: 3 }), song(), fade(), false)).toBe(1.5);
    });

    it('clamps against a short incoming track', () => {
      expect(transitionDuration(song(), song({ durationSec: 10 }), fade(), false)).toBe(5);
    });

    it('does not lengthen a fade for long tracks', () => {
      expect(transitionDuration(song({ durationSec: 3600 }), song({ durationSec: 3600 }), fade(), false)).toBe(8);
    });
  });

  describe('an unknown duration is not a zero duration', () => {
    it('uses the full fade when neither length is known', () => {
      const unknown = song({ durationSec: undefined });
      expect(transitionDuration(unknown, unknown, fade(), false)).toBe(8);
    });

    it('still clamps against the length it does know', () => {
      expect(
        transitionDuration(song({ durationSec: undefined }), song({ durationSec: 4 }), fade(), false)
      ).toBe(2);
    });
  });

  it('cuts when there is nothing to fade into', () => {
    expect(transitionDuration(song(), null, fade(), false)).toBe(0);
  });
});
