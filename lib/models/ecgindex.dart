/// A tiny POJO for the list view / history page.  Extend as you wish.
class EcgIndexEntry {
  EcgIndexEntry({
    required this.fileStem,
    required this.duration,
    required this.diagnosisBits,
    required this.hr,
    required this.qrs,
    required this.pvcs,
    required this.qtc,
  });

  final String  fileStem;                    // “yyyyMMddHHmmss”
  final int     duration;                    // seconds
  final int     diagnosisBits;               // 32-bit mask
  final int     hr;                          // bpm
  final int     qrs;                         // ms
  final int     pvcs;                        // count
  final int     qtc;                         // ms
}