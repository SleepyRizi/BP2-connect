// ────────────────────────────────────────────────────────────────────────────
// ecg_record.dart — v2   (adds QRS / PVCs / QTc)
// ────────────────────────────────────────────────────────────────────────────
import 'package:hive/hive.dart';

part 'ecg_record.g.dart';

@HiveType(typeId: 3)                     // keep the old typeId
class EcgRecord extends HiveObject {     // (extends HiveObject = convenient)
  EcgRecord({
    required this.start,
    required this.duration,
    required this.hr,
    required this.diagnosisBits,
    required this.wave,
    this.qrs = 0,                        // ← NEW (ms)
    this.pvcs = 0,                       // ← NEW (count)
    this.qtc = 0,                        // ← NEW (ms)
  });

  // ───────── basic fields (unchanged) ─────────
  @HiveField(0) DateTime  start;          // UTC
  @HiveField(1) int       duration;       // seconds
  @HiveField(2) int       hr;             // bpm
  @HiveField(3) int       diagnosisBits;  // 32-bit mask
  @HiveField(4) List<int> wave;           // Int16 little-endian

  // ───────── analysis extras ─────────
  @HiveField(5) int qrs;                  // ms
  @HiveField(6) int pvcs;                 // count
  @HiveField(7) int qtc;                  // ms
}
