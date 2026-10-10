# AppleMonitor — iOS 端（由 AndroidMonitor 移植）

`PCMonitorHost` 的 iOS 客户端。UI、前端框架、协议栈与
[`../AndroidMonitor`](../AndroidMonitor) **完全同源**——`lib/` 是从 Android 端整体
搬过来的，只改了 5 个文件里与平台强相关的几行（见下文《iOS 适配清单》）。
所有页面、主题、响应式布局、导航状态机、配对与遥测协议都保持原样。

> 工程在本机（Windows）只做**源码创建**。iOS 的编译链路只存在于 macOS
> （Xcode + iOS SDK），所以这个目录是**可直接在 Mac 上编译的完整工程**，
> 而不是产物。

> **没有 Mac 也不想买？** 本工程已接入云端编译：GitHub Actions 的免费 macOS
> 机器产出**未签名 IPA**，再在你的 Windows 机器上用 Sideloadly 配自己的
> Apple ID（普通免费账号即可）签名并装进 iPhone。完整流程见
> **[SIGN-AND-INSTALL-WINDOWS.md](SIGN-AND-INSTALL-WINDOWS.md)**。
> 本节后面的内容是传统的「借一台 Mac」路线，两条路都可行。

---

## 1. 目录结构

```
AppleMonitor/
├── lib/                     Dart 源码，与 AndroidMonitor 同源（27 个文件）
│   ├── main.dart            入口：主题 + 三个长生命周期控制器
│   ├── models/              PCStatus 镜像、13 态设备状态机
│   ├── responsive/          屏幕分档 / 布局变体 / 缩放度量
│   ├── screens/             仪表盘、CPU/GPU/DISK 详情、HOST LINK 连接页
│   ├── services/            协议编解码、WS 客户端、UDP 发现、配对、握手
│   ├── theme/               6 套主题
│   ├── util/                固件同款格式化函数
│   └── widgets/             HUD、火花线、命令栏、主题选择
├── test/                    回归测试（fix1~fix12 + widget 冒烟）
├── assets/fonts/            字体目录（pubspec 已声明，TTF 按原样留空）
├── preview/                 浏览器版 UI 复刻（纯审阅用，不参与编译）
├── ios/                     ← iOS 平台工程（本目录的核心新增部分）
│   ├── Runner.xcodeproj/    Xcode 工程（标准 Flutter 模板，非手写）
│   ├── Runner.xcworkspace/  ← Xcode 要打开的是这个，不是 .xcodeproj
│   ├── Runner/
│   │   ├── AppDelegate.swift     设备名通道 + 屏幕常亮（对应 MainActivity.kt）
│   │   ├── SceneDelegate.swift   UIScene 生命周期（模板原样）
│   │   ├── Info.plist            本地网络权限 / 方向 / 显示名 / ATS
│   │   ├── Runner.entitlements   组播权限（默认未启用，见第 5 节）
│   │   └── Assets.xcassets/      图标与启动图
│   ├── Flutter/            xcconfig、AppFrameworkInfo（Generated.xcconfig 由 pub get 生成）
│   ├── RunnerTests/        模板自带的空测试 target
│   └── Podfile             CocoaPods 配置（platform :ios, '15.0'）
├── build_ios.sh            Mac 端构建脚本
├── pubspec.yaml            依赖与 Android 端一致，未新增任何包
└── README-iOS.md           本文件
```

---

## 2. 到 Mac 上怎么编译

### 前置

| 需要 | 说明 |
| --- | --- |
| macOS + Xcode 15 或更新 | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` |
| Flutter SDK 3.47.7 | 与生成此工程的版本一致；其他 3.4x 版本一般也可 |
| CocoaPods | `sudo gem install cocoapods`（或 `brew install cocoapods`） |

依赖没有新增：`intl` + `shared_preferences`，与 Android 端完全相同。
iOS 侧插件只有 `shared_preferences_foundation`，走 CocoaPods。

### 构建

```bash
cd AppleMonitor
chmod +x build_ios.sh          # 从 Windows 复制过来会丢执行位，务必先做这一步

