// device_controller.dart – Release 21 Jun 2025
//
//  • no-packet-loss poller: we only send the next 0×08 when the previous one
//    has been acknowledged (fixes occasional HR off-by-2).
//  • final UI push in stopEcg() so the last samples are never dropped.
//  • keep a 60 s history buffer for post-run scrolling.
//  • small refactor: _maybePushToUi([force]) and _releaseBusy() helper.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../models/device_info.dart';
import '../services/ble_service.dart';
import '../services/bp2_protocol.dart';
import 'history_controller.dart';

class DeviceController extends GetxController {
  /* ───────── general ───────── */
  static const bool _dbg = false;

  /* ───────── BLE ───────── */
  final _ble       = Get.find<BleService>();
  final isScanning = false.obs;
  final isBleReady = false.obs;
  final devices    = [].obs;

  /* ───────── UI bindables ───────── */
  final info           = Rx<DeviceInfo?>(null);
  final batteryPercent = 0.obs;
  final statusText     = 'Idle'.obs;
  final diagText       = ''.obs;
  final bpmNow         = 0.obs, sysNow = 0.obs, diaNow = 0.obs;
  final ecg            = <FlSpot>[].obs;
  bool get isRunning => _ecgRunning;

  /* Y-axis */
  final yScale = 2.0.obs;                                  // 2 / 1 / 0.5 mV div⁻¹
  void cycleYScale() =>
      yScale.value = yScale.value == 2 ? 1 : yScale.value == 1 ? .5 : 2;

  /* X-axis (speed ↔ window) */
  final _speedLabels = ['25', '12.5', '6.25'];             // mm s⁻¹
  final _windowsSec  = [3.0, 6.0, 12.0];                   // visible window
  final xSpeedIdx    = 0.obs;
  String get speedLbl  => _speedLabels[xSpeedIdx.value];
  double get windowSec => _windowsSec[xSpeedIdx.value];
  void  cycleSpeed() {
    xSpeedIdx.value = (xSpeedIdx.value + 1) % _speedLabels.length;
    _trimRing();
  }

  /* ───────── buffers & timers ───────── */
  static const double _historySec = 60;                    // retained for scroll
  double _t                = 0;                            // running time axis
  double _lastUiPush       = 0;
  late final List<FlSpot> _ring;
  Timer? _poll;
  StreamSubscription? _bleSub;
  bool _busy               = false;                       // poller debounce flag
  bool _ecgRunning = false;                // <─ NEW
  /* ───────── lifecycle ───────── */
  @override
  void onInit() {
    super.onInit();
    _ring = <FlSpot>[];
    _bleSub = _ble.frames.listen(_dispatch);
    startScan();
  }

  @override
  void onClose() {
    _poll?.cancel();
    _bleSub?.cancel();
    super.onClose();
  }

  /* ═════════ BLE scan / connect ═════════ */
  Future<void> startScan() async {
    isScanning.value = true;
    await _ble.startScan();
    _ble.scan().listen(
          (rs) => devices.assignAll(
        rs.where((r) => r.device.name.toUpperCase().contains('BP2')),
      ),
      onDone: () => isScanning.value = false,
    );
  }

  Future<void> connectDevice(dynamic r) async {
    await _ble.stopScan();
    await _ble.connect(r);
    isBleReady.value = true;

    await _send(echo());
    await _send(getDeviceInfo());
    await _send(getBattery());
    await _send(deleteAllFiles());   // clear history right after a successful connect
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    await _ble.disconnect();
    isBleReady.value = false;
  }

  /* ═════════ BP (unchanged) ═════════ */
  Future<void> startBp({int rate = 10}) async {
    await _send(switchToBp());
    await Future.delayed(const Duration(milliseconds: 300));
    await _send(startBpTest());
    await Future.delayed(const Duration(milliseconds: 500));
    await _send(rtWave(rate.clamp(1, 25)));
  }

