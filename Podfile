# iOS 工程的 Podfile
# 用法：pod install

platform :ios, '15.0'
use_frameworks!

target 'VideoCall' do
  # stasel 维护的 WebRTC XCFramework
  # https://github.com/stasel/WebRTC
  # 注意：M141+ 的 iOS framework 头文件路径有 bug (import 嵌套路径对不上)
  # 详见 https://github.com/stasel/WebRTC/issues/132
  pod 'WebRTC-lib', '140.0.0'
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
