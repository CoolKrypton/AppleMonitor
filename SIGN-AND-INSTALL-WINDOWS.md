# 从云端编译到装进 iPhone —— Windows 全程指南

> 目标：**一分钱不花**，把 `AppleMonitor` 编译出来、签好名、装进你的 iPhone。
> 你的 Apple 账号是**普通（免费）账号**，这一点决定了方案的形态，见第 1 节。

---

## 0. 路线总览

```
  Windows（你现在的机器）                    GitHub 云端（免费）
  ┌──────────────────────┐                  ┌─────────────────────────┐
  │  lib/  ios/  源码     │  ── git push ──▶ │ ubuntu 机器：            │
  │                      │                  │   analyze + test（0 成本）│
  │                      │                  │        ↓ 通过了才开始     │
  │                      │                  │ macOS 机器：             │
  │                      │                  │   Xcode 编译 → .ipa      │
  │                      │ ◀── 下载 ──────── │   （未签名）             │
  └──────────┬───────────┘                  └─────────────────────────┘
             │
             │  USB
             ▼
  ┌──────────────────────┐                  ┌─────────────────────────┐
  │ Sideloadly（Windows） │  ── 签名 + 安装 ─▶│     你的 iPhone          │
  │ 用你的免费 Apple ID   │                  │  PC Monitor ✅           │
  └──────────────────────┘                  └─────────────────────────┘
```

**为什么签名不能在云端做？** 免费账号签名要过苹果的 Apple ID + 双重认证交互流程，做这个的只有 Windows / macOS 上的本地工具。把 Apple ID 密码塞进 CI 理论上可行，但等于把你的账号凭据交给第三方机器常驻，而且 2FA 会频繁失效 —— 不建议，本方案也不这么做。

---

## 1. 先认清那条绕不过去的硬限制

免费 Apple 账号 = 苹果给开发者的"个人团队"，它在苹果服务器上有三条硬限制，**任何免费工具都改不了**：

| | 免费账号（你） | 付费账号（$99/年） |
| --- | --- | --- |
| App 签名有效期 | **7 天** | 约 1 年 |
| 同时能装的 App 数 | **3 个** | 100 台设备 |
| 每 7 天可创建的 App ID | 10 个 | — |

第 8 天的表现：**图标还在，点开闪退**。不是 App 坏了，是签名过期了，重签一次就好（见第 6 节）。

除此之外的功能上没有阉割 —— 本地网络、WebSocket、常亮屏幕全都能用。工程里那个需要苹果单独审批的**组播权限默认就没接入**，iOS 端改走单播扫描，所以不会撞上签名失败。

---

## 2. 一次性准备（约 20 分钟）

### 2.1 GitHub 账号 + 一个空的私有仓库

1. 没有账号就在 <https://github.com/signup> 注册（免费）。
2. 建仓库：<https://github.com/new>
   - 名称随意，比如 `AppleMonitor`
   - **选 Private**
   - **不要**勾选 "Add a README file" / .gitignore / license —— 保持完全空白

> 为什么选 Private：代码不外泄。代价是 macOS 构建要走每月免费额度。GitHub 免费账号每月 2000 分钟，macOS 按 **10 倍**扣，即约 **200 分钟 macOS**。一次完整构建约 8–12 分钟，够跑 15–20 次，日常完全够用。额度用完当月只是停止构建，**不会扣费**（默认支出上限是 $0）。

### 2.2 装上 Windows 端的签名工具

按这个顺序装，缺一不可：

| 顺序 | 装什么 | 从哪装 | 注意 |
| --- | --- | --- | --- |
| 1 | **iTunes** | <https://www.apple.com/itunes/download/win64> | ⚠️ **不要**从 Microsoft Store 装 |
| 2 | **iCloud** | <https://support.apple.com/zh-cn/106176> | ⚠️ 同上，要 Apple 官网的独立安装包 |
| 3 | **Sideloadly** | <https://sideloadly.app/> | 免费 |

**为什么必须是官网独立安装包而不是商店版？** Sideloadly 要用苹果官方的 USB 驱动跟手机通信，还要用 iCloud 里的 Anisette 组件去跟苹果服务器完成握手 —— 商店版做了沙箱隔离，Sideloadly 找不到它，会在登录 Apple ID 那一步卡死。

装完 iTunes 后建议重启一次，确认服务在跑：`Win+R` → `services.msc` → 找到 **Apple Mobile Device Service** → 状态应为"正在运行"。

