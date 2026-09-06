require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

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

  # Both directories: `ios/Core` is plain Swift with no Expo dependency — it is
  # also a SwiftPM target so it can be built and tested by `swift test` without
  # an app — and `ios/*.swift` is the bridge that needs ExpoModulesCore. The
  # podspec takes both; the package takes only the first.
  s.source_files = 'ios/**/*.{h,m,mm,swift,hpp,cpp}'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
