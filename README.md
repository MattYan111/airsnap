<p align="center">
  <img src="icon.png" width="128" alt="AirSnap">
</p>

<h1 align="center">AirSnap</h1>

<p align="center">
  Mac 按下 <code>⌥⌘C</code> 直接唤起 iPhone 拍照，自动贴进当前对话框。<br>
  纯离线 · 零广告 · 照片不留桌面
</p>

<p align="center">
  <a href="https://github.com/MattYan111/airsnap/releases/latest">下载安装包 (Releases)</a> · <a href="#english">English</a>
</p>

---

## 简介

写文档或跟 AI（ChatGPT、Claude、Antigravity、微信等）聊天时，想拍一张桌面的纸质资料或实物，不用掏手机、拍照、AirDrop、再拖拽。按下快捷键，直接用 iPhone 拍完贴入输入框。

---

## 安装

### 方式 A：下载安装包（最快）

1. 前往 [Releases](https://github.com/MattYan111/airsnap/releases/latest) 下载 `AirSnap-1.0.0-macOS-universal.zip` 解压。
2. 将 `AirSnap.app` 拖进「应用程序」（`/Applications`）。
3. 首次打开如遇“无法验证开发者”或拦截提示，终端运行一行命令解锁：
   ```bash
   xattr -dr com.apple.quarantine /Applications/AirSnap.app
   ```

### 方式 B：一行命令源码安装（免拦截，需 Xcode 命令行工具）

```bash
curl -fsSL https://raw.githubusercontent.com/MattYan111/airsnap/main/install.sh | zsh
```

---

## 使用

**前提**：Mac 和 iPhone 登录同一 Apple ID，双方开启 Wi-Fi 和蓝牙。

1. 打开 `AirSnap`，顶部菜单栏出现相机图标。
2. 把光标点进任意对话框或输入框，按 **`⌥⌘C`**。
3. 手机自动打开相机，拍照后点 **“使用照片”**，照片自动贴入当前输入框。

> **菜单栏选项**（点击顶部相机图标）：
> - **设置快捷键…**：随时把 `⌥⌘C` 改成你顺手的键位
> - **拍完自动写入当前对话框**：默认开启；关掉后改为手动 `⌘V` 粘贴
> - **开机自动启动**：按需勾选

---

## 隐私与安全

- **不联网、无自动更新**：纯调用苹果系统本地框架，没有网络请求和遥测代码。
- **不留存桌面**：照片仅暂存于当前用户专属临时目录（`$TMPDIR/airsnap-runtime/captures`），拍新自动删旧，重启清空，不会同步到 iCloud。
- **清除定位与防误粘**：自动剥离照片 GPS 信息；若拍照期间你切换了浏览器标签页或聊天窗口，会中止自动粘贴并只留在剪贴板，防止发错对象。
- **最小权限**：无需摄像头或完全磁盘权限；仅“自动粘贴”需授予辅助功能权限，关闭后可零权限运行。

---

<a name="english"></a>

## English

Trigger your iPhone camera with `⌥⌘C` on Mac and paste photos straight into any chat box. 100% offline, no desktop clutter.

### Install

- **Download**: Grab `AirSnap-1.0.0-macOS-universal.zip` from [Releases](https://github.com/MattYan111/airsnap/releases/latest), move `AirSnap.app` to `/Applications`, and run `xattr -dr com.apple.quarantine /Applications/AirSnap.app` if prompted.
- **Build from source**:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/MattYan111/airsnap/main/install.sh | zsh
  ```

### Usage

1. Sign Mac and iPhone into the same Apple Account with Wi-Fi and Bluetooth on.
2. Launch `AirSnap` (camera icon appears in menu bar).
3. Focus any input box, press **`⌥⌘C`**, snap on iPhone, and tap **Use Photo** — the image pastes right in (with GPS stripped and window-title safety check).

---

## License

[MIT](LICENSE) · Based on [techjuicelab/continuity-capture](https://github.com/techjuicelab/continuity-capture).