./build_ios.sh                 # ① release 编译（不签名）——先验证能编过
./build_ios.sh sim             # ② 起模拟器直接跑（不需要任何签名）
./build_ios.sh run             # ③ 连真机跑（需要先在 Xcode 里选团队）
./build_ios.sh archive         # ④ 出 .ipa（TestFlight / 上架）
./build_ios.sh clean           # 清理
```

只会手工敲命令时，等价于：

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release --no-codesign      # → build/ios/iphoneos/Runner.app
```

### 真机跑之前必须做一次的事

打开 `ios/Runner.xcworkspace`（**不是** `.xcodeproj`，workspace 才带 Pods）：

1. 左侧选 **Runner** target → **Signing & Capabilities**；
2. 勾上 *Automatically manage signing*，**Team** 选你自己的 Apple ID / 团队；
3. 如果用了免费个人账号，把 **Bundle Identifier** 改成全局唯一的（例如
   `com.yourname.pcmMonitor`）——默认值 `com.pcmonitor.pcmMonitor` 只是占位。

`build_ios.sh run / archive` 都依赖这一步，Flutter 无法代劳。

---

## 3. iOS 适配清单（`lib/` 只动了 5 个文件）

移植原则：**界面与前端框架零改动**。`screens/`、`widgets/`、`theme/`、`models/`、
`responsive/`、`util/`、`main.dart` 与 Android 端**逐字节相同**。改动全部集中在
`services/`，且只涉及"文件放哪、我叫什么名字、报文发到哪些地址"这三类平台差异。

| 文件 | 改动 | 为什么必须改 |
| --- | --- | --- |
| `services/gpu_selection_service.dart` | 存储目录：iOS 用 `$HOME/Documents/PCMonitor/`（Windows 仍用 `%LOCALAPPDATA%`，桌面 Linux/macOS 仍用 `$HOME`） | iOS 上 `$HOME` 是 App 容器**根目录**，不能在那里建新文件。文件名与内容格式一字未变，只是换了位置 |
| `services/host_discovery_service.dart` | 新增 iOS 专用**单播回退**：探测时除广播外，再对本地私有网段的 `/24` 逐个单播一遍 | iOS 禁止 App 向广播/组播地址发包，除非持有 Apple 逐 App 审批的 multicast 权限。见第 5 节 |
| `services/host_connection.dart` | 兜底设备名由固定的 `Android Monitor xxxx` 改为平台相关（iOS 上为 `iOS Monitor xxxx`）；注释同步 | 这个名字会写进存储、并显示在 PC 的配对弹窗里，iPhone 不该自称 Android |
| `services/pairing_store.dart` | 设备 ID 前缀平台化：`android-…` / `ios-…` / `dart-…` | 主机侧把它记进配对注册表，前缀用于人眼区分客户端；主机的 `ValidDeviceId` 只校验长度和不可见字符，所以前缀纯属可读性，**不影响协议** |
| `services/protocol.dart` | `device.status` 里的 `firmwareVersion` 由常量改为按平台取前缀（`ios-2026.10.09.1`） | 同上：主机原样记录这个字符串。协议版本号本身（`2026.10.09.1`）没变 |

