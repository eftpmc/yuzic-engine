import { requireNativeModule } from 'expo-modules-core';

import type { AudioEngine } from './AudioEngine';

/**
 * The native module, typed as the interface it implements.
 *
 * Nothing clever happens here on purpose. Every rule that could be enforced in
 * JavaScript is enforced natively instead — the crossfade clamps, the
 * gapless hard-cut, the sample-rate/crossfade exclusion — because JavaScript is
 * suspended in the background and a rule that only holds while the app is in
 * the foreground is not a rule.
 */
export const YuzicEngine = requireNativeModule<AudioEngine>('YuzicEngine');
