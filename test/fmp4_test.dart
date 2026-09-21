import 'dart:io';
import 'dart:typed_data';

import 'package:bilicross/src/core/abort.dart';
import 'package:bilicross/src/core/bili_api.dart';
import 'package:bilicross/src/core/fmp4.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _be32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];

List<int> _be16(int value) => [(value >> 8) & 0xff, value & 0xff];

/// 带版本与标志字节的盒子。测试里一律 version = 0。
Uint8List _fullBox(String type, int flags, List<int> body) => buildMp4Box(type, [
      Uint8List.fromList([
        0,
        (flags >> 16) & 0xff,
        (flags >> 8) & 0xff,
        flags & 0xff,
        ...body,
      ]),
    ]);

Uint8List _ftyp() => buildMp4Box('ftyp', [
      Uint8List.fromList(<int>[
        ...'isom'.codeUnits,
        ..._be32(0x200),
        ...'isom'.codeUnits,
        ...'mp41'.codeUnits,
      ]),
    ]);

Uint8List _mvhd({required int timescale, required int nextTrackId}) =>
    _fullBox('mvhd', 0, <int>[
      ..._be32(0),
      ..._be32(0),
      ..._be32(timescale),
      ..._be32(0),
      ..._be32(0x00010000),
      ..._be16(0x0100),
      ..._be16(0),
      ..._be32(0),
      ..._be32(0),
      ...List<int>.filled(36, 0),
      ...List<int>.filled(24, 0),
      ..._be32(nextTrackId),
    ]);

Uint8List _tkhd(int trackId) => _fullBox('tkhd', 0x000007, <int>[
      ..._be32(0),
      ..._be32(0),
      ..._be32(trackId),
      ..._be32(0),
      ..._be32(0),
      ...List<int>.filled(8, 0),
      ..._be16(0),
      ..._be16(0),
      ..._be16(0),
      ..._be16(0),
      ...List<int>.filled(36, 0),
      ..._be32(0),
      ..._be32(0),
    ]);

Uint8List _mdhd(int timescale) => _fullBox('mdhd', 0, <int>[
      ..._be32(0),
      ..._be32(0),
      ..._be32(timescale),
      ..._be32(0),
      ..._be16(0x55c4),
      ..._be16(0),
    ]);

Uint8List _trak(int trackId, int timescale) => buildMp4Box('trak', [
      _tkhd(trackId),
      buildMp4Box('mdia', [_mdhd(timescale)]),
    ]);

Uint8List _moov({
  required int trackId,
  required int timescale,
  required int movieTimescale,
  required int movieDuration,
}) =>
    buildMp4Box('moov', [
      _mvhd(timescale: movieTimescale, nextTrackId: trackId + 1),
      _trak(trackId, timescale),
      buildMp4Box('mvex', [
        _fullBox('mehd', 0, _be32(movieDuration)),
        _fullBox('trex', 0, <int>[
          ..._be32(trackId),
          ..._be32(1),
          ..._be32(1000),
          ..._be32(1000),
          ..._be32(0),
        ]),
      ]),
    ]);

/// tfhd 里基础偏移字段的字节位置：moof 头 + mfhd + traf 头 + tfhd 头 + 版本/标志 + track_ID。
const int _baseOffsetPlaceholder = 8 + 16 + 8 + 8 + 4 + 4;

Uint8List _fragment({
  required int trackId,
  required int decodeTime,
  required int sequence,
  required bool baseDataOffset,
}) {
  final flags = (baseDataOffset ? 0x000001 : 0x020000) | 0x000008;
  return buildMp4Box('moof', [
    _fullBox('mfhd', 0, _be32(sequence)),
    buildMp4Box('traf', [
      _fullBox('tfhd', flags, <int>[
        ..._be32(trackId),
        if (baseDataOffset) ..._be32(0),
        if (baseDataOffset) ..._be32(0),
        ..._be32(1000),
      ]),
      _fullBox('tfdt', 0, _be32(decodeTime)),
      _fullBox('trun', 0x000001, <int>[..._be32(10), ..._be32(0)]),
    ]),
  ]);
}

