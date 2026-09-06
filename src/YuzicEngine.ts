import { requireNativeModule } from 'expo-modules-core';

import type { AudioEngine } from './AudioEngine';
import { flattenBrowseTree } from './browseTree';
import type { BrowseNode, EngineEvent, PlaybackState, Progress, MediaId } from './types';

/**
 * The native module, plus the one thing that cannot be a straight pass-through.
 *
 * Expo's event emitter is **name-based** — `addListener('onProgress', fn)`,
 * one subscription per event — while `AudioEngine.addListener` takes a single
 * listener and a discriminated union. That union is the better API for a
 * consumer: one subscription, one exhaustive switch, no chance of forgetting
 * that `onError` exists. But it is not what the runtime does, and declaring it
 * over `requireNativeModule` was simply a lie about the shape — it typechecked
 * and then threw "Value is a function, expected a String" the first time
 * anything subscribed.
 *
 * `setBrowseTree` is the other one, for a duller reason: the tree cannot cross
 * as a tree, so it is flattened here rather than making every host do it.
 *
 * So the union is assembled here, over the six named events the module
 * declares. If a name is added natively it must be added to `EVENTS` too;
 * that duplication is the price of the nicer surface, and it is small and
 * visible rather than spread across call sites.
 */

type NativeModule = Omit<AudioEngine, 'addListener' | 'setBrowseTree'> & {
  addListener(name: string, listener: (payload: any) => void): { remove(): void };
  setBrowseTree(title: string, nodes: ReturnType<typeof flattenBrowseTree>): Promise<void>;
};

const native = requireNativeModule<NativeModule>('YuzicEngine');

const EVENTS = [
  'onStateChange',
  'onTrackChange',
  'onProgress',
  'onQueueChange',
  'onError',
  'onRemoteCommand',
] as const;

function toEvent(name: (typeof EVENTS)[number], payload: any): EngineEvent | null {
  switch (name) {
    case 'onStateChange':
      return { type: 'stateChange', state: payload.state as PlaybackState };
    case 'onTrackChange':
      return {
        type: 'trackChange',
        index: payload.index as number,
        id: (payload.id ?? null) as MediaId | null,
        previousListenedSec: payload.previousListenedSec as number | undefined,
      };
    case 'onProgress':
      return {
        type: 'progress',
        progress: {
          positionSec: payload.positionSec,
          durationSec: payload.durationSec,
          bufferedSec: payload.bufferedSec ?? 0,
        } as Progress,
      };
    case 'onQueueChange':
      return { type: 'queueChange' };
    case 'onError':
      return { type: 'error', code: payload.code, message: payload.message, id: payload.id };
    case 'onRemoteCommand':
      return { type: 'remoteCommand', command: payload.command, payload: payload.payload };
    default:
      return null;
  }
}

export const YuzicEngine: AudioEngine = Object.assign(Object.create(native), {
  setBrowseTree(root: BrowseNode): Promise<void> {
    return native.setBrowseTree(root.title, flattenBrowseTree(root));
  },

  addListener(listener: (event: EngineEvent) => void): () => void {
    const subscriptions = EVENTS.map(name =>
      native.addListener(name, (payload: any) => {
        const event = toEvent(name, payload ?? {});
        if (event) listener(event);
      })
    );
    return () => subscriptions.forEach(subscription => subscription.remove());
  },
}) as AudioEngine;
