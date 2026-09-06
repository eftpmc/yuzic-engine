const {
  withInfoPlist,
  withAndroidManifest,
  AndroidConfig,
} = require('@expo/config-plugins');

/**
 * Expo config plugin for yuzic-engine.
 *
 * Everything here is native configuration the engine cannot grant itself. An
 * audio app that does not declare these does not fail loudly — it plays fine
 * until the screen locks, and then stops. That is the worst kind of missing
 * config: invisible in every test that keeps the app in the foreground.
 *
 * Worth knowing for yuzic specifically: it commits its `ios/` and `android/`
 * directories, so config plugins only take effect on a prebuild. The
 * Info.plist entry is already present there today — but it was put there by
 * @rntp/player, and it leaves with it. This plugin is what replaces that, and
 * until a prebuild happens the existing entry has to stay.
 */

/** iOS: keep playing when the screen locks. Pure, over the plist object. */
function addBackgroundAudio(infoPlist) {
  const modes = infoPlist.UIBackgroundModes ?? [];
  if (!modes.includes('audio')) {
    infoPlist.UIBackgroundModes = [...modes, 'audio'];
  }
  return infoPlist;
}

/**
 * iOS: tell the system this app has a CarPlay screen, and which class draws it.
 *
 * Without this entry CarPlay never constructs the scene delegate, and the app
 * simply does not appear on the car's home screen — no error, no log, nothing
 * to search for. The class name is a *string* here and `@objc`-pinned on the
 * Swift side, because Swift's mangled name is not what the system looks up.
 *
 * The `com.apple.developer.carplay-audio` entitlement is a separate matter and
 * deliberately not written here: it has to be granted by Apple per app, and a
 * plugin that fabricated it would produce a build that fails to sign with a
 * far less obvious message than "you do not have this entitlement".
 */
function addCarPlayScene(infoPlist) {
  const manifest = infoPlist.UIApplicationSceneManifest ?? {};
  const roles = manifest.UISceneConfigurations ?? {};
  const carPlay = roles.CPTemplateApplicationSceneSessionRoleApplication ?? [];

  const name = 'YuzicEngineCarPlay';
  if (!carPlay.some(scene => scene.UISceneConfigurationName === name)) {
    carPlay.push({
      UISceneConfigurationName: name,
      UISceneDelegateClassName: 'YuzicCarPlaySceneDelegate',
    });
  }

  roles.CPTemplateApplicationSceneSessionRoleApplication = carPlay;
  manifest.UISceneConfigurations = roles;
  infoPlist.UIApplicationSceneManifest = manifest;
  return infoPlist;
}

function withBackgroundAudio(config) {
  return withInfoPlist(config, config => {
    config.modResults = addCarPlayScene(addBackgroundAudio(config.modResults));
    return config;
  });
}

/**
 * Android: a foreground service, and permission to run one.
 *
 * `FOREGROUND_SERVICE_MEDIA_PLAYBACK` is separate from `FOREGROUND_SERVICE` and
 * required from API 34 — without it the service throws on start, on exactly
 * the newer devices least likely to be tested against.
 */
function addPlaybackService(manifest, application) {

    manifest.manifest['uses-permission'] = manifest.manifest['uses-permission'] ?? [];
    const permissions = [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
      'android.permission.WAKE_LOCK',
      'android.permission.INTERNET',
      'android.permission.POST_NOTIFICATIONS',
    ];
    for (const name of permissions) {
      const already = manifest.manifest['uses-permission'].some(
        entry => entry.$?.['android:name'] === name
      );
      if (!already) {
        manifest.manifest['uses-permission'].push({ $: { 'android:name': name } });
      }
    }

    application.service = application.service ?? [];
    const serviceName = 'dev.yuzic.engine.PlaybackService';
    const already = application.service.some(
      entry => entry.$?.['android:name'] === serviceName
    );
    if (!already) {
      application.service.push({
        $: {
          'android:name': serviceName,
          'android:exported': 'true',
          'android:foregroundServiceType': 'mediaPlayback',
        },
        'intent-filter': [
          {
            // Both actions on purpose: head units still resolve media browsers
            // by the legacy one, and dropping it makes the app invisible in
            // some cars while looking correct everywhere else.
            action: [
              { $: { 'android:name': 'androidx.media3.session.MediaLibraryService' } },
              { $: { 'android:name': 'android.media.browse.MediaBrowserService' } },
            ],
          },
        ],
      });
    }

    return manifest;
}

function withPlaybackService(config) {
  return withAndroidManifest(config, config => {
    const application = AndroidConfig.Manifest.getMainApplicationOrThrow(config.modResults);
    addPlaybackService(config.modResults, application);
    return config;
  });
}

module.exports = function withYuzicEngine(config) {
  return withPlaybackService(withBackgroundAudio(config));
};

// The two transformations, separately, so they can be tested without standing
// up Expo's whole mod pipeline. A config plugin that is wrong fails silently
// at prebuild — the app just stops when the screen locks — so these are worth
// pinning.
module.exports.addBackgroundAudio = addBackgroundAudio;
module.exports.addCarPlayScene = addCarPlayScene;
module.exports.addPlaybackService = addPlaybackService;
