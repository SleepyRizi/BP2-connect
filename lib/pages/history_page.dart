/*──────────────────────────────────────────────────────────────────────────────
  history_page.dart – spark‑line + correct timestamp
──────────────────────────────────────────────────────────────────────────────*/
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import '../controllers/history_controller.dart';
import 'ecg_detail_page.dart';
import '../widgets/ecg_spark.dart';
import 'dart:typed_data';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Get.find<HistoryController>();
    final df = DateFormat('yyyy-MM-dd  HH:mm');

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Historical Records'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Blood-Pressure'),
              Tab(icon: Icon(Icons.favorite), text: 'ECG'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            //── BP list ──
            Obx(() => h.records.isEmpty
                ? const _EmptyHint(text: 'No BP data yet')
                : ListView.separated(
              itemCount: h.records.length,
              separatorBuilder: (_, __) => const Divider(height: 0),
              itemBuilder: (_, i) {
                final r = h.records[i];
                return ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined, color: Colors.blue),
                  title: Text('${r.systolic}/${r.diastolic} mmHg'),
                  subtitle: Text('${r.pulse} bpm   ·   ${df.format(r.time)}'),
                );
              },
            )),

            //── ECG list ──
            Obx(() => h.ecgs.isEmpty
                ? const _EmptyHint(text: 'No ECGs pulled from device')
                : ListView.separated(
              itemCount: h.ecgs.length,
              separatorBuilder: (_, __) => const Divider(height: 0),
              itemBuilder: (_, i) {
                final r = h.ecgs[i];
                final dur = r.duration;
                return ListTile(
                  leading: const Icon(Icons.favorite, color: Colors.red),
                  title: Text('HR ${r.hr} bpm   ·   $dur s'),
                  subtitle: Text(df.format(r.start)),
                  trailing: EcgSpark(wave: r.wave),
                  onTap: () => Get.to(() => EcgDetailPage(record: r)),
                );
              },
            )),
          ],
        ),
        floatingActionButton: Obx(() => FloatingActionButton.extended(
          onPressed: h.isPulling.value ? null : h.pullEcgPressed,
          icon: const Icon(Icons.download),
          label: Text(h.isPulling.value ? 'Pulling…' : 'Pull ECG'),
        )),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Card(
      elevation: 0,
      margin: const EdgeInsets.all(40),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey),
        ),
      ),
    ),
  );
}
