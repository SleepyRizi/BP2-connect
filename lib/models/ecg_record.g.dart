// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ecg_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class EcgRecordAdapter extends TypeAdapter<EcgRecord> {
  @override
  final int typeId = 3;

  @override
  EcgRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return EcgRecord(
      start: fields[0] as DateTime,
      duration: fields[1] as int,
      hr: fields[2] as int,
      diagnosisBits: fields[3] as int,
      qrs: fields[4] as int,
      pvcs: fields[5] as int,
      qtc: fields[6] as int,
      wave: (fields[7] as List).cast<int>(),
    );
  }

  @override
  void write(BinaryWriter writer, EcgRecord obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.start)
      ..writeByte(1)
      ..write(obj.duration)
      ..writeByte(2)
      ..write(obj.hr)
      ..writeByte(3)
      ..write(obj.diagnosisBits)
      ..writeByte(4)
      ..write(obj.qrs)
      ..writeByte(5)
      ..write(obj.pvcs)
      ..writeByte(6)
      ..write(obj.qtc)
      ..writeByte(7)
      ..write(obj.wave);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EcgRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
