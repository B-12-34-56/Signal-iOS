Pod::Spec.new do |s|
  s.name             = 'SignalCore'
  s.version          = '1.0.0'
  s.summary          = 'Core functionality for Signal iOS app'
  s.description      = 'Core functionality and utilities for Signal iOS app'
  s.homepage         = 'https://github.com/signalapp/Signal-iOS'
  s.license          = { :type => 'GPLv3', :file => '../LICENSE' }
  s.author           = { 'Signal' => 'support@signal.org' }
  s.source           = { :git => 'https://github.com/signalapp/Signal-iOS.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
  s.source_files = 'Sources/**/*'
  s.frameworks = 'Foundation', 'UIKit', 'CoreImage'
  s.dependency 'AWSCore'
  s.dependency 'AWSS3'
  s.dependency 'AWSDynamoDB'
end 