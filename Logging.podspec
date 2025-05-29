Pod::Spec.new do |s|
  s.name         = 'Logging'
  s.version      = '1.6.3'
  s.summary      = 'Apple swift-log API framework'
  s.homepage     = 'https://github.com/apple/swift-log'
  s.license      = { :type => 'Apache 2.0' }
  s.author       = { 'Apple' => 'swiftpm-dev@swift.org' }
  s.source       = { :git => 'https://github.com/apple/swift-log.git',
                     :tag => s.version.to_s }
  s.swift_version = '5.9'
  s.platform     = :ios, '13.0'
  s.source_files = 'Sources/Logging/**/*.swift'
  s.module_name  = 'Logging'
end
