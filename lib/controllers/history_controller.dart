// ─────────────────────────────────────────────────────────────
// lib/controllers/history_controller.dart  –  V3 (14 Jun 2025)
//   • Adds ECG download / parsing logic (F1–F4)
//   • Keeps legacy BP parser for backwards‑compat
// ─────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert' show ascii;

import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '../models/bp_record.dart';
import '../models/ecg_record.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart';

class HistoryController extends GetxController {
  // BLE service handle
  final _ble = Get.find<BleService>();

  // ======= Local caches =======
  final RxList<BpRecord>  records = <BpRecord>[].obs;   // blood‑pressure list
  final RxList<EcgRecord> ecgs    = <EcgRecord>[].obs;  // finished ECGs

  // ======= Startup =======
  @override
  void onInit() {
    super.onInit();
    // Still listen for BP file pushes (old mechanism)
    _ble.frames.listen(_onFrame);
  }

  // ---------------------------------------------------------------------
  //                            BP  (unchanged)
  // ---------------------------------------------------------------------
  Future<void> syncFromDevice() async {
    await _ble.sendFrame(getFileList());   // legacy BP sync
  }

  void _onFrame(BP2Frame f) async {
    if (f.cmd == 0xF1 && f.pkgType == 0x01) {
      // File list → iterate BP records (each name 16 B)
      int pos = 1;                     // first byte = file_num
      while (pos + 16 <= f.data.length) {
        final name = ascii.decode(
            f.data.sublist(pos, pos + 16)).split('\x00').first;
        pos += 16;
        final id = records.length;           // any unique slot ok
        await _ble.sendFrame(readFile(id, 0));
      }
    } else if (f.cmd == 0xF2 && f.pkgType == 0x01) {
      _parseBpFile(Uint8List.fromList(f.data));
    }
  }

  void _parseBpFile(Uint8List bytes) {
    if (bytes.length < 21) return;

    // FileHead_t occupies first 14 bytes (V2)
    final mode = bytes[9];                       // measure_mode
    if (mode != 0) return;                       // only single‑mode here

    final systolic  = bytes[14] | (bytes[15] << 8);
    final diastolic = bytes[16] | (bytes[17] << 8);
    final mean      = bytes[18] | (bytes[19] << 8);
    final pulse     = bytes[20];

    final ts = _tsFromName(
        ascii.decode(bytes.sublist(0, 14)).replaceAll('\u0000', ''));

    final rec = BpRecord(
      systolic : systolic,
      diastolic: diastolic,
      mean     : mean,
      pulse    : pulse,
      time     : ts,
    );

    Hive.box<BpRecord>('bpBox').add(rec);
    records.insert(0, rec);
  }

  // Helper: convert “yyyyMMddhhmmss” → DateTime (UTC)
  DateTime _tsFromName(String name) => DateTime.utc(
    int.parse(name.substring(0, 4)),
    int.parse(name.substring(4, 6)),
    int.parse(name.substring(6, 8)),
    int.parse(name.substring(8, 10)),
    int.parse(name.substring(10, 12)),
    int.parse(name.substring(12, 14)),
  );

  // ---------------------------------------------------------------------
  //                         ECG  (new logic)
  // ---------------------------------------------------------------------

  /// Public entry — called from DeviceController.stopEcg()
  Future<void> syncLatestEcg() async {
    // 1) switch to review mode (Target_status = 2)
    await _ble.sendFrame(switchToMemory());
    await Future.delayed(const Duration(milliseconds: 300));

    // 2) fetch file list
    final listReply = await _awaitReply(getFileList());
    if (listReply == null || listReply.data.isEmpty) return;

    final count = listReply.data[0];
    if (count == 0) return;                        // no records stored

    final nameBytes = listReply.data.sublist(
        1 + (count - 1) * 16, 1 + count * 16);
    final fileName = ascii.decode(nameBytes).split('\x00').first.trim();

    // 3) get total file size (Read Start)
    final startReply = await _awaitReply(readFileStart(fileName, 0));
    if (startReply == null || startReply.data.length < 4) return;
    final total = ByteData.sublistView(Uint8List.fromList(startReply.data), 0, 4)
        .getUint32(0, Endian.little);

    // 4) stream file data in 1 kB chunks
    final buff   = BytesBuilder();
    var   offset = 0;
    const chunk  = 1024;
    while (offset < total) {
      final part = await _awaitReply(
          readFileData(offset, (total - offset).clamp(0, chunk)));
      if (part == null) return;          // abort on timeout
      buff.add(part.data);
      offset += part.data.length;
    }
    await _ble.sendFrame(readFileEnd());

    // 5) decode & persist
    _parseEcgFile(buff.toBytes());
  }

  // Low‑level round‑trip helper ------------------------------------------------
  Future<BP2Frame?> _awaitReply(BP2Frame req) async {
    final c = Completer<BP2Frame?>();
    late final sub;
    sub = _ble.frames.listen((f) {
      if (f.cmd == req.cmd && f.pkgType == 0x01) {
        sub.cancel();
        c.complete(f);
      }
    });
    await _ble.sendFrame(req);
    return c.future.timeout(const Duration(seconds: 2), onTimeout: () {
      sub.cancel();
      return null;
    });
  }

  // ECG file decoder ----------------------------------------------------------
  void _parseEcgFile(Uint8List bytes) {
    if (bytes.length < 40) return;            // header + analysis

    final startUnix = ByteData.sublistView(bytes, 4, 8)
        .getUint32(0, Endian.little);
    final start     =
    DateTime.fromMillisecondsSinceEpoch(startUnix * 1000, isUtc: true);

    final analysis  = ByteData.sublistView(bytes, 8, 40);
    final duration  = analysis.getUint32(0, Endian.little);
    final diagBits  = analysis.getUint32(4, Endian.little);
    final hr        = analysis.getUint16(12, Endian.little);

    final waveBytes = bytes.sublist(40);       // raw Int16 LE waveform

    final rec = EcgRecord(
      start         : start,
      duration      : duration,
      hr            : hr,
      diagnosisBits : diagBits,
      wave          : waveBytes,
    );

    Hive.box<EcgRecord>('ecgBox').add(rec);
    ecgs.insert(0, rec);
  }
}