/// 造一份分片 MP4：ftyp + moov + 若干 moof/mdat。
Uint8List _sourceFile({
  required int trackId,
  required int timescale,
  required int movieTimescale,
  required int decodeStep,
  required int movieDuration,
  required List<List<int>> payloads,
  required bool baseDataOffset,
}) {
  final ftyp = _ftyp();
  final moov = _moov(
    trackId: trackId,
    timescale: timescale,
    movieTimescale: movieTimescale,
    movieDuration: movieDuration,
  );
  final out = BytesBuilder();
  out.add(ftyp);
  out.add(moov);
  var written = ftyp.length + moov.length;
  for (var index = 0; index < payloads.length; index++) {
    final fragment = _fragment(
      trackId: trackId,
      decodeTime: index * decodeStep,
      sequence: index + 1,
      baseDataOffset: baseDataOffset,
    );
    if (baseDataOffset) {
      // 把占位改成「moof 起点 + moof 长度」，也就是紧随其后的 mdat 位置。
      final base = written + fragment.length;
      writeUint32(fragment, _baseOffsetPlaceholder, (base >> 32) & 0xffffffff);
      writeUint32(fragment, _baseOffsetPlaceholder + 4, base & 0xffffffff);
    }
    out.add(fragment);
    out.add(buildMp4Box('mdat', [Uint8List.fromList(payloads[index])]));
    written += fragment.length + 8 + payloads[index].length;
  }
  return out.takeBytes();
}

Uint8List _noFragmentFile() {
  final ftyp = _ftyp();
  final moov = _moov(
    trackId: 1,
    timescale: 90000,
    movieTimescale: 1000,
    movieDuration: 1000,
  );
  return Uint8List.fromList(<int>[...ftyp, ...moov]);
}

class _Inspected {
  const _Inspected({required this.boxes, required this.data});

  final List<Mp4Box> boxes;
  final Uint8List data;

  List<Mp4Box> children(Mp4Box box) => mp4Boxes(data, box.bodyStart, box.end);

  Mp4Box child(Mp4Box box, String type) =>
      children(box).firstWhere((item) => item.type == type);
}

Future<_Inspected> _inspect(String path) async {
  final data = await File(path).readAsBytes();
  return _Inspected(boxes: mp4Boxes(data, 0, data.length), data: data);
}

int _tkhdTrackId(_Inspected inspected, Mp4Box trak) {
  final tkhd = inspected.child(trak, 'tkhd');
  return readUint32(inspected.data, tkhd.bodyStart + 12);
}

int _trexTrackId(_Inspected inspected, Mp4Box trex) =>
    readUint32(inspected.data, trex.bodyStart + 4);

int _tfhdTrackId(_Inspected inspected, Mp4Box traf) {
  final tfhd = inspected.child(traf, 'tfhd');
  return readUint32(inspected.data, tfhd.bodyStart + 4);
}

