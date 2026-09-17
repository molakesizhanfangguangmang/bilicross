# BiliHarbor

BiliHarbor is a Flutter client for local Bilibili media workflows.

Current stage: first-version features are wired into the app and the cloud build
produces installable Windows and Android artifacts. Everything runs locally on the
device; there is no remote service.

## Initial targets

- Windows x64
- Android arm64-v8a, Android 8.0 (API 26) or newer
- iOS unsigned IPA later

## What works now

- Address recognition for `BV`/`av` videos, `b23.tv` short links, bangumi `ep`/`ss`
  and cheese episodes, including multi-part `?p=` selection.
- Two parsing channels: the WBI-signed web channel (`/x/player/wbi/playurl`) and the
  signed APP channel (`/x/player/playurl`). The APP channel is used first when
  `preferAppApi` is enabled and an APP token exists; a failed channel falls back to the
  other one and the channel actually used is recorded on the task.
- Stream selection from the DASH payload: video tracks sorted by quality then codec
  preference (AVC first), audio tracks including FLAC and Dolby entries.
- WEB Cookie handling: paste, `cookie.txt` import (Netscape and request-header forms),
  `/x/web-interface/nav` validation, account and VIP display. Only field presence and
  masked values are shown.
- APP token: WEB Cookie -> `auth_code` -> system browser authorization -> poll every
  2 seconds -> token written only after a complete response. Old tokens are kept when
  acquisition fails.
- Downloads: per file up to 8 parallel `Range` connections (splitting into chunks under
  `.partN` files that each resume on their own), falling back to a single connection when
  the server ignores `Range`, when the file is small, or when a partially written `.part`
  is already there. Backup URL fallback, queue with a configurable parallel limit, task
  persistence and restart recovery. Stale CDN URLs are re-resolved before resuming.
- Merging without external tools: `Fmp4Merger`, the built-in merge, rebuilds one `moov` with
  both tracks (the audio track gets a fresh `track_ID`), rewrites the audio fragments'
  `tfhd` accordingly, and interleaves `moof`+`mdat` pairs by `tfdt` decode time. Sample
  data is copied as is: no re-encode, no rebuild of the sample tables, and `trun` data
  offsets stay valid because `base_data_offset`, when present, is recomputed relative to
  the new `moof` position.
- Merging with ffmpeg: when an `ffmpeg` binary is configured or found on `PATH`, it is
  used first (`-c copy`, no transcoding) because it emits a plain MP4. The built-in merge
  is the fallback, and the engine actually used is written into the task message.
- Failed merges keep both parts and say why in the task message; a separate "retry merge"
  action re-runs only the merge step.

## Not wired yet

- Embedded web login (a web view that captures cookies). Use paste or `cookie.txt`.
- Bundled FFmpeg binary. It is not required any more: the built-in merge covers machines
  without `ffmpeg`.
- BBDownNext compatibility engine (bundled `serve` on Windows) and the engine switch.
- Secure credential storage: settings, cookies and tasks are stored as JSON under the
  application support directory, with timestamped backups for credentials.

## Layout

- `lib/src/core` — address parsing, signing, API access, DASH building, downloads,
  remux, persistence. No Flutter imports except for `foundation` notifications.
- `lib/src/ui` — the four pages: downloads, tasks, account, settings.
- `test/app_test.dart` — offline checks for address parsing, cookie parsing, WBI and APP
  signing vectors, DASH stream building and formatting helpers.
- `test/fmp4_test.dart` — builds fragmented MP4 fixtures and checks track renumbering,
  fragment interleaving, `base_data_offset` rewriting and the non-fragmented error path.
- `test/downloader_test.dart` — runs a local `HttpServer` to check parallel range
  downloads, the single-connection fallback and resume against a partial `.part`.

## Builds

The `Cloud build` GitHub Actions workflow installs Flutter stable on clean runners,
generates the platform shells, patches the Android manifest (API 26, `INTERNET`
permission, `url_launcher` queries), runs formatting, analysis and tests, and builds:

- `BiliHarbor-android-arm64`
- `BiliHarbor-windows-x64`

Local build products are intentionally not used for releases.
