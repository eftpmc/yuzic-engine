/**
 * The facade's platform-gap behaviour.
 *
 * Everything else here is exercised on a device; this is the one part whose
 * whole purpose is what happens when the native module is *missing* something,
 * which is easier to construct in a test than to reproduce on a phone.
 */

/** A native module with a deliberate hole in it, standing in for Android. */
const nativeStub: Record<string, unknown> = {
  play: jest.fn(async () => undefined),
  setBrowseTree: jest.fn(async () => undefined),
  addListener: jest.fn(() => ({ remove: jest.fn() })),
  // `setSpeed`, `getQueue`, `insertAt` and the rest are absent, exactly as
  // they are on Android today.
};

jest.mock('expo-modules-core', () => ({
  requireNativeModule: () => nativeStub,
}));

jest.mock('react-native', () => ({ Platform: { OS: 'android' } }));

import { YuzicEngine } from './YuzicEngine';

describe('the facade over a partial native module', () => {
  it('passes through methods the platform does implement', async () => {
    await YuzicEngine.play();
    expect(nativeStub.play).toHaveBeenCalled();
  });

  /**
   * The point of the whole exercise. Before this, an unimplemented method was
   * an absent property and calling it threw `X is not a function` — the same
   * message a typo or an unlinked module produces, which is why a real
   * platform gap read as a broken install.
   */
  it('rejects a method the platform lacks, naming the method and platform', async () => {
    await expect(YuzicEngine.setSpeed(2)).rejects.toThrow(
      /setSpeed\(\) is not implemented on android/
    );
  });

  it('says the interface has it, so the reader knows it is a gap not a typo', async () => {
    await expect(YuzicEngine.getQueue()).rejects.toThrow(/AudioEngine interface/);
  });

  /**
   * Asynchronous on purpose. Callers already handle a rejected promise from
   * every other method, and `createEngineBackend`'s queue edits run several
   * calls in sequence — a synchronous throw part-way through would abandon the
   * ones after it.
   */
  it('rejects rather than throwing synchronously', async () => {
    // The promise is captured rather than discarded: an unhandled rejection
    // takes the whole test run down, which is itself a small demonstration
    // that this rejects rather than throws.
    let pending: Promise<unknown> | undefined;
    expect(() => {
      pending = YuzicEngine.insertAt(0, []);
    }).not.toThrow();
    await expect(pending).rejects.toThrow(/insertAt/);
  });

  /** Not every absent property is a missing engine method. */
  it('leaves unknown properties alone', () => {
    expect((YuzicEngine as unknown as Record<string, unknown>).notAMethod).toBeUndefined();
  });
});
