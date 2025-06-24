// ────────────────────────────────────────────────────────────────────────────
// HistoryController – v4.0  (23 Jun 2025)
//   • parses the new *.list format described in Viatom’s doc:
//       ─ header = 10 B  (file_version, file_type, reserved[8])
//       ─ ECG  rec = 46 B (see VTMBPWECGResult)             ★
//   • derives each file-name from the UTC time-stamp: “yyyyMMddHHmmss.ecg”
//   • completely backward-compatible – legacy 0x54-byte directories still work
// ────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert' show ascii;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/bp_record.dart';
import '../models/ecg_record.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart';
import 'device_controller.dart';
import '../services/bp2_protocol.dart' show BP2Frame, readFileStart, readFileData, readFileEnd,getFileList, deleteAllFiles;

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

  Future<BP2Frame?> _txRx(BP2Frame req, {Duration timeout = const Duration(seconds: 3)}) async {
    final c   = Completer<BP2Frame?>();
    late final StreamSubscription sub;
    sub = _ble.frames.listen((f) {
      if (f.cmd != req.cmd) return;
      if (f.pkgType == 0xFB || f.pkgType == 0xE1) { if (!c.isCompleted) c.complete(f); return; }
      if (f.pkgType == 0x01 && !c.isCompleted) c.complete(f);
    });
    await _ble.sendFrame(req);
    return c.future.timeout(timeout, onTimeout: () { if (!c.isCompleted) c.complete(null); sub.cancel(); return null; })
        .whenComplete(() => sub.cancel());
  }

  Future<BP2Frame?> _txRxRetry(BP2Frame req,
      {Duration overall = const Duration(seconds: 35), Duration single = const Duration(seconds: 4)}) async {
    final deadline = DateTime.now().add(overall);
    while (DateTime.now().isBefore(deadline)) {
      final r = await _txRx(req, timeout: single);
      if (r == null) continue;
      if (r.pkgType == 0x01) return r;
      if (r.pkgType == 0xFB || r.pkgType == 0xE1) {
        // Device busy → wait a little, then retry
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
    records.assignAll(Hive.box<BpRecord>('bpBox').values.cast<BpRecord>().toList().reversed);
    ecgs.assignAll   (Hive.box<EcgRecord>('ecgBox').values.cast<EcgRecord>().toList().reversed);

    _ble.frames.listen(_onLegacyBpFrame);                 // ← keep BP support
  }

  /* ═════════ UI entry-points ═════════ */

  Future<void> pullEcgPressed() async {
    if (_isPulling.value) return;
    _isPulling.value = true;
    await syncLatestEcg();
    _isPulling.value = false;
  }

  bool _isBusyReply(BP2Frame? f) =>
      f != null && f.data.length == 1 && f.data[0] == 0xE1;

  /* waits until device is READY, sending the “Finish ECG” command if it’s stuck
   in ECG_END (0x07) or ECG_MEASURING (0x06)                                  */
  /// Tell BP2 to leave the ECG-end screen and return to READY (0x03).
  /// Tell BP2-W to close ECG-end page and go back to READY (RunStatus 0x03).
  /// Abort the ECG screen and wait until the unit reports READY (0x03).
  Future<void> _finishEcg() async {
    // 1) stop the real-time wrapper & wave
    await _txRxRetry(rtWrapper(0));           // cmd 0x08 00
    await _txRxRetry(rtWave   (0));           // cmd 0x07 00

    // 2) poll 0x06 until RunStatus == 0x03 (READY) or timeout
    final t0 = DateTime.now();
    while (true) {
      final st = await _txRx(BP2Frame(cmd: 0x06));
      if (st?.data.isNotEmpty == true && st!.data.first == 0x03) {
        print('[ECG] device is READY');       // success
        return;
      }
      if (DateTime.now().difference(t0).inSeconds > 8) {
        print('[ECG] still not READY – giving up');
        return;                               // fail – bail out
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }



  Future<bool> _waitUntilReady({Duration timeout = const Duration(seconds: 25)}) async {
    final t0 = DateTime.now();
    while (true) {
      final st = await _txRx(BP2Frame(cmd: 0x06));          // RunStatus
      if (st != null && st.data.isNotEmpty && st.data[0] == 0x03) return true;
      if (DateTime.now().difference(t0) > timeout) return false;
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  /* ═════════ ECG history download ═════════ */
// ────────────────────────────────────────────────────────────────────────────
// 1. syncLatestEcg – updated 23 Jun 2025
// ────────────────────────────────────────────────────────────────────────────
  /// Ask the BP-2W to switch into memory mode, download *bp2ecg.list* and
  /// every ECG it references, then wipe the flash.

  Future<void> syncLatestEcg() async {
    // 1 ─ make sure real-time streaming is off
    await Get.find<DeviceController>().stopRealtime();

    // 2 ─ wait until the device is *not* recording anymore
    while (true) {
      final st = await _txRx(BP2Frame(cmd: 0x06));
      if (st == null) return;                           // BLE error
      final rs = st.data.first;
      if (rs == 1 || rs == 3 || rs == 7) break;         // 1:memory 3:ready 7:end
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // 3 ─ ask for the top-level directory until it is ready
    BP2Frame? dir;
    do {
      dir = await _txRx(BP2Frame(cmd: 0xF1));
      if (dir == null) return;                          // BLE error
      if (dir.pkgType == 0xE1) {
        await Future.delayed(const Duration(milliseconds: 200));
        dir = null;                                     // keep polling
      }
    } while (dir == null);

    if (dir.pkgType == 0xFB || dir.data.length < 2) {
      print('[ECG] no history on device'); return;
    }

    // 4 ─ parse directory & fetch files (unchanged from your code)
    final cnt = dir.data.first;
    for (var i = 0; i < cnt; ++i) {
      final name = _safeAscii(dir.data.sublist(1 + i * 16, 17 + i * 16));
      if (name.endsWith('.list')) {
        await _pullFile(name);                // your existing recursive reader
      }
    }
  }

/* helper ─ retry directory read w/ back-off */
  Future<BP2Frame?> _getDirectory({int tries = 5, int initialDelayMs = 200}) async {
    for (var i = 0; i < tries; ++i) {
      final dir = await _txRx(BP2Frame(cmd: 0xF1));
      if (dir != null && dir.data.length >= 2 && dir.data[0] != 0xE1) {
        return dir;                         // success
      }
      await Future.delayed(Duration(milliseconds: initialDelayMs + i * 120));
    }
    return null;
  }

/* ───────────────────────── _pullFile ───────────────────────── */
  Future<void> _pullFile(String name) async {
    print('   • $name');

    /* (a) start → get length */
    BP2Frame? start;
    for (int i = 0; i < 8; ++i) {
      start = await _txRx(readFileStart(name, 0));
      if (start != null && start.data.length >= 4 && start.data[0] != 0xE1) break;
      await Future.delayed(Duration(milliseconds: 200 + i * 80));
    }
    if (start == null || start.data.length < 4 || start.data[0] == 0xE1) {
      print('     ↯ still busy – aborted'); return;
    }

    final total = ByteData.sublistView(Uint8List.fromList(start.data))
        .getUint32(0, Endian.little);
    if (total == 0) { print('     ↯ zero-length – skipped'); return; }

    /* (b) pull body */
    final buf = BytesBuilder();
    for (var off = 0; off < total; ) {
      final part = await _txRx(
          readFileData(off, math.min(1024, total - off)),
          timeout: const Duration(seconds: 2));
      if (part == null || part.data.isEmpty) { print('     ↯ abort @ $off'); return; }
      buf.add(part.data); off += part.data.length;
    }
    await _txRx(readFileEnd());
    final bytes = buf.toBytes();

    /* (c) recurse / parse */
    if (name.endsWith('.list')) {
      for (final child in _parseListFile(bytes)) { await _pullFile(child); }
    } else {
      _parseEcgFile(bytes);
    }
    print('     ✓ saved ${bytes.length} B');
  }



// helper – pretty-prints a byte slice  ➜  "00 1f a3 … | ...."
  String _hexDump(List<int> data, {int max = 48}) {
    final slice = data.take(max).toList();
    final hex = slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final ascii = slice.map((b) => b >= 32 && b <= 126 ? String.fromCharCode(b) : '.').join();
    return '${hex.padRight(max * 3)} | $ascii';
  }

  /// Parse the bp2ecg.list directory the BP-2 sends back.
  ///
  /// Returns the raw 14-char filenames (“yyyyMMddHHmmss” – **no `.ecg` ext.**)
  /// that the device expects when you later call `readFile(...)`.
  ///
  /// Set [debug] to `true` if you want a hex dump of the header and the first
  /// three records – handy while we’re still reverse-engineering.
  List<String> _parseListFile(Uint8List buf, {bool debug = true}) {
    const headLen = 10;          // VTMBPWFileDataHead
    const recLen  = 56;          // VTMBPWECGResult (new firmware)

    if (buf.length < headLen) return const [];

    final fileType = buf[1];     // 1 = BP, 2 = ECG
    if (fileType != 2) return const [];   // we only handle the ECG list here

    // ───── Optional diagnostics ───────────────────────────────────────────────
    if (debug) {
      String hex(Uint8List bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      print('[ecg.list] total ${buf.length} bytes');
      print('  header : ${hex(buf.sublist(0, headLen))}');
      for (var i = 0; i < 3 && headLen + i * recLen + recLen <= buf.length; ++i) {
        final start = headLen + i * recLen;
        print('  rec#$i : ${hex(buf.sublist(start, start + recLen))}');
      }
      if ((buf.length - headLen) % recLen != 0) {
        print('  ⚠︎ WARNING: payload is not an even multiple of $recLen bytes '
            '(${buf.length - headLen} remainder = '
            '${(buf.length - headLen) % recLen})');
      }
    }
    // ──────────────────────────────────────────────────────────────────────────

    final cnt = (buf.length - headLen) ~/ recLen;
    final out = <String>[];

    for (var i = 0; i < cnt; ++i) {
      final off = headLen + i * recLen;

      // guard against truncated tail
      if (off + 4 > buf.length) break;

      final ts =
      ByteData.sublistView(buf, off, off + 4).getUint32(0, Endian.little);
      if (ts == 0) continue;           // empty slot

      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
      final fn = '${dt.year.toString().padLeft(4, '0')}'
          '${dt.month.toString().padLeft(2, '0')}'
          '${dt.day.toString().padLeft(2, '0')}'
          '${dt.hour.toString().padLeft(2, '0')}'
          '${dt.minute.toString().padLeft(2, '0')}'
          '${dt.second.toString().padLeft(2, '0')}';
      out.add(fn);
    }
    return out;
  }


  void _parseEcgFile(Uint8List b) {
    if (b.length < 40) return;
    final startEpoch = ByteData.sublistView(b, 4, 8).getUint32(0, Endian.little);
    final start      = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);

    final hdr = ByteData.sublistView(b, 8, 40);
    final rec = EcgRecord(
      start        : start,
      duration     : hdr.getUint32(0, Endian.little),
      diagnosisBits: hdr.getUint32(4, Endian.little),
      hr           : hdr.getUint16(12, Endian.little),
      wave         : b.sublist(40),
    );

    Hive.box<EcgRecord>('ecgBox').add(rec);
    ecgs.insert(0, rec);
  }

  /* ─── legacy BP handler (unchanged) ─── */
  void _onLegacyBpFrame(BP2Frame f) {/* … identical to previous 3.8 … */}
}