**没有被改、但需要知道的**：
`main.dart` 里的 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`
在 iOS 上是无操作（该模式是 Android 概念），保留它不会有任何副作用，所以没动。

---

## 4. iOS 平台工程做了什么

`ios/` 由 Flutter 官方脚手架生成（`flutter create --platforms=ios`），保证
`project.pbxproj` 是 Xcode 认的正确结构，而不是手写的。在此之上做了 4 处修改：

### `Runner/AppDelegate.swift` — 对应 Android 的 `MainActivity.kt`

Android 那边 `MainActivity` 只做两件事，iOS 这边一一对应：

| `MainActivity.kt` | `AppDelegate.swift` |
| --- | --- |
| `MethodChannel("pcmonitor/device")` + `deviceName` 返回厂商+型号 | 同名通道，`deviceName` 返回 `UIDevice.current.name`（如 "iPhone"） |
| `FLAG_KEEP_SCREEN_ON` | `application.isIdleTimerDisabled = true`，并在每次 `applicationDidBecomeActive` 重置（系统会在切后台时清掉它） |

Dart 侧 `_platformDeviceName()` 的容错逻辑（拿不到就回退）原样保留，所以即使通道
注册失败 App 也照常工作。

> 注：iOS 16 起 `UIDevice.current.name` 对未持 `…user-assigned-device-name` 权限的
> App 返回通用机型名（"iPhone" / "iPad"），而不是用户自定义的设备名。行为差异仅
> 体现在 PC 配对弹窗显示的名字上，不影响任何功能。

### `Runner/Info.plist`

| 键 | 值 / 原因 |
| --- | --- |
| `CFBundleDisplayName` | `PC Monitor`，与 Android 的 `android:label` 一致 |
| `NSLocalNetworkUsageDescription` | **必需**。iOS 14+ 访问局域网要用户授权，没有这个键连弹窗都不会出现，所有探测包被静默丢弃 |
| `NSAppTransportSecurity → NSAllowsLocalNetworking` | 只放行本地网络。Flutter 的 socket 走 `dart:io` 原生 socket，不经 CFNetwork，本来就不受 ATS 约束；这里是给将来可能引入的 NSURLSession 组件留的窄口子，比 `NSAllowsArbitraryLoads` 安全得多 |
| `ITSAppUsesNonExemptEncryption = false` | 全 App 只用了 SHA-256 / HMAC-SHA-256，属豁免范围。声明后上传 App Store Connect 不再逐次追问 |
| `UISupportedInterfaceOrientations` | 与 Android 声明穷举 `configChanges` 同一个目的：旋转只重排布局，绝不重建。iPhone 三向，iPad 四向 |

### `ios/Podfile`

`platform :ios, '15.0'`，与 `IPHONEOS_DEPLOYMENT_TARGET` 和 SPM 包的
`platforms:` 三处保持一致（脚手架默认给的就是 15.0）。选 15.0 而不是模板的
13.0，是因为发现流程依赖的本地网络隐私门是 iOS 14 才有的特性。

### 部署目标

`IPHONEOS_DEPLOYMENT_TARGET = 15.0`，最低 iOS 15。

---

## 5. 网络与权限（重点）

### 5.1 权限清单

| 权限 | Android 对应 | iOS 的形态 |
| --- | --- | --- |
| 互联网 | `INTERNET` | 无需声明 |
| 局域网发现 / 连接 | `ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE` | **本地网络权限**：首次访问 LAN 时系统自动弹窗，用户可拒绝（设置 → 隐私与安全性 → 本地网络） |
| 发送 UDP 广播 | 无对应限制 | **`com.apple.developer.networking.multicast` 权限**，需向 Apple 单独申请，见 5.2 |

### 5.2 广播与单播回退（这是 iOS 唯一的实质性功能适配）

Apple 官方文档原话：

> *"Your app must have this entitlement to send or receive IP multicast or
> broadcast on iOS. […] This entitlement requires permission from Apple before
> you can use it in your app."*

申请入口：<https://developer.apple.com/contact/request/networking-multicast>

申请对个人开发者并不算轻松（要写明用途，等待审批），所以工程**没有**把功能押在
它上面：

- **默认行为**：`HostDiscoveryService` 在 iOS 上除广播外，额外对每个本地私有网段
  （`10/8`、`172.16/12`、`192.168/16`）的 `/24` 逐个地址发一遍**单播** `discovery.probe`。
  单播完全不受该权限约束，而主机对单播探测的应答与对广播的应答**是同一条**
  `discovery.offer`。协议一字未改，只是目的地址不同。
- **Android / ESP32 不受影响**：回退逻辑由 `Platform.isIOS` 开关控制，两端流量特征
  与原来完全一致。
- **已配对的重连根本用不到广播**：每次探测都先向记住的主机 IP 发单播
  `discovery.request`（原代码就是这么写的），这条路在 iOS 上一直可用。
- **代价**：一次探测窗口最多多发约 254 个小报文（约 50 KB），且只覆盖首次配对；
  扫描期间每 32 个地址让出一次事件循环，不会卡住 UI。

### 5.3 想用上广播（可选）

两件事都满足后再启用：

1. Apple 已为该 App ID 批准 multicast 权限；
2. 所用的描述文件（provisioning profile）已包含它。

然后：

1. 打开 `ios/Runner.xcworkspace`，把 `ios/Runner/Runner.entitlements` 拖进左侧
   Runner 分组（它有意没有写进 `project.pbxproj`，避免误改工程文件）；
2. 选中 Runner target → **Build Settings** → 搜 `entitlements`，把
   **Code Signing Entitlements** 设为 `Runner/Runner.entitlements`。

`Runner.entitlements` 文件已经准备好（内容就是那一项权限），但**默认不接入工程** ——
因为带着描述文件里没有的权限去签名会在签名阶段直接失败，那会让 `flutter run`
在真机上莫名其妙地跑不起来。文件头部的注释里写了同样的说明。

### 5.4 配对流程是否一致

完全一致，流程未变：

```
扫描(UDP 8766) → discovery.offer → 选中主机 → pairing.request
   → PC 弹窗人工确认 → pairing.grant(32B secret) → 落盘
   → WebSocket /ws → pairing.challenge → pairing.authenticate(HMAC)
   → pairing.auth.result → device.status → telemetry.snapshot 流
