// ─────────────────────────────────────────────────────────────
// lib/controllers/history_controller.dart  –  V3.3 (15 Jun 2025)
//   • Cleans up duplicate lines & type errors
//   • Uses print() instead of debugPrint()
//   • Adds user‑aware switchToMemory call
// ─────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert' show ascii;
import 'dart:math' as math;

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/bp_record.dart';
import '../models/ecg_record.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart';

class HistoryController extends GetxController {
  final _ble = Get.find<BleService>();

  final RxList<BpRecord>  records = <BpRecord>[].obs;  // BP list
  final RxList<EcgRecord> ecgs    = <EcgRecord>[].obs; // ECG list

  @override
  void onInit() {
    super.onInit();
    _ble.frames.listen(_onFrame);   // legacy BP only
  }

  // ───────────── BP LEGACY SYNC ─────────────
  Future<void> syncFromDevice() async => _ble.sendFrame(getFileList());

  void _onFrame(BP2Frame f) async {
    if (f.cmd == 0xF1 && f.pkgType == 0x01) {
      int pos = 1;                              // first byte = file_num
      while (pos + 16 <= f.data.length) {
        final name = ascii.decode(f.data.sublist(pos, pos + 16))
            .split('\x00').first;
        pos += 16;
        final id = records.length;
        await _ble.sendFrame(readFile(id, 0));  // legacy read path
      }
    } else if (f.cmd == 0xF2 && f.pkgType == 0x01) {
      _parseBpFile(Uint8List.fromList(f.data));
    }
  }

  void _parseBpFile(Uint8List bytes) {
    if (bytes.length < 21) return;
    if (bytes[9] != 0) return;                  // single‑measure only

    final rec = BpRecord(
      systolic  : bytes[14] | (bytes[15] << 8),
      diastolic : bytes[16] | (bytes[17] << 8),
      mean      : bytes[18] | (bytes[19] << 8),
      pulse     : bytes[20],
      time      : _tsFromName(ascii.decode(bytes.sublist(0, 14))
          .replaceAll('\u0000', '')),
    );
    Hive.box<BpRecord>('bpBox').add(rec);
    records.insert(0, rec);
  }

  DateTime _tsFromName(String s) => DateTime.utc(
    int.parse(s.substring(0, 4)),
    int.parse(s.substring(4, 6)),
    int.parse(s.substring(6, 8)),
    int.parse(s.substring(8, 10)),
    int.parse(s.substring(10, 12)),
    int.parse(s.substring(12, 14)),
  );

  // ───────────── ECG SYNC ─────────────
  /// Download the newest ECG record for a given user (default user 0).
  /// Sequence:
  ///   1. 0x09 [2,user]  → Review/Memory mode
  ///   2. wait until the BP-2 stops replying with wrapper packets (0x08)
  ///      and sleep an extra 800 ms so the flash commit finishes
  ///   3. 0xF1          → File list
  ///   4. 0xF2 / 0xF3   → Read file in chunks, finish with 0xF4
  ///   5. parse + save  → EcgRecord
// ───────────── ECG SYNC ─────────────
  Future<void> syncLatestEcg({int userId = 0}) async {
    /* 0) switch the BP-2 to “memory / review” for the given user */
    await _ble.sendFrame(switchToMemory(userId: userId));

    /* 0-bis) wait until we have seen no 0×08 packets for ≥400 ms */
    var last08 = DateTime.now();
    late final sub;
    sub = _ble.frames.listen((f) {
      if (f.cmd == 0x08) last08 = DateTime.now();
    });

    while (DateTime.now().difference(last08).inMilliseconds < 400) {
      await Future.delayed(const Duration(milliseconds: 60));
    }
    sub.cancel();

    /* 1) ask for the file list – retry while the firmware is still busy */
    BP2Frame? listReply;
    for (var tries = 0; tries < 8; tries++) {
      listReply = await _awaitReply(getFileList());
      if (listReply != null &&
          listReply.pkgType == 0x01 && listReply.data.isNotEmpty) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (listReply == null || listReply.data.isEmpty) {
      print('[ECG] file-list failed');
      return;
    }

    /* 2) newest file is always the last entry */
    final count = listReply.data.first;
    if (count == 0) { print('[ECG] no files for user$userId'); return; }

    final namePos  = 1 + (count - 1) * 16;
    final fileName = ascii
        .decode(listReply.data.sublist(namePos, namePos + 16))
        .split('\x00')
        .first
        .trim();
    print('[ECG] downloading “$fileName”…');

    /* 3) total size */
    final start = await _awaitReply(readFileStart(fileName, 0));
    if (start == null || start.data.length < 4) {
      print('[ECG] start-reply failed'); return;
    }
    final total = ByteData.sublistView(
        Uint8List.fromList(start.data), 0, 4).getUint32(0, Endian.little);

    /* 4) chunked download */
    final buff   = BytesBuilder();
    var   offset = 0;
    const chunk  = 1024;
    while (offset < total) {
      final req = math.min(chunk, total - offset);
      final part = await _awaitReply(readFileData(offset, req));
      if (part == null || part.data.isEmpty) {
        print('[ECG] aborted at $offset / $total'); return;
      }
      buff.add(part.data);
      offset += part.data.length;
    }
    await _ble.sendFrame(readFileEnd());

    /* 5) decode & persist */
    _parseEcgFile(buff.toBytes());
    print('[ECG] saved ${buff.length} bytes');
  }


  Future<BP2Frame?> _awaitReply(BP2Frame req) async {
    final c = Completer<BP2Frame?>();
    late final StreamSubscription sub;

    sub = _ble.frames.listen((f) {
      if (f.cmd == req.cmd) {           // ← drop pkgType requirement
        sub.cancel();
        c.complete(f);
      }
    });

    await _ble.sendFrame(req);

    return c.future
        .timeout(const Duration(seconds: 3), onTimeout: () {
      sub.cancel();
      return null;
    });
  }


  void _parseEcgFile(Uint8List bytes) {
    if (bytes.length < 40) return;

    final startUnix = ByteData.sublistView(bytes, 4, 8)
        .getUint32(0, Endian.little);
    final start     = DateTime.fromMillisecondsSinceEpoch(
        startUnix * 1000, isUtc: true);

    final analysis  = ByteData.sublistView(bytes, 8, 40);
    final rec = EcgRecord(
      start        : start,
      duration     : analysis.getUint32(0, Endian.little),
      diagnosisBits: analysis.getUint32(4, Endian.little),
      hr           : analysis.getUint16(12, Endian.little),
      wave         : bytes.sublist(40),
    );

    Hive.box<EcgRecord>('ecgBox').add(rec);
    ecgs.insert(0, rec);
  }
}
