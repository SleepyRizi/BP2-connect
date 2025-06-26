// ────────────────────────────────────────────────────────────────────────────
// EcgDetailPage — v1.2   (duration fix + diagnosis list)
// ────────────────────────────────────────────────────────────────────────────
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/ecg_record.dart';

class EcgDetailPage extends StatelessWidget {
  const EcgDetailPage({super.key, required this.record});
  final EcgRecord record;

  /* simple bit-mask → text decoder
     (adjust if your firmware uses different flags) */
  List<String> _diagnosisList(int mask) {
    // special full-word values  ──────────────────────────────

    if (mask == 0xFFFFFFFF) {
      return const ['Poor waveform quality · unable to analyse'];
    }
    if (mask == 0xFFFFFFFE) {
      return const ['Lead off / <30 s · unable to analyse'];
    }
    if (mask == 0x00000000) {
      return const ['Regular ECG'];
    }

    // per-bit flags  ─────────────────────────────────────────
    const names = <int, String>{
      0x00000001: 'HR > 100 bpm',
      0x00000002: 'HR < 50 bpm',
      0x00000004: 'RR irregular',
      0x00000008: 'PVC',
      0x00000010: 'Cardiac arrest',
      0x00000020: 'Atrial fibrillation',
      0x00000040: 'QRS > 120 ms',
      0x00000080: 'QTc > 450 ms',
      0x00000100: 'QTc < 300 ms',
    };

    final list = <String>[
      for (final e in names.entries)
        if (mask & e.key != 0) e.value,
    ];

    // show unknown bits, if any, so nothing is hidden
    final unknown = mask & ~names.keys.reduce((a, b) => a | b);
    if (unknown != 0) list.add('0x${unknown.toRadixString(16).padLeft(8, '0')}');

    return list;
  }

  @override
  Widget build(BuildContext context) {
    /* ───── decode waveform (raw i16 LE @ 125 Hz) ───── */
    final bd      = record.wave.buffer.asByteData();
    const sps     = 125.0;
    final samples = record.wave.lengthInBytes >> 1;

    final spots = <FlSpot>[
      for (int i = 0; i < samples; ++i)
        FlSpot(i / sps, bd.getInt16(i * 2, Endian.little) / 1000.0),
    ];

    // nice Y-limits
    final minY = spots.map((e) => e.y).reduce(math.min);
    final maxY = spots.map((e) => e.y).reduce(math.max);

    /* ───── build page ───── */
    final diag = _diagnosisList(record.diagnosisBits);

    return Scaffold(
      appBar: AppBar(title: const Text('ECG Detail')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── metadata ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodyMedium,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start:     ${record.start}'),
                  Text('Duration:  ${record.duration} s'),
                  Text('Heart Rate: ${record.hr} bpm'),
                  if (record.qrs  != 0) Text('QRS:       ${record.qrs} ms'),
                  if (record.qtc  != 0) Text('QTc:       ${record.qtc} ms'),
                  if (record.pvcs != 0) Text('PVCs:      ${record.pvcs}'),
                  const SizedBox(height: 4),
                  Text(diag.join(' · ')),
                ],
              ),
            ),
          ),
          const Divider(height: 0),

          // ── waveform ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: record.duration.toDouble(),
                  minY: minY - 0.3,
                  maxY: maxY + 0.3,
                  titlesData: const FlTitlesData(show: false),
                  gridData  : const FlGridData(show: false),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      barWidth: 1.2,
                      dotData : const FlDotData(show: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
