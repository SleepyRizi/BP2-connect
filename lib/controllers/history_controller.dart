import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import '../models/bp_record.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart';
import 'dart:convert' show ascii;

class HistoryController extends GetxController {
  final _ble = Get.find<BleService>();
  final RxList<BpRecord> records = <BpRecord>[].obs;

  @override
  void onInit() {
    super.onInit();
    _ble.frames.listen(_onFrame);
  }

  Future<void> syncFromDevice() async {
    await _ble.sendFrame(getFileList());
  }

  /*  very small helper to turn “yyyyMMddhhmmss” into DateTime  */
  DateTime _tsFromName(String name) {
    final y = int.parse(name.substring(0, 4));
    final m = int.parse(name.substring(4, 6));
    final d = int.parse(name.substring(6, 8));
    final H = int.parse(name.substring(8, 10));
    final M = int.parse(name.substring(10, 12));
    final S = int.parse(name.substring(12, 14));
    return DateTime.utc(y, m, d, H, M, S);
  }

  void _onFrame(BP2Frame f) async {
    if (f.cmd == 0xF1 && f.pkgType == 0x01) {        // FileList
      int pos = 1;                                   // first byte = file_num
      while (pos + 16 <= f.data.length) {
        final name = String.fromCharCodes(
            f.data.sublist(pos, pos + 16)).split('\x00').first;
        pos += 16;
        final id = records.length;                   // any unique slot is ok
        await _ble.sendFrame(readFile(id, 0));
      }
    } else if (f.cmd == 0xF2 && f.pkgType == 0x01) { // FileStart → chunk
      _parseBpFile(Uint8List.fromList(f.data));
    }
  }

  void _parseBpFile(Uint8List bytes) {
    if (bytes.length < 14) return;

    /*  FileHead_t occupies first 14 bytes in V2  */
    final mode = bytes[9];                           // measure_mode
    if (mode != 0) return;                           // only single mode here

    final systolic  = bytes[14] | (bytes[15] << 8);
    final diastolic = bytes[16] | (bytes[17] << 8);
    final mean      = bytes[18] | (bytes[19] << 8);
    final pulse     = bytes[20];
    final ts = _tsFromName(
        ascii.decode(bytes.sublist(0, 14)).replaceAll('\u0000', ''));

    final rec = BpRecord(
      systolic: systolic,
      diastolic: diastolic,
      mean: mean,
      pulse: pulse,
      time: ts,
    );

    Hive.box<BpRecord>('bpBox').add(rec);
    records.add(rec);
  }
}
