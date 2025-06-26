// ecg_record.dart — v3
import 'dart:typed_data';
import 'package:hive/hive.dart';
part 'ecg_record.g.dart';

@HiveType(typeId: 3)
class EcgRecord extends HiveObject {
  EcgRecord({
    required this.start,
    required this.duration,
    required this.hr,
    required this.diagnosisBits,
    required this.wave,
    this.qrs  = 0,
    this.pvcs = 0,
    this.qtc  = 0,
  });


  factory EcgRecord.fromBytes(Uint8List buf, {int sps = 125}) {
    if (buf.length < 60 || buf[1] != 0x02) {
      throw const FormatException('not an ECG payload');
    }

    const hdr        = 10;          // “01 02” + 8 reserved bytes
    const resOld     = 38;          // 2023 fw  (wave @ 48)
    const resNew     = 44;          // 2025 fw  (wave @ 54)

    // Offsets **inside** AnalysisResult_t (little-endian)
    const tsOff   =  0;          // u32  start epoch (s)
    const maskOff =  4;          // u32  diagnosis mask
    const durOffN = 10;          // u32  duration for *new* header
    const hrOffN  = 18;          // u16  HR       for *new* header
    const qrsOffN = 20;
    const pvcOffN = 22;
    const qtcOffN = 24;

    final bd = ByteData.sublistView(buf);

    int duration = bd.getUint32(hdr + durOffN, Endian.little);
    int hr       = bd.getUint16(hdr + hrOffN , Endian.little);
    final bool newLay = hr > 20 && hr < 250 && duration != 0;

    // Fall back to V1 offsets if “new” looks fishy
    final dur    = newLay ? duration                    : bd.getUint32(hdr +  8, Endian.little);
    final hrate  = newLay ? hr                          : bd.getUint16(hdr + 12, Endian.little);
    final qrs    = newLay ? bd.getUint16(hdr + qrsOffN, Endian.little)
        : bd.getUint16(hdr + 14      , Endian.little);
    final pvcs   = newLay ? bd.getUint16(hdr + pvcOffN, Endian.little)
        : bd.getUint16(hdr + 16     , Endian.little);
    final qtc    = newLay ? bd.getUint16(hdr + qtcOffN, Endian.little)
        : bd.getUint16(hdr + 18     , Endian.little);

    final mask   = bd.getUint32(hdr + maskOff, Endian.little);
    final epoch  = bd.getUint32(hdr + tsOff  , Endian.little);

    final waveOff = hdr + (newLay ? resNew : resOld);
    if (buf.length <= waveOff + 2) {
      throw const FormatException('truncated wave');
    }
    final wave     = buf.sublist(waveOff);
    final secsFromWave = (wave.length ~/ 2) ~/ sps;

    return EcgRecord(
      start         : DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true).toLocal(),
      duration      : dur == 0 ? secsFromWave : dur,
      hr            : hrate == 0xFFFF ? 0 : hrate,
      diagnosisBits : mask,
      wave          : wave,
      qrs           : qrs,
      pvcs          : pvcs,
      qtc           : qtc,
    );
  }

  /* ─── plain data fields remain unchanged ─── */
  @HiveField(0) DateTime  start;
  @HiveField(1) int       duration;
  @HiveField(2) int       hr;
  @HiveField(3) int       diagnosisBits;
  @HiveField(4) Uint8List wave;

  @HiveField(5) int qrs;
  @HiveField(6) int pvcs;
  @HiveField(7) int qtc;
}