  /* ═════════ ECG control ═════════ */
  Future<void> startEcg() async {
    // UI prep
    statusText.value = 'ECG-Prep';
    diagText.value   = '';
    bpmNow.value     = 0;
    _ring.clear();
    ecg.value = [];
    _t = 0;
    _lastUiPush = 0;

    // 1 │ switch mode
    await _send(switchToEcg());
    await Future.delayed(const Duration(milliseconds: 150));

    // 2 │ wait RunStatus = 6
    var ready = false;
    late final StreamSubscription sub;
    sub = _ble.frames.listen((f) {
      if (f.cmd == 0x06 && f.data.isNotEmpty && f.data[0] == 6) {
        ready = true;
        if (f.data.length >= 3) _updBattery(f.data[2]);
        sub.cancel();
      }
    });
    final t0 = DateTime.now();
    while (!ready && DateTime.now().difference(t0).inSeconds < 3) {
      await _send(BP2Frame(cmd: 0x06));
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!ready) {
      statusText.value = 'ECG-timeout';
      return;
    }

    // 3 │ open realtime wave + wrapper
    await _send(rtWave(25));       // 250 Hz
    await _send(rtWrapper(25));

    // 4 │ loss-free poller
    _poll = Timer.periodic(const Duration(milliseconds: 40), (_) async {
      if (_busy) return;
      _busy = true;
      await _send(BP2Frame(cmd: 0x08));
    });
    _ecgRunning = true;                  // ← moved down
    statusText.value = 'ECG-Measuring';
  }
// DeviceController
  /// Make absolutely sure the device is NOT in realtime mode.
  /// Safe to call even when no ECG is running.
  /// Make absolutely sure the device is NOT in realtime mode.
  /// Safe to call even if no ECG is currently running.
  Future<void> stopRealtime() async {
    // 1 ─ stop the poller no-matter-what
    _poll?.cancel();
    _poll = null;            // <-- avoid zombie timer
    _busy = true;            // block new polls while we drain

    // 2 ─ tell firmware to close both realtime channels
    await _send(rtWave(0));      // CMD 0x07 wrapper
    await _send(rtWrapper(0));   // CMD 0x08 waveform (ACK will bounce)

    // 3 ─ wait until we have seen *at least one* 0x08 echo
    //     and then 300 ms of complete silence
    var last08 = DateTime.now();
    final sub = _ble.frames.listen((f) {
      if (f.cmd == 0x08) last08 = DateTime.now();
    });

    while (DateTime.now().difference(last08).inMilliseconds < 300) {
      await Future.delayed(const Duration(milliseconds: 60));
    }
    await sub.cancel();

    // 4 ─ reset state
    _busy = false;
    _ecgRunning = false;
    statusText.value = 'Idle';
  }

