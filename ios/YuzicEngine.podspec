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

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    # opus's own defines, spelled out rather than reached through
    # HAVE_CONFIG_H. That flag is generic autotools vocabulary and these apply
    # to every file in the target — including React Native's C++ — so setting
    # it made unrelated headers take a different branch and surfaced as a
    # missing <bitset> inside yoga. These names are opus's alone.
    'GCC_PREPROCESSOR_DEFINITIONS' =>
      '$(inherited) OPUS_BUILD=1 VAR_ARRAYS=1 HAVE_LRINT=1 HAVE_LRINTF=1 OP_DISABLE_HTTP=1',
    # Vendored third-party C, compiled as it ships. Its warnings are not ours
    # to fix and would bury our own.
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES'
  }

  # The engine itself.
  #
  # This podspec lives in `ios/` rather than at the package root because that
  # is where expo-modules-autolinking looks: `search` finds a package by its
  # expo-module.config.json wherever it sits, but `resolve` only produces a pod
  # — and therefore a Swift module in the generated ExpoModulesProvider — when
  # it finds a podspec here. With it at the root the module compiled and linked
  # and was still invisible to `requireNativeModule`.
  #
  # `Core/` is also a SwiftPM target, which is what lets `swift test` build the
  # logic with no app; this simply takes the same files.
  s.subspec 'Core' do |ss|
    ss.source_files = '*.{h,m,mm,swift}', 'Core/**/*.swift', 'CarPlay/**/*.swift'
    ss.dependency 'YuzicEngine/Ogg'
    ss.dependency 'YuzicEngine/Vorbis'
    ss.dependency 'YuzicEngine/Opus'
  end

  # Xiph's decoders, one subspec each. iOS has no Vorbis or Opus decoder, so
  # without these an `.ogg` or `.opus` cannot be opened by Core Audio at all.
  #
  # A subspec per library rather than one lump, and that is the load-bearing
  # decision. `header_mappings_dir` takes a single directory and the three
  # libraries cannot share one — their public headers sit at different depths,
  # and libvorbis and libopus both define `mdct_lookup` in a file called
  # `mdct.h`, so one shared header search path puts both in scope and fails to
  # compile. SwiftPM expresses the same separation as one target each.
  #
  # The mappings matter because compiling these sources and *importing* the
  # resulting module are two different clang invocations. The first uses the
  # search paths below; the second resolves against `Pods/Headers/Public/`,
  # where CocoaPods has copied the public headers — flattened, unless a
  # mappings dir preserves the structure. That is how `<ogg/os_types.h>` could
  # fail to resolve while every C file compiled happily.
  s.subspec 'Ogg' do |ss|
    ss.source_files = 'Vendor/ogg/**/*.{c,h}'
    ss.public_header_files = 'Vendor/ogg/include/**/*.h'
    ss.private_header_files = 'Vendor/ogg/src/*.h'
    ss.header_mappings_dir = 'Vendor/ogg/include'
    ss.pod_target_xcconfig = {
      'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Vendor/ogg/include"'
    }
  end

  s.subspec 'Vorbis' do |ss|
    ss.dependency 'YuzicEngine/Ogg'
    ss.source_files = 'Vendor/vorbis/**/*.{c,h}'
    ss.public_header_files = 'Vendor/vorbis/include/**/*.h'
    ss.private_header_files = 'Vendor/vorbis/lib/**/*.h'
    ss.header_mappings_dir = 'Vendor/vorbis/include'
    ss.pod_target_xcconfig = {
      # libvorbis reaches its own `modes/` and `books/` relative to `lib`.
      'HEADER_SEARCH_PATHS' => [
        '"$(PODS_TARGET_SRCROOT)/Vendor/vorbis/include"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/vorbis/lib"',
      ].join(' ')
    }
  end

  s.subspec 'Opus' do |ss|
    ss.dependency 'YuzicEngine/Ogg'
    ss.source_files = 'Vendor/opus/**/*.{c,h}'
    ss.public_header_files = 'Vendor/opus/include/*.h'
    ss.private_header_files =
      'Vendor/opus/celt/**/*.h', 'Vendor/opus/silk/**/*.h',
      'Vendor/opus/src/*.h', 'Vendor/opus/opusfile/*.h'
    # Flat, unlike the other two: opus and opusfile include their own public
    # headers by bare name — `<opus_multistream.h>`, not `<opus/…>` as a
    # consumer would — so they have to land at the root of the public
    # directory rather than under one.
    ss.header_mappings_dir = 'Vendor/opus/include'
    ss.pod_target_xcconfig = {
      'HEADER_SEARCH_PATHS' => [
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/include"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/celt"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/silk"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/silk/float"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/src"',
        '"$(PODS_TARGET_SRCROOT)/Vendor/opus/opusfile"',
      ].join(' ')
    }
  end

  s.default_subspecs = 'Core'
end
