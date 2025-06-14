import 'package:hive/hive.dart';

part 'device_info.g.dart';

@HiveType(typeId: 1)
class DeviceInfo {
  DeviceInfo({required this.sn, required this.hw, required this.fw});

  @HiveField(0)
  String sn;
  @HiveField(1)
  String hw;
  @HiveField(2)
  String fw;
}
