<p align="center">
  <img src="icon.png" width="144" alt="AirSnap icon">
</p>

<h1 align="center">AirSnap</h1>

<p align="center">
  Trigger your iPhone camera with a single Mac hotkey, strip GPS metadata, and paste straight into any AI chat or app.<br>
  <b>100% Offline · Zero Telemetry · No Desktop Clutter · Safe Auto-Paste</b>
</p>

<p align="center">
  <a href="#中文说明">中文说明</a> · <a href="#english">English</a>
</p>

---

<a name="中文说明"></a>

## 中文说明

**AirSnap** 是一个极简的 macOS 菜单栏工具。在任意对话框（ChatGPT、Claude、Antigravity、微信、Chrome 等）中按下快捷键，直接通过苹果原生连续互通相机（Continuity Camera / AWDL 局域网直连）唤起身边的 iPhone 拍照，拍完后照片直接进入剪贴板或自动填入当前输入框。

### 核心特性与隐私安全设计

- **100% 纯离线、无自动更新器**：仅链接苹果系统原生框架，无任何第三方库、无 Sparkle 更新器、无任何网络请求。
- **不污染桌面，不上传 iCloud**：照片默认仅暂存于当前用户专属的 macOS 临时目录（`$TMPDIR/airsnap-runtime/captures`，权限 `0700`），每次新拍照自动清理上一张旧图，重启自动回收，不往桌面或下载目录堆垃圾，也不会触发 iCloud 同步。
- **自动清除 GPS 定位元数据**：通过 `ImageIO` 无损剥离照片中的 GPS 位置信息后再写入临时文件与剪贴板。
- **剪贴板瘦身与方向矫正**：写入 `public.file-url`、`public.jpeg` 以及自动摆正旋转方向的 `public.png`，兼容浏览器、Electron/AI 客户端与原生应用，避免几十 MB 未压缩 TIFF 拖慢剪贴板。
- **防切窗误粘校验（可选自动写入）**：开启“拍完自动写入当前对话框”时，会在触发瞬间记录当前应用与窗口标题；拍完准备贴入前重新比对窗口标题——若拍照期间你切换了浏览器标签页或聊天对象，会自动**中止自动粘贴**并留存剪贴板，防止敏感图片发错窗口。
- **内置全局快捷键（默认 `⌥⌘C`）**：通过 macOS 原生 Carbon 热键注册，无需经由卡顿的“快捷指令”App 或 Karabiner，可在菜单栏随时自定义快捷键。
- **中文系统菜单适配**：原生兼容简体中文、繁体中文、英文与韩文 macOS 系统菜单。

### 安装使用

#### 方式一：源码一键本地编译安装（推荐，免除 macOS 拦截弹窗）

只需系统自带的 Xcode 命令行工具（`xcode-select --install`），无需安装 Homebrew 或任何第三方依赖：

```bash
git clone https://github.com/MattYan111/airsnap.git
cd airsnap
chmod +x install.sh build.sh
./install.sh
```

安装完成后会自动打开 `AirSnap`，顶部菜单栏会出现相机图标。

#### 方式二：下载预编译包（若通过 Releases 分发）

将 `AirSnap.app` 拖入 `/Applications` 后，首次运行若遇未公证拦截提示，执行一次即可：

```bash
xattr -d com.apple.quarantine /Applications/AirSnap.app
```

### 日常使用

1. 确保 Mac 与 iPhone 登录**同一个 Apple ID**，且双方开启 **Wi-Fi** 和 **蓝牙**。
2. 把光标停在任意输入框，按下 **`⌥⌘C`**（可在顶部菜单栏相机图标 → **设置快捷键…** 中随时修改）。
3. iPhone 自动拉起相机，拍照后点击 **“使用照片”**。
4. 照片立即写入剪贴板；若菜单栏开启了 **“拍完自动写入当前对话框”**，则直接贴入当前输入框。

### 权限说明

- **摄像头 / 麦克风 / 完全磁盘访问**：**全都不需要**。
- **辅助功能（Accessibility）**：**按需可选**。仅当启用“拍完自动写入当前对话框”时用于读取窗口标题防误粘和发送 `⌘V`；若在菜单栏取消勾选自动写入，应用可在**零系统权限**下正常运行（拍完后手动 `⌘V` 粘贴）。

### 命令行用法

```bash
open -na AirSnap --args photo        # 单次拍照
open -na AirSnap --args scan         # 单次扫描文档 (PDF)
open -na AirSnap --args --no-paste   # 仅写入剪贴板，不自动粘贴
```

---

<a name="english"></a>

## English

**AirSnap** is a lightweight, offline-first macOS menu bar utility that wakes your nearby iPhone's Continuity Camera from a customizable global hotkey (default `⌥⌘C`), strips sensitive GPS EXIF metadata, and pastes the captured photo straight into any chat box or app.

### Key Highlights

- **Purely Offline**: Zero third-party frameworks, zero auto-updaters, zero network URLs or telemetry. Built solely on Apple system frameworks (`AppKit`, `Carbon`, `ImageIO`, `ServiceManagement`).
- **No Desktop Clutter**: Saves strictly to your per-user private macOS temp directory (`$TMPDIR/airsnap-runtime/captures`, `0700`), clearing the previous capture on every new shot so files never pile up on your Desktop or sync to iCloud.
- **Privacy First**: Losslessly removes `kCGImagePropertyGPSDictionary` metadata via `ImageIO`.
- **Safe Auto-Paste with Window-Title Guard**: Records the active app and focused window title when triggered; if you switch browser tabs or chat windows while taking the photo, AirSnap aborts auto-paste and leaves the image safely on your clipboard.
- **Clean Clipboard Formats**: Writes `public.file-url`, `public.jpeg`, and an orientation-normalized `public.png` (no bloated uncompressed TIFF).
- **Zero-Lag Customizable Hotkey**: Uses Carbon `RegisterEventHotKey` directly from the menu bar (works across Chrome, Electron/AI apps, and Finder without Shortcuts runtime lag). Configurable in the menu bar UI.
- **Zero-Permission Option**: Disable "Auto-Paste" in the menu bar to run with **zero macOS privacy permissions** (manual `⌘V`). Camera, Microphone, and Full Disk Access permissions are never required.

### Quick Install (Build from Source)

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/MattYan111/airsnap.git
cd airsnap
chmod +x install.sh build.sh
./install.sh
```

### Requirements

- macOS 14.0+ (Apple Silicon & Intel Universal binary)
- Mac and iPhone signed into the same Apple Account with Wi-Fi and Bluetooth enabled

---

## License & Attribution

Released under the [MIT License](LICENSE).

AirSnap started from and builds upon [techjuicelab/continuity-capture](https://github.com/techjuicelab/continuity-capture) (MIT License, Copyright (c) 2026 TechJuiceLab), redesigned with a menu bar host, customizable Carbon global hotkeys, offline-only builds, per-user temp auto-cleanup, GPS metadata stripping, upright PNG clipboard output, invisible window teardown, Chinese localization, and window-title-verified auto-paste.