### 2.3 建议：为签名单独注册一个 Apple ID

不是必须，但强烈建议。理由：

- Sideloadly 需要输入你的 Apple ID **密码**和双重认证验证码；
- 用主账号意味着主账号的密码出现在第三方工具的输入框里；
- 新建一个 Apple ID 专门用来签名，功能上完全等价。

如果要用主账号也没问题 —— 凭据只在你本机和苹果服务器之间流转，Sideloadly 不经过自己的服务器。

---

## 3. 推代码，触发云端编译

本地仓库我已经初始化好并提交了。你只需要把它推到刚才建的空仓库。

**把 `<你的用户名>` 换成你的 GitHub 用户名**（后面 Bundle ID 会用到它）：

```bash
cd /f/Codes/c/esp32test/AppleMonitor

git remote add origin https://github.com/<你的用户名>/AppleMonitor.git

git push -u origin main
```

推送时弹出的登录窗口，用浏览器授权即可（Git Credential Manager 会接管，不需要手输密码）。

> **推送报 `remote: Repository not found.`？** 别急着怀疑网络或账号权限 —— GitHub 对「仓库不存在」和「你无权访问」返回同一个 404。先按 **7.1 节**三步自查，九成是仓库其实还没建出来。

> **想让 commit 记在你的 GitHub 名下？** 本地 git 身份还是占位的，改一下再提交：
> ```bash
> git config user.name  "你的名字"
> git config user.email "你的GitHub邮箱"
> git commit --amend --reset-author
> ```
> 不改也能正常推送，只是提交记录不会关联到你的账号。

推上去之后，**构建会自动开始**，不用做别的。

---

## 4. 等构建，下载 IPA

1. 打开 `https://github.com/<你的用户名>/AppleMonitor/actions`
2. 看到 **Build unsigned iOS IPA** 这条正在跑。两个阶段：
   - `Dart analyze + test`（Linux，**不计费**）—— 这一关不过，后面的 macOS 根本不会启动
   - `Flutter iOS release -> unsigned IPA`（macOS，**计费**）
3. 等它变成绿色 ✅（首次约 8–12 分钟，之后有缓存会快些）
4. 点进这次运行，页面底部 **Artifacts** 框里点 `PCMonitor-unsigned-2026.10.10-9`
5. 下载得到一个 zip，解压后是 **`PCMonitor-unsigned-2026.10.10-9.ipa`**

> Artifacts 必须登录 GitHub 才能下载（私有仓库的必然结果）。文件 30 天后自动清理，过期就重跑一次流水线。

**Bundle ID 是怎么定的？** 优先级：手动触发时填的输入 > 仓库变量 `BUNDLE_ID` > `com.<你的用户名小写>.pcmmonitor`。免费账号要求这个 ID 在苹果全球范围内唯一，用你的用户名来构造基本不会撞车。想换就在仓库 `Settings → Secrets and variables → Actions → Variables` 里加一个 `BUNDLE_ID`。

---

## 5. Sideloadly 签名 + 安装

### 5.1 连接

1. **USB 线**连上 iPhone（首次必须用线，Wi-Fi 方式后面再说）
2. 手机上解锁，弹"要信任此电脑吗？" → **信任**，输入锁屏密码
3. **右键 Sideloadly → 以管理员身份运行**

### 5.2 签名安装

4. 把 `PCMonitor-unsigned-*.ipa` **拖进 Sideloadly 窗口**顶部的 IPA 框
5. 确认左上角 **Device** 下拉框里是你的 iPhone（不是别的设备）
6. **Apple ID** 一栏填你的 Apple ID（建议用 2.3 里那个专用账号）
7. 点 **Start**
8. 会依次要求：Apple ID 密码 → 双重认证验证码（手机上会弹 6 位数字）
9. 等 1–3 分钟，进度条走完，日志出现 `Done` 之类字样

> 如果卡在 **"Connecting to device"** 或 Apple ID 登录：先彻底退出 iTunes（任务管理器里确认没有 `iTunes.exe` / `AppleMobileDeviceService.exe` 残留），再重试。这是最常见的失败点。

### 5.3 手机上放行（iOS 16 起必做）

10. **信任开发者证书**
    `设置 → 通用 → VPN 与设备管理 → 开发者 App → 你的 Apple ID → 信任`

