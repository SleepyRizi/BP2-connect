// bp2_protocol.dart
import 'dart:convert';
import 'dart:typed_data';

/* ───────── Frame object ───────── */

class BP2Frame {
  BP2Frame({
    required this.cmd,
    this.pkgType = 0,
    this.pkgNo   = 0,
    this.data    = const [],
  }) : raw = Uint8List(0);

  BP2Frame.raw(this.raw)
      : cmd = null, pkgType = 0, pkgNo = 0, data = const [];

  final int?       cmd;          // null ⇒ raw waveform chunk
  final int        pkgType;
  final int        pkgNo;
  final List<int>  data;
  final Uint8List  raw;

  bool get isRaw => cmd == null;

  Uint8List encode() {
    if (cmd == null) throw StateError('raw chunk can’t be encoded');
    final bb = BytesBuilder();
    final len = data.length;
    bb.add([
      0xA5,
      cmd!, (~cmd!) & 0xFF,
      pkgType, pkgNo,
      len & 0xFF, len >> 8
    ]);
    bb.add(data);
    bb.addByte(_crc8(bb.toBytes()));
    return bb.toBytes();
  }

  static BP2Frame? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes[0] == 0xA5) {
      if (bytes.length < 8) return null;
      if (((~bytes[1]) & 0xFF) != bytes[2]) return null;
      final len = bytes[5] | (bytes[6] << 8);
      if (bytes.length != 7 + len + 1) return null;
      return BP2Frame(
        cmd     : bytes[1],
        pkgType : bytes[3],
        pkgNo   : bytes[4],
        data    : bytes.sublist(7, 7 + len),
      );
    }
    if (bytes.length.isEven) return BP2Frame.raw(bytes);
    return null;
  }

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

Uint8List _element(String s) =>
    Uint8List.fromList([s.length, ...ascii.encode(s)]);

BP2Frame echo()             => BP2Frame(cmd: 0xE0, data: [0x55]);
BP2Frame getDeviceInfo()    => BP2Frame(cmd: 0xE1);
BP2Frame getBattery()       => BP2Frame(cmd: 0xE4);

BP2Frame switchToEcg()      => BP2Frame(cmd: 0x09, data: [1]);
BP2Frame switchToBp()       => BP2Frame(cmd: 0x09, data: [0]);
BP2Frame startBpTest()      => BP2Frame(cmd: 0x0A, data: [0xAA, 0x00]);

BP2Frame rtWrapper(int r)   => BP2Frame(cmd: 0x08, data: [r]);
BP2Frame rtWave   (int r)   => BP2Frame(cmd: 0x07, data: [r]);

// ★ FIXED: correct one‑byte payload as per spec – no userId argument
/* ───── review / memory mode ─────
 * two-byte payload:  [2 /*target-state*/, userId]             */
BP2Frame switchToMemory()   => BP2Frame(cmd: 0x09, data: const [2]);

BP2Frame getFileList()      => BP2Frame(cmd: 0xF1);

// Delete every file in Review / Memory mode (no payload == “all”)
BP2Frame deleteAllFiles() => BP2Frame(cmd: 0xF8);

BP2Frame readFileStart(String n, int off) {
  final d = Uint8List(20)..fillRange(0, 20, 0);
  d.setRange(0, 16, ascii.encode(n.padRight(16, '\x00')));
  ByteData.view(d.buffer).setUint32(16, off, Endian.little);
  return BP2Frame(cmd: 0xF2, data: d);
}

BP2Frame readFileData(int off, int len) {
  final d = Uint8List(6);
  ByteData.view(d.buffer)
    ..setUint32(0, off, Endian.little)
    ..setUint16(4, len, Endian.little);
  return BP2Frame(cmd: 0xF3, data: d);
}

BP2Frame readFileEnd()      => BP2Frame(cmd: 0xF4);

List<double> decodeEcg(List<int> b) => [for (var i = 0; i+1 < b.length; i+=2)
  (b[i] | (b[i+1] << 8)).toSigned(16) * 0.003098];

// legacy BP helper
BP2Frame readFile(int id, int off) =>
    BP2Frame(cmd: 0xF2, data: [id, off & 0xFF, off >> 8]);