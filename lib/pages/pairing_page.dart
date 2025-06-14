//pairing_page

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/device_controller.dart';

class PairingPage extends StatelessWidget {
  const PairingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<DeviceController>();

    return Scaffold(
      appBar: AppBar(title: const Text('BP2 Connect')),
      body: Obx(() {
        if (!c.isBleReady.value) {
          return Column(
            children: [
              if (!c.isScanning.value)
                ElevatedButton(onPressed: c.startScan, child: const Text('Scan')),
              Expanded(
                child: ListView.builder(
                  itemCount: c.devices.length,
                  itemBuilder: (_, i) {
                    final r = c.devices[i];
                    return ListTile(
                      title: Text(r.device.name),
                      subtitle: Text(r.device.id.id),
                      onTap: () => c.connectDevice(r),
                    );
                  },
                ),
              ),
            ],
          );
        }

        final di = c.info.value;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(di?.sn ?? '—', style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Text('Battery ${c.batteryPercent.value}%'),
              const SizedBox(height: 24),
              ElevatedButton(
                  onPressed: () => Get.toNamed('/live'),
                  child: const Text('Live Monitor')),
              const SizedBox(height: 8),
              ElevatedButton(
                  onPressed: () => Get.toNamed('/history'),
                  child: const Text('History')),
              const SizedBox(height: 24),
              // ElevatedButton(
              //   onPressed: () => _wifiDialog(c),
              //   child: const Text('Configure Wi-Fi'),
              // ),
              TextButton(onPressed: c.disconnect, child: const Text('Disconnect')),
            ],
          ),
        );
      }),
    );
  }

  // void _wifiDialog(DeviceController c) async {
  //   await c.refreshWifiList();
  //   Get.defaultDialog(
  //     title: 'Select Wi-Fi',
  //     content: Obx(() {
  //       if (c.wifiSsids.isEmpty) {
  //         return const Padding(
  //             padding: EdgeInsets.all(16), child: Text('Scanning…'));
  //       }
  //       final pwd = TextEditingController();
  //       var sel = c.wifiSsids.first.obs;
  //       return Column(
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         children: [
  //           ...c.wifiSsids.map((s) => Obx(() => RadioListTile(
  //             title: Text(s),
  //             dense: true,
  //             value: s,
  //             groupValue: sel.value,
  //             onChanged: (v) => sel.value = v!,
  //           ))),
  //           TextField(
  //             controller: pwd,
  //             decoration: const InputDecoration(labelText: 'Password'),
  //           ),
  //           const SizedBox(height: 8),
  //           ElevatedButton(
  //             onPressed: () async {
  //               await c.configWifi(sel.value, pwd.text.trim());
  //               Get.back();
  //             },
  //             child: const Text('Send'),
  //           )
  //         ],
  //       );
  //     }),
  //   );
  // }
}
