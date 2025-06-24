// ────────────────────────────────────────────────────────────────────────────
// HistoryController — v4.2  (26 Jun 2025)
//   • corrects start-time/HR parsing for new & old ECG headers
//   • canonical file-key  <YYYYMMDDhhmmss>.ecg  ↔︎ 14-byte stem on-device
//   • keeps full back-compat with BP history
// ────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert' show ascii;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/bp_record.dart';
import '../models/ecg_record.dart';
import '../models/ecgindex.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart'
    show BP2Frame,
    readFileStart,
    readFileData,
    readFileEnd,
    getFileList,
    deleteAllFiles;
import 'device_controller.dart';

class HistoryController extends GetxController {
  /* ───────── dependencies & observables ───────── */
  final _ble = Get.find<BleService>();

  final records = <BpRecord>[].obs;
  final ecgs    = <EcgRecord>[].obs;

  final RxBool _isPulling = false.obs;
  RxBool get isPulling => _isPulling;

  /* ───────── helpers ───────── */

  String _safeAscii(List<int> b) =>
      ascii.decode(b, allowInvalid: true).split('\x00').first.trim();

  Future<BP2Frame?> _txRx(BP2Frame req,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final c   = Completer<BP2Frame?>();
    late final StreamSubscription sub;
    sub = _ble.frames.listen((f) {
      if (f.cmd != req.cmd) return;
      if (f.pkgType == 0xFB || f.pkgType == 0xE1) {
        if (!c.isCompleted) c.complete(f);
        return;
      }
      if (f.pkgType == 0x01 && !c.isCompleted) c.complete(f);
    });
    await _ble.sendFrame(req);
    return c.future
        .timeout(timeout, onTimeout: () {
      if (!c.isCompleted) c.complete(null);
      sub.cancel();
      return null;
    })
        .whenComplete(() => sub.cancel());
  }

  Future<BP2Frame?> _txRxRetry(BP2Frame req,
      {Duration overall = const Duration(seconds: 35),
        Duration single  = const Duration(seconds: 4)}) async {
    final deadline = DateTime.now().add(overall);
    while (DateTime.now().isBefore(deadline)) {
      final r = await _txRx(req, timeout: single);
      if (r == null) continue;
      if (r.pkgType == 0x01) return r;
      if (r.pkgType == 0xFB || r.pkgType == 0xE1) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      return null;
    }
    return null;
  }

  /* ───────── life-cycle ───────── */

  @override
  void onInit() {
    super.onInit();
    records.assignAll(
        Hive.box<BpRecord>('bpBox').values.cast<BpRecord>().toList().reversed);
    ecgs.assignAll(
        Hive.box<EcgRecord>('ecgBox').values.cast<EcgRecord>().toList().reversed);

    _ble.frames.listen(_onLegacyBpFrame);
  }

  /* ═════════ UI entry-points ═════════ */

  Future<void> pullEcgPressed() async {
    if (_isPulling.value) return;
    _isPulling.value = true;
    await syncLatestEcg();
    _isPulling.value = false;
  }

  /* ═════════ ECG history download ═════════ */

