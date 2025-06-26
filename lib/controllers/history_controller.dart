// ────────────────────────────────────────────────────────────────────────────
// HistoryController — v4.3  (27 Jun 2025)
//   • auto‑detects both ECG header layouts (2023 & 2025 firmware)
//   • fixes HR/QRS offsets for new layout (+18 / +20 …)
//   • keeps full back‑compat with BP history & existing UI hooks
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


// ─── ECG-file constants ───
  static const int _hdrBytes    = 10;   // 2-byte “01 02” + 8-byte reserved
  static const int _resultBytes = 38;   // sizeof(AnalysisResult_t)
  static const int _waveOffset  = _hdrBytes + _resultBytes;   // 48
  static const int _sps         = 125;  // Hz

// ── OFFSETS *inside* AnalysisResult_t (little-endian) ──
  static const int _tsOff   =  0;   // u32 start timestamp      (same)
  static const int _maskOff =  4;   // u32 analysisMask*        (same – often 0xFFFF on 2025 fw)
  static const int _durOff  = 10;   // u32 recording_time       (was  8)
  static const int _hrOff   = 18;   // u16 HR   (NEW → +4)
  static const int _qrsOff  = 20;   // u16 QRS  (NEW → +4)
  static const int _pvcsOff = 22;   // u16 PVCs (NEW → +4)
  static const int _qtcOff  = 24;   // u16 QTc  (NEW → +4)



  bool _looksLikeHr(int v) => v > 20 && v < 250;      // sane HR range

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

  /* ───────── life‑cycle ───────── */

  @override
  void onInit() {
    super.onInit();
    records.assignAll(
        Hive.box<BpRecord>('bpBox').values.cast<BpRecord>().toList().reversed);
    ecgs.assignAll(
        Hive.box<EcgRecord>('ecgBox').values.cast<EcgRecord>().toList().reversed);

    _ble.frames.listen(_onLegacyBpFrame);
  }

  /* ═════════ UI entry‑points ═════════ */

  Future<void> pullEcgPressed() async {
    if (_isPulling.value) return;
    _isPulling.value = true;
    await syncLatestEcg();
    _isPulling.value = false;
  }

  /* ═════════ ECG history download ═════════ */

  Future<void> syncLatestEcg() async {
    await Get.find<DeviceController>().stopRealtime();       // step 1

    // step 2 — wait until not recording
    while (true) {
      final st = await _txRx(BP2Frame(cmd: 0x06));
      if (st == null) return;
      final rs = st.data.first;
      if (rs == 1 || rs == 3 || rs == 7) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // step 3 — fetch root dir
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

    // step 4 — iterate entries
    final cnt = dir.data.first;
    for (var i = 0; i < cnt; ++i) {
      final n = _safeAscii(dir.data.sublist(1 + i * 16, 17 + i * 16));
      if (n.endsWith('.list')) await _pullFile(n);
    }
  }

  /* ───────── pull one file recursively ───────── */

  // ★ keeps a map: canonical <stem>.ecg  →  UTC epoch
  final _startEpochByFile = <String,int>{};

  Future<void> _pullFile(String name) async {
    print('   • $name');

    /* a)  start — get length */
    BP2Frame? start;
    for (int i = 0; i < 8; ++i) {
      // Device expects 16‑byte 0‑padded file name
      final devName = name.padRight(16, '\x00');
      start = await _txRx(readFileStart(devName, 0));
      if (start != null &&
          start.data.length >= 4 &&
          start.data[0] != 0xE1) break;
      await Future.delayed(Duration(milliseconds: 200 + i * 80));
    }
    if (start == null || start.data.length < 4 || start.data[0] == 0xE1) {
      print('     ↯ still busy — aborted');
      return;
    }

    final total = ByteData.sublistView(
        Uint8List.fromList(start.data))
        .getUint32(0, Endian.little);
    if (total == 0) {
      print('     ↯ zero‑length — skipped');
      return;
    }

    /* b)  body */
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

    /* c)  recurse / parse */
    if (name.endsWith('.list')) {
      for (final entry in _parseListFile(bytes)) {
        await _pullFile(entry.fileStem);          // still only 14‑byte stem
      }
    } else {
      // ★ optional cross‑check - not used further
      if (_startEpochByFile.containsKey('$name.ecg')) {
        // we *could* compare header vs list here
      }
      _parseEcgFile(bytes);
    }
    print('     ✓ saved ${bytes.length} B');
  }

  DateTime _decodeUtc6(ByteData bd, int off) {             // ★ helper
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
    const headLen = 10;                     // fixed
    if (buf.length <= headLen) return const [];

    // try V2 (48 B) first, fall back to V1 (46 B)
    var recLen = 48;
    if ((buf.length - headLen) % recLen != 0) recLen = 46;
    if ((buf.length - headLen) % recLen != 0) return const [];

    final bd  = ByteData.sublistView(buf);
    final cnt = (buf.length - headLen) ~/ recLen;
    final out = <EcgIndexEntry>[];

    for (var i = 0; i < cnt; ++i) {
      final off = headLen + i * recLen;

      final ts = bd.getUint32(off + 0, Endian.little);
      if (ts == 0) continue;                           // empty slot

      final duration = bd.getUint32(off + (recLen == 48 ? 10 : 4), Endian.little);
      final mask     = bd.getUint32(off + (recLen == 48 ? 16 : 8), Endian.little);
      var   hr       = bd.getUint16(off + (recLen == 48 ? 20 : 12), Endian.little);
      final qrs      = bd.getUint16(off + (recLen == 48 ? 22 : 14), Endian.little);
      final pvcs     = bd.getUint16(off + (recLen == 48 ? 24 : 16), Endian.little);
      final qtc      = bd.getUint16(off + (recLen == 48 ? 26 : 18), Endian.little);
      if (hr == 0xFFFF) hr = 0;

      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
      final stem =
          '${dt.year.toString().padLeft(4, "0")}'
          '${dt.month.toString().padLeft(2, "0")}'
          '${dt.day.toString().padLeft(2, "0")}'
          '${dt.hour.toString().padLeft(2, "0")}'
          '${dt.minute.toString().padLeft(2, "0")}'
          '${dt.second.toString().padLeft(2, "0")}';

      _startEpochByFile['$stem.ecg'] = ts;             // cross‑check

      out.add(EcgIndexEntry(
        fileStem      : stem,
        duration      : duration,
        diagnosisBits : mask,
        hr            : hr,
        qrs           : qrs,
        pvcs          : pvcs,
        qtc           : qtc,
      ));

      if (debug) {
        print('• $stem  dur=$duration  HR=$hr  diag=0x${mask.toRadixString(16)}');
      }
    }
    return out;
  }



/* ───────── ECG file parser ───────── */
/* ───────── ECG file parser (v4.4) ───────── */
  void _parseEcgFile(Uint8List buf) {
    if (buf.length < 60) return;                        // short-file guard

    final bd = ByteData.sublistView(buf);
    if (bd.getUint8(1) != 2) return;                    // not an ECG payload

    // ─── constants for the two known header sizes ───
    const int _resultOld = 38;          // 2023 fw   → wave @ 10 + 38 = 48
    const int _resultNew = 44;          // 2025 fw   → wave @ 10 + 42 = 52

    /* --- 1.  try "new" layout first --------------------------------------- */
    int duration = bd.getUint32(_hdrBytes + _durOff, Endian.little);
    int hr       = bd.getUint16(_hdrBytes + _hrOff,  Endian.little);
    bool useNew  = _looksLikeHr(hr) && duration != 0;

    /* --- 2.  if HR/duration look bogus, fall back to the old offsets ------ */
    if (!useNew) {
      duration = bd.getUint32(_hdrBytes +  8, Endian.little);   // old dur
      hr       = bd.getUint16(_hdrBytes + 12, Endian.little);   // old HR
    }

    // final offsets according to the chosen layout
    final qrs  = bd.getUint16(_hdrBytes + (useNew ? _qrsOff  : 14), Endian.little);
    final pvcs = bd.getUint16(_hdrBytes + (useNew ? _pvcsOff : 16), Endian.little);
    final qtc  = bd.getUint16(_hdrBytes + (useNew ? _qtcOff  : 18), Endian.little);
    final mask = bd.getUint32(_hdrBytes + _maskOff, Endian.little);
    final startSecs = bd.getUint32(_hdrBytes + _tsOff, Endian.little);

    // pick correct waveform offset
    final waveOff = _hdrBytes + (useNew ? _resultNew : _resultOld);
    if (buf.length <= waveOff + 2) return;              // corrupt

    final wave = buf.sublist(waveOff);
    final secsFromWave = (wave.length ~/ 2) ~/ _sps;

    // last-chance sanity: if header duration still looks fishy, trust the wave
    if (duration == 0 || (secsFromWave - duration).abs() > 1) {
      duration = secsFromWave;
    }

    final rec = EcgRecord(
      // store in **local** time so UI shows what you saw on the watch
      start : DateTime.fromMillisecondsSinceEpoch(
          startSecs * 1000, isUtc: true).toLocal(),

      duration      : duration,
      diagnosisBits : mask,
      hr            : (hr == 0xFFFF) ? 0 : hr,
      qrs           : qrs,
      pvcs          : pvcs,
      qtc           : qtc,
      wave          : wave,
    );

    Hive.box<EcgRecord>('ecgBox').add(rec);
    ecgs.insert(0, rec);
  }

  /* ─── legacy BP handler (unchanged) ─── */
  void _onLegacyBpFrame(BP2Frame f) {/* … same as before … */}
}
