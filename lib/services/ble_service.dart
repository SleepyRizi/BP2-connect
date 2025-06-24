//ble_service
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'bp2_protocol.dart';

class BleService {
  /* ───────── public stream of decoded frames ───────── */
  final _frames = StreamController<BP2Frame>.broadcast();
  Stream<BP2Frame> get frames => _frames.stream;

  /* ───────── private BLE handles ───────── */
  BluetoothDevice?            _dev;
  BluetoothCharacteristic?    _tx;
  BluetoothCharacteristic?    _rx;

  /* ───────── scan helpers ───────── */
  Stream<List<ScanResult>> scan() => FlutterBluePlus.scanResults;
  Future<void> startScan()        => FlutterBluePlus.startScan(withServices: []);
  Future<void> stopScan()         => FlutterBluePlus.stopScan();

  /* ───────── connect ───────── */
  Future<void> connect(ScanResult r) async {
    _dev = r.device;
    await _dev!.connect(autoConnect: false);

    /* Prefer Nordic 247-byte MTU */
    try { await _dev!.requestMtu(247); } catch (_) {}

    for (final s in await _dev!.discoverServices()) {
      if (s.serviceUuid.toString() ==
          '14839ac4-7d7e-415c-9a42-167340cf2339') {
        for (final c in s.characteristics) {
          switch (c.uuid.toString()) {
            case '8b00ace7-eb0b-49b0-bbe9-9aee0a26e1a3': _tx = c; break;
            case '0734594a-a8e7-4b1a-a6b1-cd5243059a57': _rx = c; break;
          }
        }
      }
    }
    if (_tx == null || _rx == null) {
      throw 'BP2 characteristics not found';
    }

    await _rx!.setNotifyValue(true);
    _rx!.value.listen(_onBytes);
  }

  Future<void> disconnect() async {
    await _dev?.disconnect();
    _dev = null;
  }

  Future<void> sendFrame(BP2Frame f) async {
    debugPrint('[BP2-TX] ' +
        f.encode().map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));
    await _tx?.write(f.encode(), withoutResponse: true);
  }



  /* ───────── packet assembler ───────── */

  /// buffer while building a headered packet (starts with 0xA5)
  final _hdrBuf = <int>[];

  void _onBytes(List<int> data) {
    debugPrint('[BP2-RX] ' +
        data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));

    //------------------------------------------------------------------
    // 1)  Header-less waveform chunks
    //     They only appear when we are *not currently* assembling
    //     a headered packet and the first byte is *not* 0xA5.
    //------------------------------------------------------------------
    if (_hdrBuf.isEmpty && data.isNotEmpty && data[0] != 0xA5) {
      // if length is odd keep last byte for next round (very rare)
      if (data.length.isOdd) {
        _hdrBuf.add(data.removeLast());
      }
      if (data.isNotEmpty) {
        _frames.add(BP2Frame.raw(Uint8List.fromList(data)));
      }
      return;
    }

    //------------------------------------------------------------------
    // 2)  Headered packets  (0xA5 … CRC)
    //------------------------------------------------------------------
    _hdrBuf.addAll(data);

    while (true) {
      // a) find start of a frame
      final start = _hdrBuf.indexOf(0xA5);
      if (start == -1) {
        // nothing that looks like a header → keep what we have for now
        break;
      }
      if (start > 0) _hdrBuf.removeRange(0, start);

      // b) need at least header + CRC
      if (_hdrBuf.length < 8) break;

      final len   = _hdrBuf[5] | (_hdrBuf[6] << 8);
      final need  = 7 + len + 1;            // header + DATA + CRC
      if (_hdrBuf.length < need) break;     // wait for rest

      final rawPkt = Uint8List.fromList(_hdrBuf.sublist(0, need));
      _hdrBuf.removeRange(0, need);

      final f = BP2Frame.decode(rawPkt);
      if (f != null) _frames.add(f);
    }

    //------------------------------------------------------------------
    // 3)  If the buffer now *starts* with non-A5 and is even-sized
    //     (can happen after stripping a headered packet), flush it
    //     as a waveform chunk.
    //------------------------------------------------------------------
    if (_hdrBuf.isNotEmpty && _hdrBuf[0] != 0xA5 && _hdrBuf.length.isEven) {
      final raw = Uint8List.fromList(_hdrBuf);
      _hdrBuf.clear();
      _frames.add(BP2Frame.raw(raw));
    }
  }
}
