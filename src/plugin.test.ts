// eslint-disable-next-line @typescript-eslint/no-require-imports
const plugin = require('../app.plugin.js');

/**
 * The config plugin's two transformations.
 *
 * Worth testing precisely because a wrong config plugin fails *silently*: the
 * app builds, runs, plays — and then stops the moment the screen locks. There
 * is no error anywhere, and every test that keeps the app in the foreground
 * passes.
 */
describe('config plugin', () => {
  describe('background audio', () => {
    it('adds the audio background mode', () => {
      const plist = plugin.addBackgroundAudio({});
      expect(plist.UIBackgroundModes).toEqual(['audio']);
    });

    it('keeps modes the app already declared', () => {
      // Clobbering an app's own list is how you break its push handling while
      // fixing its audio.
      const plist = plugin.addBackgroundAudio({ UIBackgroundModes: ['fetch', 'remote-notification'] });
      expect(plist.UIBackgroundModes).toEqual(['fetch', 'remote-notification', 'audio']);
    });

    it('is idempotent', () => {
      // Prebuild can run repeatedly over an existing plist.
      let plist = plugin.addBackgroundAudio({});
      plist = plugin.addBackgroundAudio(plist);
      expect(plist.UIBackgroundModes).toEqual(['audio']);
    });
  });

  describe('playback service', () => {
    const emptyManifest = () => ({ manifest: {} }) as any;
    const application = () => ({}) as any;

    it('declares the media-playback foreground service permission', () => {
      const manifest = plugin.addPlaybackService(emptyManifest(), application());
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      // Separate from FOREGROUND_SERVICE and required from API 34. Without it
      // the service throws on start, on the newest devices only.
      expect(names).toContain('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK');
      expect(names).toContain('android.permission.FOREGROUND_SERVICE');
    });

    it('registers the service as mediaPlayback', () => {
      const app = application();
      plugin.addPlaybackService(emptyManifest(), app);
      const service = app.service[0];
      expect(service.$['android:name']).toBe('dev.yuzic.engine.PlaybackService');
      expect(service.$['android:foregroundServiceType']).toBe('mediaPlayback');
    });

    it('advertises both the media3 and the legacy browser action', () => {
      const app = application();
      plugin.addPlaybackService(emptyManifest(), app);
      const actions = app.service[0]['intent-filter'][0].action.map((a: any) => a.$['android:name']);
      // Head units still resolve media browsers by the legacy action; dropping
      // it makes the app invisible in some cars while looking fine everywhere.
      expect(actions).toContain('androidx.media3.session.MediaLibraryService');
      expect(actions).toContain('android.media.browse.MediaBrowserService');
    });

    it('does not duplicate on a second run', () => {
      const manifest = emptyManifest();
      const app = application();
      plugin.addPlaybackService(manifest, app);
      plugin.addPlaybackService(manifest, app);
      expect(app.service).toHaveLength(1);
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      expect(new Set(names).size).toBe(names.length);
    });

    it('leaves permissions the app already declared alone', () => {
      const manifest = {
        manifest: { 'uses-permission': [{ $: { 'android:name': 'android.permission.CAMERA' } }] },
      } as any;
      plugin.addPlaybackService(manifest, application());
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      expect(names).toContain('android.permission.CAMERA');
    });
  });
});
