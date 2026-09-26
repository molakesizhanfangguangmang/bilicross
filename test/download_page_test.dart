import 'dart:io';

import 'package:bilicross/src/app_state.dart';
import 'package:bilicross/src/core/models.dart';
import 'package:bilicross/src/core/store.dart';
import 'package:bilicross/src/ui/download_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下载页最基础的两态：空态给占位，解析出结果后列出视频流与音频流、
/// 给出入队按钮。不发起网络，只在内存态上验证 UI 结构。
void main() {
  late Directory root;
  late AppState state;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bilicross_download_page');
    state = AppState.forTest(
      store: Store.at(root),
      settings: AppSettings(downloadDir: root.path),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ParsedMedia media() => ParsedMedia(
        info: const VideoInfo(
          bvid: 'BV0000000001',
          aid: 1,
          title: '示例视频',
          owner: 'UP 主',
          cover: '',
          durationSec: 120,
          pages: <PlayPage>[PlayPage(page: 1, cid: 11, part: 'P1', durationSec: 120)],
        ),
        page: const PlayPage(page: 1, cid: 11, part: 'P1', durationSec: 120),
        videos: <MediaStream>[
          MediaStream(
            id: 80,
            label: '1080P',
            codecs: 'avc1.640032',
            bandwidth: 900000,
            url: 'https://cdn.example/v80.m4s',
            width: 1920,
            height: 1080,
          ),
        ],
        audios: <MediaStream>[
          MediaStream(
            id: 30280,
            label: '192K',
            codecs: 'mp4a.40.2',
            bandwidth: 203786,
            url: 'https://cdn.example/a192.m4s',
          ),
        ],
        durationSec: 120,
        channel: 'APP',
        guestLimited: false,
      );

  testWidgets('未解析时显示空态', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DownloadPage(state: state))),
    );
    expect(find.text('等待解析'), findsOneWidget);
  });

  testWidgets('解析出结果后列出流与入队按钮', (tester) async {
    state.parsed = media();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DownloadPage(state: state))),
    );
    await tester.pump();

    expect(find.text('示例视频'), findsOneWidget);
    expect(find.text('1080P · 1920x1080 · AVC · 900 Kbps'), findsOneWidget);
    expect(find.text('192K · AAC · 204 Kbps'), findsOneWidget);
    expect(find.text('加入任务（视频 + 音频）'), findsOneWidget);
    expect(find.text('立即开始下载'), findsOneWidget);
  });
}
