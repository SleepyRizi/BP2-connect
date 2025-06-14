import 'package:get/get.dart';
import 'services/ble_service.dart';
import 'controllers/device_controller.dart';
import 'controllers/history_controller.dart';

class AppBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(() => BleService(), fenix: true);
    Get.put(DeviceController(), permanent: true);
    Get.put(HistoryController(), permanent: true);
  }
}