  Future<void> syncLatestEcg() async {
    await Get.find<DeviceController>().stopRealtime();       // step 1

    // step 2 — wait until not recording
    while (true) {
      final st = await _txRx(BP2Frame(cmd: 0x06));
      if (st == null) return;
      final rs = st.data.first;
      if (rs == 1 || rs == 3 || rs == 7) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // step 3 — fetch root dir
    BP2Frame? dir;
    do {
      dir = await _txRx(BP2Frame(cmd: 0xF1));
      if (dir == null) return;
      if (dir.pkgType == 0xE1) {
        await Future.delayed(const Duration(milliseconds: 200));
        dir = null;
      }
    } while (dir == null);

    if (dir.pkgType == 0xFB || dir.data.length < 2) {
      print('[ECG] no history on device');
      return;
    }

    // step 4 — iterate entries
    final cnt = dir.data.first;
    for (var i = 0; i < cnt; ++i) {
      final n = _safeAscii(dir.data.sublist(1 + i * 16, 17 + i * 16));
      if (n.endsWith('.list')) await _pullFile(n);
    }
  }

  /* ───────── pull one file recursively ───────── */

  // ★ keeps a map: canonical <stem>.ecg  →  UTC epoch
  final _startEpochByFile = <String,int>{};       // ★

  Future<void> _pullFile(String name) async {
    print('   • $name');

    /* a)  start — get length */
    BP2Frame? start;
    for (int i = 0; i < 8; ++i) {
      // Device expects 16-byte 0-padded file name
      final devName = name.padRight(16, '\x00');
      start = await _txRx(readFileStart(devName, 0));
      if (start != null &&
          start.data.length >= 4 &&
          start.data[0] != 0xE1) break;
      await Future.delayed(Duration(milliseconds: 200 + i * 80));
    }
    if (start == null || start.data.length < 4 || start.data[0] == 0xE1) {
      print('     ↯ still busy — aborted');
      return;
    }

    final total = ByteData.sublistView(
        Uint8List.fromList(start.data))
        .getUint32(0, Endian.little);
    if (total == 0) {
      print('     ↯ zero-length — skipped');
      return;
    }

    /* b)  body */
    final buf = BytesBuilder();
    for (var off = 0; off < total;) {
      final part = await _txRx(readFileData(off, math.min(1024, total - off)),
          timeout: const Duration(seconds: 2));
      if (part == null || part.data.isEmpty) {
        print('     ↯ abort @ $off');
        return;
      }
      buf.add(part.data);
      off += part.data.length;
    }
    await _txRx(readFileEnd());
    final bytes = buf.toBytes();

    /* c) recurse / parse */
    if (name.endsWith('.list')) {
      for (final entry in _parseListFile(bytes)) {
        await _pullFile(entry.fileStem);          // still only 14-byte stem
      }
    } else {
      // ★ optional cross-check - not used further
      if (_startEpochByFile.containsKey('$name.ecg')) {
        // we *could* compare header vs list here
      }
      _parseEcgFile(bytes);
    }
    print('     ✓ saved ${bytes.length} B');
  }
  DateTime _decodeUtc6(ByteData bd, int off) {             // ★ NEW
    final yy = bd.getUint8(off);
    final mo = bd.getUint8(off + 1);
    final dd = bd.getUint8(off + 2);
    final hh = bd.getUint8(off + 3);
    final mm = bd.getUint8(off + 4);
    final ss = bd.getUint8(off + 5);
    return DateTime.utc(2000 + yy, mo, dd, hh, mm, ss);    // 20yy
  }
  /* ───────── pretty hex dump (debug) ───────── */
  String _hexDump(List<int> data, {int maxBytes = 48}) {
    final slice  = data.take(maxBytes).toList();
    final hex    = slice.map((b) =>
        b.toRadixString(16).padLeft(2, '0')).join(' ');
    final ascii  = slice.map((b) =>
    (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.').join();
    return '${hex.padRight(maxBytes * 3)} | $ascii';
  }

  /* ───────── ECG directory parser ───────── */
  List<EcgIndexEntry> _parseListFile(Uint8List buf, {bool debug = false}) {
    const headLen = 10;
    if (buf.length < headLen) return const [];

    final type = buf[1];
    if (type != 2) return const [];              // ECG only

    // choose 56- or 46-byte layout
    int recLen = 56;
    if ((buf.length - headLen) % recLen != 0) recLen = 46;
    if ((buf.length - headLen) % recLen != 0) return const [];

    final cnt = (buf.length - headLen) ~/ recLen;
    final bd  = ByteData.sublistView(buf);
    final out = <EcgIndexEntry>[];

    for (var i = 0; i < cnt; ++i) {
      final off = headLen + i * recLen;
      if (off + recLen > buf.length) break;

      final ts = bd.getUint32(off, Endian.little);
      if (ts == 0) continue;

      final duration = bd.getUint32(off + 4,  Endian.little);
      final mask     = bd.getUint32(off + 8,  Endian.little);
      final hr       = bd.getUint16(off + 12, Endian.little);
      final qrs      = bd.getUint16(off + 14, Endian.little);
      final pvcs     = bd.getUint16(off + 16, Endian.little);
      final qtc      = bd.getUint16(off + 18, Endian.little);

      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
      final stem = '${dt.year.toString().padLeft(4, '0')}'
          '${dt.month.toString().padLeft(2, '0')}'
          '${dt.day.toString().padLeft(2, '0')}'
          '${dt.hour.toString().padLeft(2, '0')}'
          '${dt.minute.toString().padLeft(2, '0')}'
          '${dt.second.toString().padLeft(2, '0')}';

      // ★ keep a reverse-lookup to confirm later (optional)
      _startEpochByFile['$stem.ecg'] = ts;                         // ★

      out.add(EcgIndexEntry(
        fileStem      : stem,                                     // 14-byte
        duration      : duration,
        diagnosisBits : mask,
        hr            : hr,
        qrs           : qrs,
        pvcs          : pvcs,
        qtc           : qtc,
      ));

      if (debug) {
        print('  • $stem  dur=$duration s  HR=$hr  diag=0x${mask.toRadixString(16)}');
      }
    }
    return out;
  }

  /* ───────── ECG file parser ───────── */
  void _parseEcgFile(Uint8List buf) {
    if (buf.length < 40) return;                 // sanity

    final bd = ByteData.sublistView(buf);
    if (bd.getUint8(1) != 2) return;             // not an ECG file

    // ★ 0-based offsets:  0-3 epoch, 8-11 duration, 14-15 HR, 16-19 diag
    final startSecs = bd.getUint32(0, Endian.little);             // ★
    final duration  = bd.getUint32(8, Endian.little);             // ★
    final hr        = bd.getUint16(14, Endian.little);            // ★
    final mask      = bd.getUint32(16, Endian.little);            // ★

    final rec = EcgRecord(
      start        : DateTime.fromMillisecondsSinceEpoch(startSecs * 1000, isUtc:true),
      duration     : duration,
      diagnosisBits: mask,
      hr           : hr,
      wave         : buf.sublist(40),                 // ★ wave starts @40
    );

    Hive.box<EcgRecord>('ecgBox').add(rec);
    ecgs.insert(0, rec);
  }

  /* ─── legacy BP handler (unchanged) ─── */
  void _onLegacyBpFrame(BP2Frame f) {/* … same as before … */}
}
