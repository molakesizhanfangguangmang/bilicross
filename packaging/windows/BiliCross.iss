; 逸轨 BiliCross 安装包脚本（Inno Setup 6）
; 注意：Inno Setup 把所有相对路径都按「本脚本所在目录」解析，
; 本脚本在 packaging\windows\ 下，所以所有路径都相对它来写：
;   app_icon.ico            -> packaging\windows\app_icon.ico
;   ..\..\build\...         -> 仓库根\build\...
;   ..\..\tools\...         -> 仓库根\tools\...
;   OutputDir=..\..         -> 仓库根（CI 在仓库根检查与上传产物）
;
; 打包 Windows 安装版：程序装到 %LOCALAPPDATA%\Programs\BiliCross，
; 数据目录由应用按通道决定落在 %LOCALAPPDATA%\BiliCross。
; 安装版不带 portable.marker（靠构建期常量认通道），故走安装版数据位置。
;
; 架构由构建时注入：ISCC /DMyAppArch=arm64；未注入时按 x64 出包。
; ⚠️ 源码目录与产物名都跟着 MyAppArch 走，改这里就别再写死 x64。
; ⚠️ arm64 需要 Inno Setup 6.3+（低版本会报 unknown architecture）。

#define MyAppName "逸轨 BiliCross"
; 版本号可由构建时注入：ISCC /DMyAppVersion=2.1.5；未注入时用下面的兜底值。
#ifndef MyAppVersion
  #define MyAppVersion "2.1.5"
#endif
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif
#define MyAppExeName "bilicross.exe"
; AppId 必须保持不变：它决定安装器是否把新版识别为「同一个应用的升级」。
; 一旦改动，新版本会与旧版本并存而不是覆盖安装，用户会看到两个逸轨。
#define MyAppId "BiliCross-1-0-6-stable"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\BiliCross
DefaultGroupName=BiliCross
OutputDir=..\..
OutputBaseFilename=BiliCross-windows-{#MyAppArch}-setup
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode={#MyAppArch}
; x64 包沿用旧行为（不限制可安装架构）；arm64 包必须限制，否则会被装到 x64 机器上。
#if MyAppArch == "arm64"
ArchitecturesAllowed=arm64
#endif
WizardStyle=modern
; 关闭行为由应用内设置控制（默认最小化到托盘），安装包不碰。

[Files]
Source: "..\..\build\windows\{#MyAppArch}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\tools\ffmpeg\ffmpeg.exe"; DestDir: "{app}\tools\ffmpeg"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\BiliCross"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\BiliCross"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 逸轨 BiliCross"; Flags: nowait postinstall skipifsilent
