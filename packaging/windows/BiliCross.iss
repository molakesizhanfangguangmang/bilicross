; 逸轨 BiliCross 安装包脚本（Inno Setup 6）
; 仅打包 Windows x64 安装版：程序装到 %LOCALAPPDATA%\Programs\BiliCross，
; 数据目录由应用按通道决定落在 %LOCALAPPDATA%\BiliCross。
; 安装版不带 portable.marker（靠构建期常量认通道），故走安装版数据位置。

#define MyAppName "逸轨 BiliCross"
#define MyAppVersion "1.0.6"
#define MyAppExeName "bilicross.exe"
#define MyAppId "BiliCross-1-0-6-stable"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\BiliCross
DefaultGroupName=BiliCross
OutputDir=.
OutputBaseFilename=BiliCross-windows-x64-setup
SetupIconFile=packaging\windows\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
; 关闭行为由应用内设置控制（默认最小化到托盘），安装包不碰。

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "tools\ffmpeg\ffmpeg.exe"; DestDir: "{app}\tools\ffmpeg"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\BiliCross"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\BiliCross"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 逸轨 BiliCross"; Flags: nowait postinstall skipifsilent
