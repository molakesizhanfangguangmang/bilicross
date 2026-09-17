# BiliHarbor

BiliHarbor is a Flutter client for local Bilibili media workflows.

This repository is at the cloud-build baseline stage. The current UI is a non-functional shell used to validate Windows and Android release builds before parser, authentication, download, and muxing code is introduced.

## Initial targets

- Windows x64
- Android arm64-v8a, Android 8.0 (API 26) or newer
- iOS unsigned IPA later

## Planned architecture

- Dart is the primary parsing and download engine on every platform.
- Windows can switch individual tasks to a bundled BBDownNext compatibility engine.
- Authentication supports pasted cookies, Netscape cookie-file import, and embedded web login.
- APP token acquisition follows WEB Cookie -> browser authorization -> poll -> token.
- Muxing only remuxes selected streams; it does not transcode.

## Builds

The `Cloud build` GitHub Actions workflow installs Flutter stable on clean runners, generates the platform shells, runs formatting checks, analysis and widget tests, and builds:

- `BiliHarbor-android-arm64`
- `BiliHarbor-windows-x64`

Local build products are intentionally not used for releases.
