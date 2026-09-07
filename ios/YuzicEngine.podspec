require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'YuzicEngine'
  s.version        = package['version']
  s.summary        = package['description']
  s.license        = package['license']
  s.author         = 'yuzic contributors'
  s.homepage       = 'https://github.com/eftpmc/yuzic-engine'
  s.platforms      = { :ios => '15.1', :tvos => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/eftpmc/yuzic-engine.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # This file lives in `ios/` rather than at the package root because that is
  # where expo-modules-autolinking looks: `search` finds a package by its
  # expo-module.config.json wherever it sits, but `resolve` only produces a pod
  # — and therefore a Swift module in the generated ExpoModulesProvider — when
  # it finds a podspec here. With it at the root the module compiled and linked
  # and was still invisible to `requireNativeModule`.
  #
  # Paths are relative to this file, so this covers the bridge alongside it and
  # `Core/` beneath. Core is also a SwiftPM target, which is what lets
  # `swift test` build the logic with no app; the podspec simply takes both.
  s.source_files = '**/*.{h,m,mm,swift,hpp,cpp,c}'

  # Xiph's decoders, vendored under `Vendor/`. iOS has no Vorbis decoder, so
  # without these an Ogg file cannot be opened at all.
  #
  # `header_mappings_dir` is the load-bearing line. CocoaPods otherwise
  # flattens every public header into one directory, and libvorbis includes
  # `<ogg/os_types.h>` by path — so the app build failed to find a header that
  # was right there, while `swift build` was perfectly happy. Both build
  # systems now agree on `Vendor/include` holding `ogg/` and `vorbis/`.
  s.header_mappings_dir = 'Vendor/include'
  s.private_header_files = 'Vendor/ogg/src/*.h', 'Vendor/vorbis/lib/**/*.h'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    # libvorbis's sources include their own internal headers by bare name.
    # PODS_TARGET_SRCROOT already points at this directory — the podspec lives
    # in ios/ — so these are relative to it. Prefixing them with ios/ produced
    # ios/ios/Vendor and a header-not-found for libvorbis's own modes/.
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/Vendor/include"',
      '"$(PODS_TARGET_SRCROOT)/Vendor/vorbis/lib"',
      '"$(PODS_TARGET_SRCROOT)/Vendor/ogg/src"',
    ].join(' '),
    # Vendored third-party C, compiled as it ships. Its warnings are not ours
    # to fix and would bury our own.
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES'
  }
end
