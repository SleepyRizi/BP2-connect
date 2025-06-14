//bp_record.dart

import 'package:hive/hive.dart';

part 'bp_record.g.dart';

@HiveType(typeId: 2)
class BpRecord {
  BpRecord({
    required this.systolic,
    required this.diastolic,
    required this.mean,
    required this.pulse,
    required this.time,
  });

  @HiveField(0)
  int systolic;
  @HiveField(1)
  int diastolic;
  @HiveField(2)
  int mean;
  @HiveField(3)
  int pulse;
  @HiveField(4)
  DateTime time;
}
