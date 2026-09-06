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
  s.source_files = '**/*.{h,m,mm,swift,hpp,cpp}'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
