//bp2_protol.dart
import 'dart:convert';
import 'dart:typed_data';

/* ───────── Frame object ───────── */

/* ───────── Frame object ───────── */

class BP2Frame {
  /// Regular headered frame (starts with 0xA5)
  BP2Frame({
    required this.cmd,
    this.pkgType = 0,
    this.pkgNo   = 0,
    this.data    = const [],
  })  : raw = Uint8List(0);

  /// Header-less waveform chunk (device pushes these after 0x08)
  BP2Frame.raw(this.raw)
      : cmd = null,
        pkgType = 0,
        pkgNo   = 0,
        data    = const [];

  /* --------------- fields --------------- */
  final int?       cmd;        // null  ⇒ purely-raw samples
  final int        pkgType;
  final int        pkgNo;
  final List<int>  data;
  final Uint8List  raw;

  bool get isRaw => cmd == null;

  /* --------------- encode --------------- */
  Uint8List encode() {
    if (cmd == null) {
      throw StateError('Cannot encode a raw (header-less) frame');
    }
    final len = data.length;
    final bb  = BytesBuilder();
    bb.add([
      0xA5,
      cmd!,
      (~cmd!) & 0xFF,
      pkgType,
      pkgNo,
      len & 0xFF,
      len >> 8
    ]);
    bb.add(data);
    bb.addByte(_crc8(bb.toBytes()));
    return bb.toBytes();
  }

  /* --------------- decode --------------- */
  static BP2Frame? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    // ----- headered packet -----
    if (bytes[0] == 0xA5) {
      if (bytes.length < 8) return null;             // header + CRC
      if (((~bytes[1]) & 0xFF) != bytes[2]) return null; // bad ~CMD
      final len = bytes[5] | (bytes[6] << 8);
      if (bytes.length != 7 + len + 1) return null;  // size mismatch
      return BP2Frame(
        cmd     : bytes[1],
        pkgType : bytes[3],
        pkgNo   : bytes[4],
        data    : bytes.sublist(7, 7 + len),
      );
    }

    // ----- header-less waveform chunk -----
    if ((bytes.length & 1) == 0) {                   // must be even
      return BP2Frame.raw(bytes);
    }

    return null;     // garbage
  }

  /* ───────── CRC-8 (poly 0x07) ───────── */
  static int _crc8(List<int> b) {
    var crc = 0;
    const poly = 0x07;
    for (final byte in b) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x80) != 0
            ? ((crc << 1) ^ poly) & 0xFF
            : (crc << 1) & 0xFF;
      }
    }
    return crc;
  }
}


/* ───────── convenience helpers ───────── */

Uint8List _element(String s) =>
    Uint8List.fromList([s.length, ...ascii.encode(s)]);

/* ───────── short requests ───────── */

BP2Frame echo()             => BP2Frame(cmd: 0xE0, pkgType: 0, pkgNo: 0, data: [0x55]);
BP2Frame getDeviceInfo()    => BP2Frame(cmd: 0xE1, pkgType: 0, pkgNo: 0);
BP2Frame getBattery()       => BP2Frame(cmd: 0xE4, pkgType: 0, pkgNo: 0);

BP2Frame switchToEcg()      => BP2Frame(cmd: 0x09, pkgType: 0, pkgNo: 0, data: [1]);
BP2Frame switchToBp()       => BP2Frame(cmd: 0x09, pkgType: 0, pkgNo: 0, data: [0]);
BP2Frame startBpTest()      => BP2Frame(cmd: 0x0A, pkgType: 0, pkgNo: 0, data: [170, 0]);

/* ───────── real-time streaming ───────── */

/// Wrapper stream (CMD 0x08) – ECG *or* BP, depending on current mode.
/// `rate` = packets per second (1-25). 0 stops the stream.
BP2Frame rtWrapper(int rate) =>
    BP2Frame(cmd: 0x08, pkgType: 0, pkgNo: 0, data: [rate]);

/// Pure waveform stream (CMD 0x07). Same rate rules as above.
BP2Frame rtWave(int rate) =>
    BP2Frame(cmd: 0x07, pkgType: 0, pkgNo: 0, data: [rate]);

/* ───────── file access (unchanged) ───────── */

BP2Frame getFileList()      => BP2Frame(cmd: 0xF1, pkgType: 0, pkgNo: 0);
BP2Frame readFile(int id, int off) =>
    BP2Frame(cmd: 0xF2, pkgType: 0, pkgNo: 0, data: [id, off & 0xFF, off >> 8]);

/* ───────── ECG helpers ───────── */

/// Convert 16-bit ADC values to mV (125 Hz or 250 Hz ECG).
List<double> decodeEcg(List<int> bytes) {
  final out = <double>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final n = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16);
    out.add(n * 0.003098);          // datasheet factor
  }
  return out;
}
