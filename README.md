# 逸轨（BiliCross）

<img src="packaging/icon/app_icon.png" width="120" alt="逸轨">

逸轨是一个本地运行的 B 站媒体下载与整理客户端。界面用 Flutter 写，核心能力用 Dart 实现，
解析、下载、合并都在本机完成，不依赖外部服务。

当前版本：1.0.0（正式版）。

## 平台

- Windows x64
- Android arm64-v8a，最低 Android 8.0（API 26）

## 能做什么

- 识别 `BV`/`av` 号、`b23.tv` 短链、番剧 `ep`/`ss` 与课程地址，支持分 P 选择。
- 两条解析通道：WBI 签名的网页通道与 APP 签名通道；APP 通道需要 Token。一条失败自动回退，
  实际用的通道记在任务上。
- 档位可选，顺序为 8K、HDR Vivid、杜比视界、HDR、4K……视频轨与音频轨可以各自保留或取消。
- 下载：单文件最多 8 个 Range 分片并行，断点续传，队列限流；地址过期时按任务原本的档位重新解析。
- 合并：优先用 ffmpeg 流复制；没有 ffmpeg 时用内置 fMP4 合并，按 `moof`/`mdat` 拼接，不重编码。
- 账号：网页 Cookie（粘贴或导入 `cookie.txt`）与 APP Token，凭据只保存在本机并留有备份。

## 从哪拿安装包

云编译产物在 Actions 的 `Cloud build` 工作流里：Android 出 APK，Windows 出 ZIP。
本机不做编译，本地构建产物不用于发布。

## 构建

推送到 `main` 或手动触发 `Cloud build`。工作流在干净的 runner 上安装 Flutter stable、
生成平台壳、注入图标与显示名、配置发布签名，跑 `flutter analyze` 与 `flutter test` 后出包。

## 目录

- `lib/src/core` — 地址解析、签名、接口访问、DASH 组装、下载、合并、持久化。
- `lib/src/ui` — 下载、任务、账号、设置四个页面。
- `test` — 离线测试：地址与 Cookie 解析、签名向量、DASH 组装、分片下载、fMP4 合并、档位选择。
- `packaging` — 图标资源：Android 各密度图标与自适应图标、Windows `ico`。

## 贡献者

- tricky — 作者，需求与验收

致谢：BBDownNext（KaiHuaDou）、neo-BBDown（bili-vd-bak，BBDown 的 Deno 实现）提供行为参考；
bilibili-API-collect（SocialSisterYi）提供接口资料。

## 说明

仅供个人备份自己有权访问的内容。