11. **打开开发者模式**（你的系统是 17/18/26，一定需要）
    `设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机`

    > 如果**找不到**"开发者模式"这一项：说明它还没被激活过。把第 7–9 步重做一遍（哪怕报错也没关系），选项就会出现。

### 5.4 首次启动

12. 主屏点开 **PC Monitor**
13. 会弹 **"允许 PC Monitor 查找并连接本地网络上的设备？"** —— **必须允许**。
    这是 iOS 14 起的强制隐私门，拒绝的话所有探测包会被系统静默丢弃，扫描会一直显示 `No PC found`。
    事后想改：`设置 → 隐私与安全性 → 本地网络 → PC Monitor`。

到这一步 App 就装好了。

---

## 6. 七天到期怎么办

三种解法，按省心程度排序：

### 方案 A（推荐）：AltStore 自动续签

AltStore 会在电脑和手机处于同一 Wi-Fi 时，**自动在后台重新签名**，你基本感知不到。对你这个场景特别合适 —— PC Monitor 本来就需要跟同一网络里的电脑通信，那台电脑（或本机）挂上 AltServer 就行。

1. 从 <https://altstore.io/> 下载 **AltServer**（Windows 版）
2. 管理员运行 AltServer（托盘图标）
3. 打开 iTunes → 设备 → **启用"通过 Wi-Fi 与此 iPhone 同步"**
4. AltServer 托盘图标 → **Install AltStore** → 选你的 iPhone → 输入 Apple ID
5. 手机上按 5.3 的步骤信任 + 开开发者模式
6. 打开 AltStore → **My Apps** → `+` → 选你的那个 IPA

之后只要电脑开着 AltStore 里的 AltServer，证书就会在到期前自动续上。

### 方案 B：每周手动重签一次

什么都不装，每周把第 5 节重做一遍 —— **IPA 不用重新下载**，本地那份一直能用：

- 拖同一个 IPA 进 Sideloadly
- 同一个 Apple ID（**必须和上次一样**，换了账号可能丢数据）
- Start

大约 1 分钟。**重复安装不会丢数据**：Bundle ID 相同、签名账号相同时，iOS 保留 App 的容器，所以已配对的密钥和设置都还在。

### 方案 C：Sideloadly 自带的自动刷新

Sideloadly 0.60+ 也有自动刷新，但要求每次续签时能通过 USB 或 Wi-Fi 看到设备。可以作为兜底，不如方案 A 稳。

---

## 7. 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| `git push` 报 `remote: Repository not found.` | **先别怀疑网络**。GitHub 对「仓库不存在」和「仓库存在但当前账号无权访问」返回的是**同一个 404**，所以这一句话有两种完全不同的成因： ① 仓库压根没建（最常见）；② 本机缓存的 GitHub 凭据属于**另一个账号**。自查见下方「仓库不存在的排查」。 |
| Actions 里 `Dart analyze + test` 红叉 | Dart 代码有问题。点进去看日志，本地 `flutter analyze` 也能复现。**这一关不计费**，随便重跑。 |
| macOS 任务里 `Missing package product 'FlutterGeneratedPluginSwiftPackage'` | Swift Package Manager 没开。workflow 里已有防御步骤，若仍出现就在仓库变量里确认没有干扰配置。 |
| 签名时报 `A valid provisioning profile ... could not be found` | Bundle ID 被占用了。去仓库 Variables 里把 `BUNDLE_ID` 改成别的（例如加个后缀），重跑流水线。 |
| Sideloadly 卡 "Connecting to device" | iTunes 残留进程占用 USB。彻底退出 iTunes 再试；换一根**能传数据**的线（不是只充电线）。 |
| Sideloadly 登录 Apple ID 报错 | 用的是 Microsoft Store 版 iTunes/iCloud。卸载，换官网独立安装包。 |
| 装完点开提示"未受信任的开发者" | 第 5.3 步没做完。去 `设置 → 通用 → VPN 与设备管理` 信任证书。 |
| 点开闪退、没有提示 | ① 开发者模式没开；② 签名过期了（第 8 天了）。 |
| App 里扫描一直 `No PC found` | ① 本地网络权限没给；② PCMonitorHost 没运行，或没开 *Allow LAN pairing*；③ 手机和电脑不在同一网段。 |
| 第 8 天开始闪退 | 正常的 7 天到期，照第 6 节续签。 |

### 7.1 `Repository not found` 的排查

**第 1 步：确认仓库到底存不存在。**

用浏览器打开（此时你应已登录 GitHub）：

