# iOS 工程的 Podfile
# 用法：pod install

platform :ios, '15.0'
use_frameworks!

target 'VideoCall' do
  # stasel 维护的 WebRTC pod (XCFramework 版本，支持模拟器+真机)
  # https://github.com/stasel/WebRTC
  pod 'WebRTC-lib'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      # 排除 arm64 模拟器架构警告
      config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = ''
    end
  end
end