int _tfhdBaseOffset(_Inspected inspected, Mp4Box traf) {
  final tfhd = inspected.child(traf, 'tfhd');
  return readUint64(inspected.data, tfhd.bodyStart + 8);
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('bilicross-fmp4');
  });

  tearDown(() async {
    // 后台 isolate 刚退出时文件句柄可能还没释放（Windows 会锁文件），重试几次。
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!await work.exists()) return;
      try {
        await work.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('把两条分片流按解码时间交替换成一个双轨 MP4', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}video.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await File(videoPath).writeAsBytes(_sourceFile(
      trackId: 1,
      timescale: 90000,
      movieTimescale: 1000,
      decodeStep: 90000,
      movieDuration: 3000,
      payloads: [
        [1, 1, 1],
        [2, 2, 2, 2],
        [3, 3, 3],
      ],
      baseDataOffset: false,
    ));
    await File(audioPath).writeAsBytes(_sourceFile(
      trackId: 1,
      timescale: 44100,
      movieTimescale: 1000,
      decodeStep: 44100,
      movieDuration: 2000,
      payloads: [
        [9, 9],
        [8, 8, 8],
      ],
      baseDataOffset: false,
    ));

    final result = await Fmp4Merger.merge(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
    );

    expect(result.fragments, 5);
    expect(result.durationSeconds, 3.0);
    expect(result.bytes, await File(outputPath).length());

    final inspected = await _inspect(outputPath);
    expect(
      inspected.boxes.map((box) => box.type).toList(),
      ['ftyp', 'moov', 'moof', 'mdat', 'moof', 'mdat', 'moof', 'mdat', 'moof', 'mdat', 'moof', 'mdat'],
    );

    final moov = inspected.boxes[1];
    expect(
      inspected.children(moov).map((box) => box.type).toList(),
      ['mvhd', 'trak', 'trak', 'mvex'],
    );
    final traks = inspected.children(moov).where((box) => box.type == 'trak').toList();
    expect(traks.map((trak) => _tkhdTrackId(inspected, trak)).toList(), [1, 2]);
    final mvhd = inspected.child(moov, 'mvhd');
    expect(readUint32(inspected.data, mvhd.end - 4), 3);

    final mvex = inspected.child(moov, 'mvex');
    expect(
      inspected.children(mvex).map((box) => box.type).toList(),
      ['mehd', 'trex', 'trex'],
    );
    final mehd = inspected.child(mvex, 'mehd');
    expect(readUint32(inspected.data, mehd.bodyStart + 4), 3000);
    expect(
      inspected
          .children(mvex)
          .where((box) => box.type == 'trex')
          .map((trex) => _trexTrackId(inspected, trex))
          .toList(),
      [1, 2],
    );

    final trackIds = <int>[];
    final payloads = <List<int>>[];
    for (var index = 2; index < inspected.boxes.length; index += 2) {
      final moof = inspected.boxes[index];
      final traf = inspected.child(moof, 'traf');
      trackIds.add(_tfhdTrackId(inspected, traf));
      final mdat = inspected.boxes[index + 1];
      payloads.add(inspected.data.sublist(mdat.bodyStart, mdat.end).toList());
      // 分片里的数据偏移是相对 moof 起点的，保持相邻关系即保持有效。
      expect(mdat.start, moof.end);
    }
    expect(trackIds, [1, 2, 1, 2, 1]);
    expect(payloads, [
      [1, 1, 1],
      [9, 9],
      [2, 2, 2, 2],
      [8, 8, 8],
      [3, 3, 3],
    ]);
  });

  test('tfhd 带基础偏移时按 moof 相对位置重算', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}video.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await File(videoPath).writeAsBytes(_sourceFile(
      trackId: 1,
      timescale: 90000,
      movieTimescale: 1000,
      decodeStep: 90000,
      movieDuration: 2000,
      payloads: [
        [1, 1],
        [2, 2],
      ],
      baseDataOffset: true,
    ));
    await File(audioPath).writeAsBytes(_sourceFile(
      trackId: 3,
      timescale: 44100,
      movieTimescale: 1000,
      decodeStep: 44100,
      movieDuration: 2000,
      payloads: [
        [7, 7],
        [6, 6],
      ],
      baseDataOffset: true,
    ));

    await Fmp4Merger.merge(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
    );

    final inspected = await _inspect(outputPath);
    for (var index = 2; index < inspected.boxes.length; index += 2) {
      final moof = inspected.boxes[index];
      final traf = inspected.child(moof, 'traf');
      // 基础偏移指向紧随 moof 之后的 mdat。
      expect(_tfhdBaseOffset(inspected, traf), moof.start + moof.size);
    }
  });

  test('音频轨道号与视频撞号时另选一个', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}video.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await File(videoPath).writeAsBytes(_sourceFile(
      trackId: 2,
      timescale: 90000,
      movieTimescale: 1000,
      decodeStep: 90000,
      movieDuration: 1000,
      payloads: [
        [1],
      ],
      baseDataOffset: false,
    ));
    await File(audioPath).writeAsBytes(_sourceFile(
      trackId: 2,
      timescale: 44100,
      movieTimescale: 1000,
      decodeStep: 44100,
      movieDuration: 1000,
      payloads: [
        [5],
      ],
      baseDataOffset: false,
    ));

    await Fmp4Merger.merge(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
    );

    final inspected = await _inspect(outputPath);
    final moov = inspected.boxes[1];
    final traks = inspected.children(moov).where((box) => box.type == 'trak').toList();
    expect(traks.map((trak) => _tkhdTrackId(inspected, trak)).toList(), [2, 3]);
    final ids = <int>[];
    for (var index = 2; index < inspected.boxes.length; index += 2) {
      ids.add(_tfhdTrackId(inspected, inspected.child(inspected.boxes[index], 'traf')));
    }
    expect(ids, [2, 3]);
  });

  test('不是分片 MP4 时明确报错', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}plain.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await File(videoPath).writeAsBytes(_noFragmentFile());
    await File(audioPath).writeAsBytes(_sourceFile(
      trackId: 1,
      timescale: 44100,
      movieTimescale: 1000,
      decodeStep: 44100,
      movieDuration: 1000,
      payloads: [
        [1],
      ],
      baseDataOffset: false,
    ));

    await expectLater(
      Fmp4Merger.merge(
        videoPath: videoPath,
        audioPath: audioPath,
        outputPath: outputPath,
      ),
      throwsA(isA<BiliException>()),
    );
    expect(await File(outputPath).exists(), isFalse);
    expect(await File('$outputPath.part').exists(), isFalse);
  });

  test('进度按分片回传，末次等于总字节数', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}video.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await _writePair(videoPath, audioPath);

    final writtens = <int>[];
    final totals = <int>[];
    final result = await Fmp4Merger.merge(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
      onProgress: (written, total) {
        writtens.add(written);
        totals.add(total);
      },
    );

    // 每个分片一次，不多不少。
    expect(writtens.length, 5);
    expect(totals.toSet(), {result.bytes});
    expect(writtens.last, result.bytes);
    for (var index = 1; index < writtens.length; index++) {
      expect(writtens[index], greaterThan(writtens[index - 1]));
    }
  });

  test('合并中途取消：抛 TaskAborted，不留半成品', () async {
    final videoPath = '${work.path}${Platform.pathSeparator}video.m4s';
    final audioPath = '${work.path}${Platform.pathSeparator}audio.m4s';
    final outputPath = '${work.path}${Platform.pathSeparator}merged.mp4';
    await _writePair(videoPath, audioPath);

    final control = AbortControl();
    var calls = 0;
    await expectLater(
      Fmp4Merger.merge(
        videoPath: videoPath,
        audioPath: audioPath,
        outputPath: outputPath,
        control: control,
        onProgress: (written, total) {
          calls += 1;
          if (calls == 1) control.stop();
        },
      ),
      throwsA(isA<TaskAborted>()),
    );
    // 取消之后不再往界面推进度。
    expect(calls, lessThan(5));
    expect(await File(outputPath).exists(), isFalse);
    expect(await File('$outputPath.part').exists(), isFalse);
  });
}

/// 3 片视频 + 2 片音频，一共 5 个分片。
Future<void> _writePair(String videoPath, String audioPath) async {
  await File(videoPath).writeAsBytes(_sourceFile(
    trackId: 1,
    timescale: 90000,
    movieTimescale: 1000,
    decodeStep: 90000,
    movieDuration: 3000,
    payloads: [
      [1, 1, 1],
      [2, 2, 2, 2],
      [3, 3, 3],
    ],
    baseDataOffset: false,
  ));
  await File(audioPath).writeAsBytes(_sourceFile(
    trackId: 1,
    timescale: 44100,
    movieTimescale: 1000,
    decodeStep: 44100,
    movieDuration: 2000,
    payloads: [
      [9, 9],
      [8, 8, 8],
    ],
    baseDataOffset: false,
  ));
}