```

被主机移除配对、拒绝认证、地址漂移后重新发现等既有行为，均与 Android 端相同。

---

## 6. 已知差异与限制

1. **后台不保活。** Android 版靠前台运行常驻；iOS 会把切到后台的 App 挂起，
   WebSocket 随之断开。回到前台时事件循环恢复、断线回调触发、退避重连自动跑起来，
   最终会重新连上——但**没有**加 `UIBackgroundModes`，因为那需要"持续定位/音频"之类
   的正当理由，容易在上架审核时被质询。如果需要锁定屏幕时也持续刷新，这一条要单独讨论。
2. **设备名可能是通用机型名。** 见第 4 节 iOS 16 的说明。
3. **字体未内置。** 与 Android 端一致，`pubspec.yaml` 的 `fonts:` 块仍是注释状态，
   时钟与数字走系统默认字体。这是原工程就有的待办，没有改。
4. **签名。** 默认用自动签名，Bundle ID 是 `com.pcmonitor.pcmMonitor`。上架前需要
   换成你自己的唯一 ID 并配好 Team。
5. **iOS 编译尚未实跑。** 本机是 Windows，`flutter build ios` 无法运行。Dart 侧已在
   本机用 Flutter 3.47.7 / Dart 3.13.5 跑过真实静态分析（`lib/` 与 `test/` 共 30 个
   文件：**0 error / 0 warning**，21 条 info 级 lint），Dart 依赖也能正常解析；
   `ios/` 目录由官方脚手架产出、结构完整。但**首次在 macOS 上的编译仍需实跑确认**
   —— 这一步由 `.github/workflows/ios-unsigned-ipa.yml` 在云端完成。

---

## 7. 排障

| 现象 | 处理 |
| --- | --- |
| `pod install` 报 `Generated.xcconfig must exist` | 先跑 `flutter pub get`，它会生成该文件 |
| Xcode 里一堆红色 `Flutter/Generated.xcconfig` 报错 | 同上，先 `flutter pub get`；再确认打开的是 `.xcworkspace` |
| 真机签名失败，提示 provisioning profile 不含某权限 | 说明 `Runner.entitlements` 被接入了但描述文件没有该权限，见 5.3 |
| 扫描一直提示 `No PC found` | ① 给 App 开"本地网络"权限（设置 → 隐私与安全性 → 本地网络）；② 确认 PCMonitorHost 正在运行且开了 *Allow LAN pairing*；③ 确认手机和 PC 在同一网段 |
| 模拟器里扫描正常但真机不行 | 模拟器共享 Mac 的网络栈，不能代表真机；以真机结果为准 |
| 旋转屏幕后数值跳变 | 不应该发生——布局引擎按窗口尺寸重排。若出现请记录机型与系统版本 |

---

## 8. 测试

Dart 侧测试与 Android 端同一套，在任意有 Flutter SDK 的机器上跑：

```bash
flutter test
```

iOS 工程自带的 `RunnerTests` 是模板空壳，没有实质断言，可以忽略。
