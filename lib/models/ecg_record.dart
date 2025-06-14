// NEW FILE
import 'package:hive/hive.dart';
part 'ecg_record.g.dart';

@HiveType(typeId: 3)
class EcgRecord {
  EcgRecord({
    required this.start,
    required this.duration,
    required this.hr,
    required this.diagnosisBits,
    required this.wave,          // raw ADC samples, mV conversion is UI side
  });

  @HiveField(0) DateTime start;
  @HiveField(1) int      duration;      // seconds
  @HiveField(2) int      hr;
  @HiveField(3) int      diagnosisBits; // 32-bit mask
  @HiveField(4) List<int> wave;         // Int16 list (little-endian)
}
