import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class EcgSpark extends StatelessWidget {
  const EcgSpark({super.key, required this.wave});
  final Uint8List wave;

  @override
  Widget build(BuildContext context) {
    if (wave.lengthInBytes < 4) return const SizedBox();

    const sps = 125.0;                         // Hz
    final samples = wave.lengthInBytes >> 1;
    final skip    = math.max(1, (samples / 312).ceil());
    final bd      = wave.buffer.asByteData();

    final pts = <FlSpot>[
      for (int s = 0; s < samples; s += skip)
        FlSpot(s / sps, bd.getInt16(s * 2, Endian.little) / 1000.0),
    ];

    return SizedBox(
      width: 64, height: 12,
      child : LineChart(
        LineChartData(
          minY: -1.3, maxY: 1.3,
          titlesData: const FlTitlesData(show: false),
          gridData  : const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: pts,
              isCurved: false,
              barWidth: .8,
              dotData : const FlDotData(show: false),
            )
          ],
        ),
        // swapAnimationDuration: Duration.zero,
      ),
    );
  }
}
