//wifi_service.dart
// ────────────────────────────────────────────────────────────────
// lib/services/wifi_service.dart  (FULL FILE)
// ────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:wifi_iot/wifi_iot.dart';
import 'bp2_protocol.dart';

class WifiService {
  Socket? _sock;
  final _rxCtrl = StreamController<BP2Frame>.broadcast();
  Stream<BP2Frame> get frames => _rxCtrl.stream;

  /*  connect to device’s own AP  */
  Future<bool> connectAp({required String ssid, String pwd = ''}) async {
    await WiFiForIoTPlugin.connect(
      ssid,
      security: pwd.isEmpty ? NetworkSecurity.NONE : NetworkSecurity.WPA,
      password: pwd,
      withInternet: false,
    );
    return connectHost('192.168.4.1', 8899);
  }

  /*  general helper – connect to any IP/port  */
  Future<bool> connectHost(String ip, int port) async {
    try {
      _sock?.destroy();
      _sock = await Socket.connect(ip, port, timeout: const Duration(seconds: 10));
      _sock!.listen(_onBytes, onDone: () => _sock = null, onError: (_) => _sock = null);
      return true;
    } catch (_) {
      _sock = null;
      return false;
    }
  }

  bool get isConnected => _sock != null;

  Future<void> sendFrame(BP2Frame f) async => _sock?.add(f.encode());

  Future<void> close() async {
    _sock?.destroy();  // destroy() returns void → no await
    _sock = null;
  }

  /*  ────────── byte assembler ────────── */
  final _buf = <int>[];
  void _onBytes(List<int> data) {
    _buf.addAll(data);
    while (true) {
      final idx = _buf.indexOf(0xA5);
      if (idx < 0) break;
      if (idx > 0) _buf.removeRange(0, idx);
      if (_buf.length < 7) break;

      final len  = _buf[5] | (_buf[6] << 8);
      final need = 7 + len + 1;
      if (_buf.length < need) break;

      final pkt = Uint8List.fromList(_buf.sublist(0, need));
      _buf.removeRange(0, need);

      final f = BP2Frame.decode(pkt);
      if (f != null) _rxCtrl.add(f);
    }
  }
}
