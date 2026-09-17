import 'dart:io';
import 'dart:typed_data';

import 'bili_api.dart';

/// 一个 MP4 盒子。`size` 是整盒长度，`headerSize` 是 8 或 16（64 位长度时）。
class Mp4Box {
  const Mp4Box({
    required this.type,
    required this.start,
    required this.headerSize,
    required this.size,
  });

  final String type;
  final int start;
  final int headerSize;
  final int size;

  int get bodyStart => start + headerSize;
  int get end => start + size;
}

int readUint32(Uint8List data, int offset) =>
    (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];

int readUint64(Uint8List data, int offset) =>
    (readUint32(data, offset) << 32) | readUint32(data, offset + 4);

void writeUint32(Uint8List data, int offset, int value) {
  data[offset] = (value >> 24) & 0xff;
  data[offset + 1] = (value >> 16) & 0xff;
  data[offset + 2] = (value >> 8) & 0xff;
  data[offset + 3] = value & 0xff;
}

void writeUint64(Uint8List data, int offset, int value) {
  writeUint32(data, offset, (value >> 32) & 0xffffffff);
  writeUint32(data, offset + 4, value & 0xffffffff);
}

String readBoxType(Uint8List data, int offset) => String.fromCharCodes(data, offset, offset + 4);

/// 读出一段字节里的同级盒子。遇到长度异常或越界就停下，不抛异常。
List<Mp4Box> mp4Boxes(Uint8List data, int start, int end) {
  final boxes = <Mp4Box>[];
  var offset = start;
  while (offset + 8 <= end) {
    final size32 = readUint32(data, offset);
    final type = readBoxType(data, offset + 4);
    var headerSize = 8;
    var size = size32;
    if (size32 == 1) {
      if (offset + 16 > end) break;
      size = readUint64(data, offset + 8);
      headerSize = 16;
    } else if (size32 == 0) {
      size = end - offset;
    }
    if (size < headerSize || offset + size > end) break;
    boxes.add(Mp4Box(type: type, start: offset, headerSize: headerSize, size: size));
    offset += size;
  }
  return boxes;
}

Uint8List buildMp4Box(String type, List<Uint8List> payloads) {
  var length = 8;
  for (final payload in payloads) {
    length += payload.length;
  }
  final out = Uint8List(length);
  writeUint32(out, 0, length);
  for (var index = 0; index < 4; index++) {
    out[4 + index] = type.codeUnitAt(index);
  }
  var offset = 8;
  for (final payload in payloads) {
    out.setRange(offset, offset + payload.length, payload);
    offset += payload.length;
  }
  return out;
}

class Fmp4MergeResult {
  const Fmp4MergeResult({
    required this.bytes,
    required this.fragments,
    required this.durationSeconds,
  });

  final int bytes;
  final int fragments;
  final double durationSeconds;
}

/// 内置的分片 MP4（m4s）合并。
///
/// DASH 的视频流与音频流各自是一个 moov 开头、后接若干 moof+mdat 的文件，
/// 两条流通常都写 track_ID = 1。这里只做三件事：
///
/// 1. 把两条流的 moov 拼成一个 moov（mvhd 取视频的，音频轨道换成不冲突的 track_ID）；
/// 2. 只把音频片段的 tfhd.track_ID 改成同一个新号，视频片段原样保留；
/// 3. 按 tfdt 解码时间把两边的 moof+mdat 交替写进输出文件。
///
/// 采样数据一律原样搬运，不重新编码，也不重建采样表。tfhd 里带 base_data_offset
/// 时按「相对本 moof 起点的偏移」重算，所以两种写法都能保住 trun 的数据偏移。
/// ffmpeg 是可选的外部路径，这里保证没有 ffmpeg 也能出可播的 MP4。
class Fmp4Merger {
  const Fmp4Merger._();

  static const int _chunkSize = 4 << 20;

