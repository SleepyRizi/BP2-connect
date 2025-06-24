import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';       // ← new
import 'app_binding.dart';
import 'models/device_info.dart';
import 'models/bp_record.dart';
import 'models/ecg_record.dart';
import 'pages/pairing_page.dart';
import 'pages/live_page.dart';
import 'pages/history_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*  runtime permissions before GetX bindings  */
  await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
    Permission.nearbyWifiDevices,
  ].request();

  await Hive.initFlutter();
  Hive.registerAdapter(DeviceInfoAdapter());
  Hive.registerAdapter(BpRecordAdapter());
  Hive.registerAdapter(EcgRecordAdapter());
  await Hive.openBox<DeviceInfo>('deviceInfoBox');
  await Hive.openBox<BpRecord>('bpBox');
  await Hive.openBox<EcgRecord>('ecgBox');   // <-- add this

  runApp(const BP2App());
}

class BP2App extends StatelessWidget {
  const BP2App({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'BP2 Connect Demo',
      debugShowCheckedModeBanner: false,
      initialBinding: AppBinding(),         // ← binding is now synchronous
      getPages: [
        GetPage(name: '/',     page: () => const PairingPage()),
        GetPage(name: '/live', page: () => const LivePage()),
        GetPage(name: '/history', page: () => const HistoryPage()),
      ],
      theme: ThemeData.light(useMaterial3: true),
    );
  }
}
