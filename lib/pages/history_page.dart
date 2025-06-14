//history page.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/history_controller.dart';
import 'package:intl/intl.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Get.find<HistoryController>();
    final df = DateFormat('yyyy-MM-dd HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Historical Records')),
      body: Obx(() => ListView.separated(
        itemCount: h.records.length,
        separatorBuilder: (_, __) => const Divider(height: 0),
        itemBuilder: (_, i) {
          final r = h.records[i];
          return ListTile(
            leading: const Icon(Icons.favorite),
            title:
            Text('${r.systolic}/${r.diastolic} mmHg  —  ${r.pulse} bpm'),
            subtitle: Text(df.format(r.time)),
          );
        },
      )),
    );
  }
}