```
https://github.com/<你的用户名>/AppleMonitor
```

- 能看到仓库页面 → 仓库存在，跳到第 3 步。
- 看到 **404** → 仓库没建，去第 2 步。注意：如果这个仓库是 Private，未登录时访问**也会**显示 404，所以务必确认浏览器右上角已经是你自己的账号。

**第 2 步：把仓库建出来。**

打开 <https://github.com/new>，名称填 `AppleMonitor`，选 **Private**，**不要**勾选任何 "Initialize this repository with..." 选项，然后 Create。建完不要再在网页上做任何操作，直接回到第 3 步。

**第 3 步：确认本机 git 用的是哪个账号。**

Windows 上 git 的凭据由 **Git Credential Manager** 托管。如果它记的是另一个 GitHub 账号的凭据，那你往自己的私有仓库推也会得到一模一样的 `Repository not found`。查一下：

```powershell
cmdkey /list | Select-String github
git credential-manager github list
```

- 两条都**没有输出** → 本机没有缓存凭据（干净状态）。直接推送，会弹出浏览器授权窗口，用你的账号登录即可。
- 列出了**别的账号** → 先清掉它，再推：

  ```powershell
  # 把列出来的账号逐个登出
  git credential-manager github logout <那个账号名>
  ```

  清干净后重新 `git push -u origin main`，浏览器窗口里登录你**自己**的账号。

**第 4 步：验证。**

```powershell
git ls-remote origin
```

能列出 `refs/heads/main` 就通了。

> **为什么会踩这个坑**：Windows 上的 git 凭据是**全局共享**的，跟当前目录无关。这台机器上如果曾经为别的项目登录过 GitHub，那个账号就会被静默复用 —— 你甚至不会看到登录窗口，只会看到一句语焉不详的 `Repository not found`。

---

## 8. 为什么没有"免费又永久"的办法

你可能会搜到下面这些，逐个说清楚为什么不行：

| 说法 | 实际情况 |
| --- | --- |
| **TrollStore 永久签名** | 依赖 iOS 14.0–17.0 上特定的 CoreTrust 漏洞。你的系统在 17/18/26 区间，用不了；iOS 26 目前也没有公开越狱。 |
| **AltStore PAL / 第三方应用市场** | 苹果的替代分发仅限**欧盟、日本、巴西**，且要求 Apple ID 所属地区也符合。中国区账号 + 境内不适用。 |
| **共享企业证书签名** | 用的是别人的企业证书，苹果一吊销就是**所有用它签的 App 同时死**；证书来源不明，是 iOS 恶意软件的主要传播途径之一。 |
| **把 Apple ID 交给 CI 让云端签名** | 技术上能凑出来，但要求把你的 Apple ID 密码作为长期凭据存在第三方机器上，且 2FA 会频繁失效。安全性上不可接受。 |
| **`fastlane sigh` 在 CI 里签** | 同样需要 Apple ID 的交互式登录，或者一张付费账号才有的 App Store Connect API Key。 |

**结论**：免费方案的天花板就是 7 天 + 3 个 App。想突破只有一条路 —— 苹果开发者账号（$99/年）。除此之外的所有"免费永久"说法，要么需要漏洞，要么需要别人的证书，要么需要欧盟身份。

---

## 9. 改完代码之后怎么更新

```bash
git add -A
git commit -m "描述你改了什么"
git push
```

然后重复第 4–5 节：等 Actions 出绿勾 → 下载新 IPA → Sideloadly 重装一次。

因为是同一个 Bundle ID 覆盖安装，**已配对的密钥不会丢**，装完打开就是连着的。

---

## 附：想调整流水线

配置文件在 `.github/workflows/ios-unsigned-ipa.yml`，常改的几个点：

| 想改什么 | 改哪里 |
| --- | --- |
| Flutter 版本 | 文件顶部的 `env.FLUTTER_VERSION`（现在是 `3.47.7`，与本工程一致） |
| Bundle ID | 仓库 Variables 加 `BUNDLE_ID`，或手动触发时填输入框 |
| macOS 机器版本 | `ios-ipa` job 的 `runs-on`（现在 `macos-latest`，可锁成 `macos-15`） |
| 产物保留天数 | `Upload the IPA` 步骤的 `retention-days`（现在 30 天） |

手动跑一次而不推代码：Actions 页面 → 左侧 **Build unsigned iOS IPA** → 右上 **Run workflow**。
