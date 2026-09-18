# 逸轨（BiliCross）

<img src="packaging/icon/app_icon.png" width="120" alt="逸轨">

逸轨是一个本地运行的 B 站媒体下载与整理客户端。界面用 Flutter 写，核心能力用 Dart 实现，
解析、下载、合并都在本机完成，不依赖外部服务。

当前版本：1.0.6（正式版）。

## 平台

- Windows x64
- Android arm64-v8a，最低 Android 8.0（API 26）

## 能做什么

- 识别 `BV`/`av` 号、`b23.tv` 短链、番剧 `ep`/`ss` 与课程地址，支持分 P 选择。
- 两条解析通道：WBI 签名的网页通道与 APP 签名通道；APP 通道需要 Token。一条失败自动回退，
  实际用的通道记在任务上。
- 档位可选，顺序为 8K、HDR Vivid、杜比视界、HDR、4K……视频轨与音频轨可以各自保留或取消。
- 下载：单文件最多 8 个 Range 分片并行，断点续传，队列限流；地址过期时按任务原本的档位重新解析。
- 任务可控：下载中可以暂停（分片留着，继续时按断点接），也可以强制结束（连同分片一起删掉）。
  空闲超过 30 秒没有数据的连接会被断开重连，不会停在最后一点等下去。
- 队列由人启动：解析页的「加入任务」只是排进队列，点「立即开始下载」或在任务页点「开始任务」才开跑，
  重开程序也一样；队列已经在跑时，新入队的任务自己跟在后面下。同时在跑几条在设置页可调。
- 合并：优先用 ffmpeg 流复制；没有 ffmpeg 时用内置 fMP4 合并，按 `moof`/`mdat` 拼接，不重编码。
- 界面语言：设置页可切换「跟随系统 / 简体中文 / English」，界面、任务状态与提示同步切换，
  选择会保存，重启后保持。
- 账号：扫码登录（应用内显示 B 站二维码，手机客户端确认）、网页登录、粘贴 Cookie 或导入 `cookie.txt`，
  三条路都只取同一份网页 Cookie，之后照旧走 APP Token 授权；凭据只保存在本机并留有备份。
  Windows 的网页登录在应用内用 WebView2 打开登录页，登录完成后自动取 Cookie；
  需要系统安装 Microsoft Edge WebView2 运行时。
- 关于：设置页底部有入口，弹窗里是应用图标、项目地址与当前版本号。Android 与 Windows 上可以点
  「检测更新」查有没有新的正式版，启动后也会静默查一次，有新版再问要不要去 Release 页。
- 备份与恢复（Windows）：设置页里可以导出应用备份，也可以从备份恢复，用于在 Windows 安装版与
  便携版之间迁移账号信息、设置与任务。恢复操作将覆盖当前应用数据，覆盖前会自动留一份回滚备份，
  请妥善保管备份文件。
- 桌面行为（Windows）：关闭窗口默认最小化到系统托盘，下载继续；托盘菜单可以显示主窗口、
  打开下载目录、暂停全部任务与退出；还有任务在跑时退出会先确认。设置页可以改成「关闭即退出」。
- 启动自检（Windows）：启动时检查数据目录可写、应用资源可读、WebView2 运行时可用；
  缺任一项会直接说明缺什么并退出，不带病进界面。

## 从哪拿安装包

云编译产物在 Actions 的 `Cloud build` 工作流里。Android 出 APK；Windows 出两种包：

- 安装版 `BiliCross-windows-x64-setup.exe`：Inno Setup 安装包，装到用户目录，数据放在
  `%LOCALAPPDATA%\BiliCross`，可从「检测更新」跳 Release 页下载新安装包覆盖安装。
- 便携版 `BiliCross-windows-x64-portable.zip`：解压即用，数据放在程序旁的 `data` 目录，
  不提供自动更新，需要新版本时自行到 Release 页下载替换。

两种包都自带 `ffmpeg.exe`（随包放在 `tools\ffmpeg`），合并默认用它；没有也能跑，
会自动回落到内置 fMP4 合并。系统需要 Microsoft Visual C++ 运行库（Windows 10/11 通常已有）；
程序目录请保留 `ffmpeg.exe`，删掉只会降级合并方式，不影响其它功能。

本机不做编译，本地构建产物不用于发布。

## 构建

推送到 `main` 或手动触发 `Cloud build`。工作流在干净的 runner 上安装 Flutter stable、
生成平台壳、注入图标与显示名、配置发布签名，跑 `flutter analyze` 与 `flutter test` 后出包。

## 目录

- `lib/src/core` — 地址解析、签名、接口访问、DASH 组装、下载、合并、备份、持久化。
- `lib/src/platform/windows` — Windows 专用外壳：托盘子窗口行为、WebView2 网页登录。
- `lib/src/ui` — 下载、任务、账号、设置四个页面，以及启动自检阻塞页。
- `test` — 离线测试：地址与 Cookie 解析、签名向量、DASH 组装、分片下载、暂停与强制结束、fMP4 合并、档位选择、版本号比较与更新检查、发行通道与数据目录、备份编解码与服务、启动自检。
- `packaging` — 图标资源（Android 各密度图标与自适应图标、Windows `ico`）与 Inno Setup 安装脚本。

## 贡献者

- tricky — 作者，需求与验收

致谢：BBDownNext（KaiHuaDou）、neo-BBDown（bili-vd-bak，BBDown 的 Deno 实现）提供行为参考；
bilibili-API-collect（SocialSisterYi）提供接口资料。

## 说明

仅供个人备份自己有权访问的内容。