  /* ═════════ ECG control ═════════ */
  Future<void> stopEcg() async {
    if (!_ecgRunning) return;      // already stopping/running a sync
    _ecgRunning = false;           // ← put it right here, first line

    _log('⇢ ECG stop');

    _poll?.cancel();
    _busy = true;

    await _send(rtWave(0));
    await _send(rtWrapper(0));
    _maybePushToUi(force: true);
    // 2) wait until the device sends its *last* 0x08
    bool quiet = false;
    late final sub;
    sub = _ble.frames.listen((f) { if (f.cmd == 0x08) quiet = false; });
    while (!quiet) {
      quiet = true;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    sub.cancel();

    // 3) hand control to HistoryController
    _ecgRunning = false;                   // <─ NEW
    Get.find<HistoryController>().syncLatestEcg();
    statusText.value = 'Idle';
  }


  /* ═════════ dispatch ═════════ */
  void _dispatch(BP2Frame f) {
    if (_dbg) {
      _log('RX cmd=${f.cmd?.toRadixString(16) ?? '--'} '
          'raw=${f.isRaw ? f.raw.length : 0} len=${f.data.length}');
    }

    switch (f.cmd) {
      case 0xE1: info.value = _parseInfo(f.data);   break;
      case 0xE4: if (f.data.length>=2) _updBattery(f.data[1]); break;
      case 0x06:
        if (f.data.length>=3) _updBattery(f.data[2]);
        if (f.data.isNotEmpty && f.data[0] == 1 /*Review*/) {
          _poll?.cancel();             // <- make sure it stays off
          _busy = false;
        }
        if (f.data.isNotEmpty) statusText.value = _statusLabel(f.data[0]);
        /* auto-stop when the device itself ends the ECG           */
        if (f.data.isNotEmpty && f.data[0] == 7 && _ecgRunning) {
          // RunStatus == 7  →  “ECG-End”
          stopEcg();
          return;
        }
        break;
      case 0x07: _handleRtWave(f.data);             break;
      case 0x08: _handleRtData(f.data);             break;
    }

    /* raw slices (rare) */
    if (f.isRaw && f.raw.isNotEmpty) _consumeSampleBytes(f.raw);

    _releaseBusy(f.cmd);
  }

  void _releaseBusy(int? cmd) {
    if (cmd == 0x08 || cmd == 0x07) _busy = false;
  }

  /* ═════════ realtime data ═════════ */

  void _handleRtData(List<int> d) {
    if (d.length < 32) return;                 // RS + header

    final hr  = _u16(d, d[9]==2 ? 18 : 14);
    if (hr>25 && hr<240) bpmNow.value = hr;

    final diag = d[9] | (d[10]<<8) | (d[11]<<16) | (d[12]<<24);
    if (diag==0xFFFFFFFF || diag==0xFFFFFFFE) {
      diagText.value = 'Signal poor – adjust grip';
    } else if (diag!=0) {
      diagText.value = <String>[
        if (diag & 0x1   !=0) 'HR>100',
        if (diag & 0x2   !=0) 'HR<50',
        if (diag & 0x4   !=0) 'Irregular RR',
        if (diag & 0x8   !=0) 'PVC',
        if (diag & 0x10  !=0) 'Possible arrest',
        if (diag & 0x20  !=0) 'A-Fib',
        if (diag & 0x40  !=0) 'QRS wide',
        if (diag & 0x80  !=0) 'QTc long',
        if (diag & 0x100 !=0) 'QTc short',
      ].join(', ');
    }

    _handleRtWave(d.sublist(9));               // strip RunStatus
  }

  void _handleRtWave(List<int> d) {
    if (d.length<25) return;
    final cnt = d[21] | (d[22]<<8);
    final end = 23 + cnt*2;
    if (end> d.length) return;
    _consumeSampleBytes(d.sublist(23, end));
  }

  /* ═════════ sample ingestion ═════════ */

  void _consumeSampleBytes(List<int> bytes) {
    for (var i = 0; i+1 < bytes.length; i+=2) {
      final mv = (bytes[i] | (bytes[i+1]<<8)).toSigned(16) * 0.003098;
      _ring.add(FlSpot(_t, mv));
      _t += 1/250.0;
    }
    _trimRing();
    _maybePushToUi();
  }

  void _trimRing() {
    final maxSamples = (math.max(windowSec, _historySec) * 250).toInt();
    if (_ring.length > maxSamples) {
      _ring.removeRange(0, _ring.length - maxSamples);
    }
  }

  void _maybePushToUi({bool force=false}) {
    if (force || _t - _lastUiPush >= 0.10) {   // 10 Hz
      ecg.value = List<FlSpot>.from(_ring);
      _lastUiPush = _t;
    }
  }

  /* ═════════ utils ═════════ */

  Future<void> _send(BP2Frame f) async {
    debugPrint('[DBG-TX] ${f.encode().map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    if (_dbg) {
      _log('TX cmd=${f.cmd?.toRadixString(16)??'--'} '
          'type=${f.pkgType} no=${f.pkgNo} len=${f.data.length}');
    }
    await _ble.sendFrame(f);
  }

  void _updBattery(int pct){
    if(pct==batteryPercent.value) return;
    batteryPercent.value = pct;
    _log('⚡ battery $pct %');
  }

  int _u16(List<int> b,int o)=>b[o]|(b[o+1]<<8);

  String _statusLabel(int c)=>[
    'Sleep','Review','Charge','Ready',
    'BP-Meas','BP-End','ECG-Meas','ECG-End'
  ].elementAt(c.clamp(0,7));

  DeviceInfo _parseInfo(List<int> d){
    if(d.length<40) return DeviceInfo(sn:'?', hw:'', fw:'');
    final hw  = String.fromCharCode(d[0]);
    final fw  = '${d[3]}.${d[2]}.${d[1]}';
    final len = d[37].clamp(0,18);
    final sn  = ascii.decode(d.sublist(38,38+len)).trim();
    return DeviceInfo(sn:sn, hw:hw, fw:fw);
  }

  void _log(Object m){
    if(_dbg) debugPrint('[DEV] ${DateTime.now().toIso8601String()} $m');
  }
}