  static Future<Fmp4MergeResult> merge({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    void Function(int written, int total)? onProgress,
  }) async {
    final video = await _open(videoPath);
    var tempPath = '';
    IOSink? sink;
    _SourceInfo? audioHandle;
    try {
      final audio = await _open(audioPath);
      audioHandle = audio;
      if (video.fragments.isEmpty) {
        throw BiliException('视频流不是分片 MP4（没有 moof），内置合并无法处理');
      }
      if (audio.fragments.isEmpty) {
        throw BiliException('音频流不是分片 MP4（没有 moof），内置合并无法处理');
      }

      final used = <int>[...video.trackIds];
      final mapping = <int, int>{};
      for (final trackId in audio.trackIds) {
        final candidate = _pickTrackId(used);
        mapping[trackId] = candidate;
        used.add(candidate);
      }

      final audioMoov = _retagMoov(audio.moov, audio.moovHeaderSize, mapping);
      final maxSeconds = video.movieDurationSeconds > audio.movieDurationSeconds
          ? video.movieDurationSeconds
          : audio.movieDurationSeconds;
      final mergedMoov = _buildMoov(
        video: video,
        audioMoov: audioMoov,
        audioMoovHeaderSize: audio.moovHeaderSize,
        mapping: mapping,
        maxDurationSeconds: maxSeconds,
      );

      final entries = <_MergeEntry>[
        for (final fragment in video.fragments)
          _MergeEntry(source: video, fragment: fragment, order: 0),
        for (final fragment in audio.fragments)
          _MergeEntry(source: audio, fragment: fragment, order: 1),
      ]..sort((a, b) {
          final compare = a.fragment.timeSeconds.compareTo(b.fragment.timeSeconds);
          return compare != 0 ? compare : a.order.compareTo(b.order);
        });

      var total = video.ftyp.length + mergedMoov.length;
      for (final entry in entries) {
        total += entry.fragment.moof.length + entry.fragment.mdatSize;
      }

      tempPath = '$outputPath.part';
      final temp = File(tempPath);
      if (await temp.exists()) await temp.delete();
      sink = temp.openWrite();
      var written = 0;
      sink.add(video.ftyp);
      sink.add(mergedMoov);
      written += video.ftyp.length + mergedMoov.length;

      for (final entry in entries) {
        final moof = Uint8List.fromList(entry.fragment.moof);
        final trackMapping = entry.source == audio ? mapping : const <int, int>{};
        _patchMoof(
          moof: moof,
          sourceMoofStart: entry.fragment.moofStart,
          targetMoofStart: written,
          mapping: trackMapping,
        );
        sink.add(moof);
        written += moof.length;
        await _copyRange(entry.source.handle, entry.fragment.mdatStart, entry.fragment.mdatSize, sink);
        written += entry.fragment.mdatSize;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      await _verify(
        tempPath,
        expectedBytes: total,
        expectedFragments: entries.length,
        expectedTrackIds: <int>[...video.trackIds, ...mapping.values],
      );

      final target = File(outputPath);
      if (await target.exists()) await target.delete();
      await File(tempPath).rename(outputPath);
      tempPath = '';

      return Fmp4MergeResult(
        bytes: total,
        fragments: entries.length,
        durationSeconds: maxSeconds,
      );
    } finally {
      if (sink != null) {
        await sink.close();
      }
      if (tempPath.isNotEmpty) {
        final leftover = File(tempPath);
        if (await leftover.exists()) await leftover.delete();
      }
      await video.close();
      if (audioHandle != null) await audioHandle.close();
    }
  }

  /// 选一个不与已有轨道冲突的编号。
  static int _pickTrackId(List<int> used) {
    var candidate = 2;
    while (used.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }

  static Future<_SourceInfo> _open(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw BiliException('文件不存在：$path');
    }
    final handle = await file.open();
    try {
      final length = await handle.length();
      final boxes = await _scanTopLevel(handle, length);
      final ftyp = _findBox(boxes, 'ftyp');
      final moov = _findBox(boxes, 'moov');
      if (ftyp == null) {
        throw BiliException('文件缺少 ftyp：$path');
      }
      if (moov == null) {
        throw BiliException('文件缺少 moov：$path');
      }
      final ftypBytes = await _readAt(handle, ftyp.start, ftyp.size);
      final moovBytes = await _readAt(handle, moov.start, moov.size);
      final facts = _readMoovFacts(moovBytes, moov.headerSize);
      final scan = await _scanFragments(handle, boxes, facts.timescales);
      return _SourceInfo(
        handle: handle,
        ftyp: ftypBytes,
        moov: moovBytes,
        moovHeaderSize: moov.headerSize,
        trackIds: facts.trackIds,
        movieTimescale: facts.movieTimescale,
        movieDurationSeconds: facts.movieDurationSeconds,
        fragments: scan,
      );
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  static Future<List<Mp4Box>> _scanTopLevel(RandomAccessFile handle, int length) async {
    final boxes = <Mp4Box>[];
    var offset = 0;
    while (offset + 8 <= length) {
      final headSize = length - offset < 16 ? length - offset : 16;
      final head = await _readAt(handle, offset, headSize);
      final size32 = readUint32(head, 0);
      final type = readBoxType(head, 4);
      var headerSize = 8;
      var size = size32;
      if (size32 == 1) {
        if (head.length < 16) break;
        size = readUint64(head, 8);
        headerSize = 16;
      } else if (size32 == 0) {
        size = length - offset;
      }
      if (size < headerSize || offset + size > length) break;
      boxes.add(Mp4Box(type: type, start: offset, headerSize: headerSize, size: size));
      offset += size;
    }
    return boxes;
  }

  static Future<Uint8List> _readAt(RandomAccessFile handle, int offset, int size) async {
    final buffer = Uint8List(size);
    var done = 0;
    await handle.setPosition(offset);
    while (done < size) {
      final read = await handle.readInto(buffer, done, size - done);
      if (read <= 0) break;
      done += read;
    }
    if (done != size) {
      throw BiliException('读取文件失败（偏移 $offset，长度 $size）');
    }
    return buffer;
  }

  static Future<void> _copyRange(
    RandomAccessFile handle,
    int offset,
    int size,
    IOSink sink,
  ) async {
    var remaining = size;
    var position = offset;
    while (remaining > 0) {
      final take = remaining < _chunkSize ? remaining : _chunkSize;
      sink.add(await _readAt(handle, position, take));
      position += take;
      remaining -= take;
    }
  }

  static _MoovFacts _readMoovFacts(Uint8List moov, int moovHeaderSize) {
    final children = mp4Boxes(moov, moovHeaderSize, moov.length);
    final mvhd = _findBox(children, 'mvhd');
    if (mvhd == null) {
      throw BiliException('moov 里没有 mvhd');
    }
    final movieTimescale = readUint32(moov, mvhd.bodyStart + (moov[mvhd.bodyStart] == 1 ? 20 : 12));
    final trackIds = <int>[];
    final timescales = <int, int>{};
    for (final trak in children.where((box) => box.type == 'trak')) {
      final trakChildren = mp4Boxes(moov, trak.bodyStart, trak.end);
      final tkhd = _findBox(trakChildren, 'tkhd');
      if (tkhd == null) {
        throw BiliException('trak 里没有 tkhd');
      }
      final trackId = readUint32(moov, tkhd.bodyStart + (moov[tkhd.bodyStart] == 1 ? 20 : 12));
      trackIds.add(trackId);
      final mdia = _findBox(trakChildren, 'mdia');
      if (mdia == null) {
        throw BiliException('trak 里没有 mdia');
      }
      final mdhd = _findBox(mp4Boxes(moov, mdia.bodyStart, mdia.end), 'mdhd');
      if (mdhd == null) {
        throw BiliException('mdia 里没有 mdhd');
      }
      final timescale = readUint32(moov, mdhd.bodyStart + (moov[mdhd.bodyStart] == 1 ? 20 : 12));
      if (timescale <= 0) {
        throw BiliException('mdhd 的时间刻度异常');
      }
      timescales[trackId] = timescale;
    }
    if (trackIds.isEmpty) {
      throw BiliException('moov 里没有 trak');
    }
    var movieDurationSeconds = 0.0;
    final mvex = _findBox(children, 'mvex');
    if (mvex != null) {
      final mehd = _findBox(mp4Boxes(moov, mvex.bodyStart, mvex.end), 'mehd');
      if (mehd != null) {
        final duration = moov[mehd.bodyStart] == 1
            ? readUint64(moov, mehd.bodyStart + 4)
            : readUint32(moov, mehd.bodyStart + 4);
        movieDurationSeconds = duration / movieTimescale;
      }
    }
    return _MoovFacts(
      movieTimescale: movieTimescale,
      trackIds: trackIds,
      timescales: timescales,
      movieDurationSeconds: movieDurationSeconds,
    );
  }

  static Future<List<_Fragment>> _scanFragments(
    RandomAccessFile handle,
    List<Mp4Box> boxes,
    Map<int, int> timescales,
  ) async {
    final fragments = <_Fragment>[];
    Mp4Box? pending;
    var fallbackSeconds = 0.0;
    for (final box in boxes) {
      if (box.type == 'moof') {
        pending = box;
        continue;
      }
      if (box.type != 'mdat') continue;
      final moofBox = pending;
      if (moofBox == null) continue;
      pending = null;
      if (box.start != moofBox.end) {
        throw BiliException('分片结构不符合预期：moof 与 mdat 之间有其他盒子');
      }
      final moof = await _readAt(handle, moofBox.start, moofBox.size);
      final trafList = mp4Boxes(moof, moofBox.headerSize, moof.length)
          .where((item) => item.type == 'traf')
          .toList();
      if (trafList.isEmpty) {
        throw BiliException('moof 里没有 traf');
      }
      var timeSeconds = -1.0;
      var durationSeconds = 0.0;
      for (final traf in trafList) {
        final trafChildren = mp4Boxes(moof, traf.bodyStart, traf.end);
        final tfhd = _findBox(trafChildren, 'tfhd');
        if (tfhd == null) {
          throw BiliException('traf 里没有 tfhd');
        }
        final trackId = readUint32(moof, tfhd.bodyStart + 4);
        final timescale = timescales[trackId] ?? 0;
        final tfdt = _findBox(trafChildren, 'tfdt');
        if (tfdt != null && timescale > 0 && timeSeconds < 0) {
          final decodeTime = moof[tfdt.bodyStart] == 1
              ? readUint64(moof, tfdt.bodyStart + 4)
              : readUint32(moof, tfdt.bodyStart + 4);
          timeSeconds = decodeTime / timescale;
        }
        durationSeconds = _fragmentDurationSeconds(moof, tfhd, trafChildren, timescale);
      }
      if (timeSeconds < 0) {
        // 没有 tfdt 时按前一片段的末尾顺推，保证顺序不乱。
        timeSeconds = fallbackSeconds;
      }
      fallbackSeconds = timeSeconds + durationSeconds;
      fragments.add(_Fragment(
        moofStart: moofBox.start,
        moof: moof,
        mdatStart: box.start,
        mdatSize: box.size,
        timeSeconds: timeSeconds,
      ));
    }
    if (pending != null) {
      throw BiliException('最后一个 moof 没有对应的 mdat');
    }
    return fragments;
  }

  /// 只在缺少 tfdt 时用到：从 trun 的采样时长或 tfhd 的默认时长推片段长度。
  static double _fragmentDurationSeconds(
    Uint8List moof,
    Mp4Box tfhd,
    List<Mp4Box> trafChildren,
    int timescale,
  ) {
    if (timescale <= 0) return 0;
    final tfhdFlags = readUint32(moof, tfhd.bodyStart) & 0xffffff;
    var cursor = tfhd.bodyStart + 8;
    if (tfhdFlags & 0x000001 != 0) cursor += 8;
    if (tfhdFlags & 0x000002 != 0) cursor += 4;
    var defaultDuration = 0;
    if (tfhdFlags & 0x000008 != 0) {
      defaultDuration = readUint32(moof, cursor);
    }
    var samples = 0;
    var summed = 0;
    for (final trun in trafChildren.where((item) => item.type == 'trun')) {
      final flags = readUint32(moof, trun.bodyStart) & 0xffffff;
      final count = readUint32(moof, trun.bodyStart + 4);
      samples += count;
      if (flags & 0x000100 == 0 || count <= 0) continue;
      var offset = trun.bodyStart + 8;
      if (flags & 0x000001 != 0) offset += 4;
      if (flags & 0x000004 != 0) offset += 4;
      var entrySize = 4;
      if (flags & 0x000200 != 0) entrySize += 4;
      if (flags & 0x000400 != 0) entrySize += 4;
      if (flags & 0x000800 != 0) entrySize += 4;
      for (var index = 0; index < count; index++) {
        summed += readUint32(moof, offset);
        offset += entrySize;
      }
    }
    final duration = summed > 0 ? summed : samples * defaultDuration;
    return duration / timescale;
  }

  static Uint8List _retagMoov(Uint8List moov, int moovHeaderSize, Map<int, int> mapping) {
    final copy = Uint8List.fromList(moov);
    for (final box in mp4Boxes(copy, moovHeaderSize, copy.length)) {
      if (box.type == 'trak') {
        for (final child in mp4Boxes(copy, box.bodyStart, box.end)) {
          if (child.type != 'tkhd') continue;
          final offset = child.bodyStart + (copy[child.bodyStart] == 1 ? 20 : 12);
          final replacement = mapping[readUint32(copy, offset)];
          if (replacement != null) writeUint32(copy, offset, replacement);
        }
      } else if (box.type == 'mvex') {
        for (final child in mp4Boxes(copy, box.bodyStart, box.end)) {
          if (child.type != 'trex') continue;
          final offset = child.bodyStart + 4;
          final replacement = mapping[readUint32(copy, offset)];
          if (replacement != null) writeUint32(copy, offset, replacement);
        }
      }
    }
    return copy;
  }

  static Uint8List _buildMoov({
    required _SourceInfo video,
    required Uint8List audioMoov,
    required int audioMoovHeaderSize,
    required Map<int, int> mapping,
    required double maxDurationSeconds,
  }) {
    final videoChildren = mp4Boxes(video.moov, video.moovHeaderSize, video.moov.length);
    final mvhd = _findBox(videoChildren, 'mvhd');
    if (mvhd == null) {
      throw BiliException('视频 moov 缺少 mvhd');
    }
    final mvhdCopy = Uint8List.fromList(video.moov.sublist(mvhd.start, mvhd.end));
    var maxTrackId = 0;
    for (final trackId in <int>[...video.trackIds, ...mapping.values]) {
      if (trackId > maxTrackId) maxTrackId = trackId;
    }
    writeUint32(mvhdCopy, mvhdCopy.length - 4, maxTrackId + 1);

    final parts = <Uint8List>[mvhdCopy];
    for (final trak in videoChildren.where((box) => box.type == 'trak')) {
      parts.add(Uint8List.fromList(video.moov.sublist(trak.start, trak.end)));
    }
    final audioChildren = mp4Boxes(audioMoov, audioMoovHeaderSize, audioMoov.length);
    for (final trak in audioChildren.where((box) => box.type == 'trak')) {
      parts.add(Uint8List.fromList(audioMoov.sublist(trak.start, trak.end)));
    }

    final mvexParts = <Uint8List>[];
    final videoMvex = _findBox(videoChildren, 'mvex');
    if (videoMvex != null) {
      for (final child in mp4Boxes(video.moov, videoMvex.bodyStart, videoMvex.end)) {
        if (child.type == 'mehd') {
          mvexParts.add(_patchedMehd(video.moov, child, maxDurationSeconds, video.movieTimescale));
        } else if (child.type == 'trex') {
          mvexParts.add(Uint8List.fromList(video.moov.sublist(child.start, child.end)));
        }
      }
    }
    final audioMvex = _findBox(audioChildren, 'mvex');
    if (audioMvex != null) {
      for (final child in mp4Boxes(audioMoov, audioMvex.bodyStart, audioMvex.end)) {
        if (child.type == 'trex') {
          mvexParts.add(Uint8List.fromList(audioMoov.sublist(child.start, child.end)));
        }
      }
    }
    if (mvexParts.isEmpty) {
      throw BiliException('moov 缺少 mvex，无法按分片合并');
    }
    parts.add(buildMp4Box('mvex', mvexParts));
    return buildMp4Box('moov', parts);
  }

  static Uint8List _patchedMehd(
    Uint8List moov,
    Mp4Box mehd,
    double maxDurationSeconds,
    int movieTimescale,
  ) {
    final copy = Uint8List.fromList(moov.sublist(mehd.start, mehd.end));
    final duration = (maxDurationSeconds * movieTimescale).round();
    if (copy[mehd.headerSize] == 1) {
      writeUint64(copy, mehd.headerSize + 4, duration);
    } else {
      writeUint32(copy, mehd.headerSize + 4, duration);
    }
    return copy;
  }

  static void _patchMoof({
    required Uint8List moof,
    required int sourceMoofStart,
    required int targetMoofStart,
    required Map<int, int> mapping,
  }) {
    final headerSize = readUint32(moof, 0) == 1 ? 16 : 8;
    for (final traf in mp4Boxes(moof, headerSize, moof.length).where((box) => box.type == 'traf')) {
      for (final child in mp4Boxes(moof, traf.bodyStart, traf.end)) {
        if (child.type != 'tfhd') continue;
        final flags = readUint32(moof, child.bodyStart) & 0xffffff;
        final trackOffset = child.bodyStart + 4;
        final replacement = mapping[readUint32(moof, trackOffset)];
        if (replacement != null) {
          writeUint32(moof, trackOffset, replacement);
        }
        if (flags & 0x000001 != 0) {
          final baseOffset = child.bodyStart + 8;
          final delta = readUint64(moof, baseOffset) - sourceMoofStart;
          final target = targetMoofStart + delta;
          if (target < 0) {
            throw BiliException('分片的基础偏移异常，无法改写');
          }
          writeUint64(moof, baseOffset, target);
        }
      }
    }
  }

  static Future<void> _verify(
    String path, {
    required int expectedBytes,
    required int expectedFragments,
    required List<int> expectedTrackIds,
  }) async {
    final handle = await File(path).open();
    try {
      final length = await handle.length();
      if (length != expectedBytes) {
        throw BiliException('合并结果长度不符：$length != $expectedBytes');
      }
      final boxes = await _scanTopLevel(handle, length);
      final fragments = <_Fragment>[];
      var cursor = 0;
      while (cursor < boxes.length) {
        final box = boxes[cursor];
        if (box.type == 'moof') {
          if (cursor + 1 >= boxes.length || boxes[cursor + 1].type != 'mdat') {
            throw BiliException('合并结果里有 moof 后面不是 mdat');
          }
          fragments.add(_Fragment(
            moofStart: box.start,
            moof: await _readAt(handle, box.start, box.size),
            mdatStart: boxes[cursor + 1].start,
            mdatSize: boxes[cursor + 1].size,
            timeSeconds: 0,
          ));
          cursor += 2;
          continue;
        }
        if (box.type == 'mdat') {
          throw BiliException('合并结果里有游离的 mdat');
        }
        cursor++;
      }
      if (fragments.length != expectedFragments) {
        throw BiliException('合并结果的片段数不符：${fragments.length} != $expectedFragments');
      }
      final seen = <int>{};
      for (final fragment in fragments) {
        final headerSize = readUint32(fragment.moof, 0) == 1 ? 16 : 8;
        for (final traf in mp4Boxes(fragment.moof, headerSize, fragment.moof.length)
            .where((box) => box.type == 'traf')) {
          final tfhd = _findBox(mp4Boxes(fragment.moof, traf.bodyStart, traf.end), 'tfhd');
          if (tfhd == null) {
            throw BiliException('合并结果的片段缺少 tfhd');
          }
          seen.add(readUint32(fragment.moof, tfhd.bodyStart + 4));
        }
      }
      for (final trackId in expectedTrackIds) {
        if (!seen.contains(trackId)) {
          throw BiliException('合并结果里没有轨道 $trackId 的片段');
        }
      }
    } finally {
      await handle.close();
    }
  }

  static Mp4Box? _findBox(List<Mp4Box> boxes, String type) {
    for (final box in boxes) {
      if (box.type == type) return box;
    }
    return null;
  }
}

class _MoovFacts {
  const _MoovFacts({
    required this.movieTimescale,
    required this.trackIds,
    required this.timescales,
    required this.movieDurationSeconds,
  });

  final int movieTimescale;
  final List<int> trackIds;
  final Map<int, int> timescales;
  final double movieDurationSeconds;
}

class _Fragment {
  const _Fragment({
    required this.moofStart,
    required this.moof,
    required this.mdatStart,
    required this.mdatSize,
    required this.timeSeconds,
  });

  final int moofStart;
  final Uint8List moof;
  final int mdatStart;
  final int mdatSize;
  final double timeSeconds;
}

class _MergeEntry {
  const _MergeEntry({required this.source, required this.fragment, required this.order});

  final _SourceInfo source;
  final _Fragment fragment;

  /// 同一时刻先写视频，再写音频。
  final int order;
}

class _SourceInfo {
  const _SourceInfo({
    required this.handle,
    required this.ftyp,
    required this.moov,
    required this.moovHeaderSize,
    required this.trackIds,
    required this.movieTimescale,
    required this.movieDurationSeconds,
    required this.fragments,
  });

  final RandomAccessFile handle;
  final Uint8List ftyp;
  final Uint8List moov;
  final int moovHeaderSize;
  final List<int> trackIds;
  final int movieTimescale;
  final double movieDurationSeconds;
  final List<_Fragment> fragments;

  Future<void> close() => handle.close();
}
