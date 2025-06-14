//bp_record.g.dart

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bp_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class BpRecordAdapter extends TypeAdapter<BpRecord> {
  @override
  final int typeId = 2;

  @override
  BpRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BpRecord(
      systolic: fields[0] as int,
      diastolic: fields[1] as int,
      mean: fields[2] as int,
      pulse: fields[3] as int,
      time: fields[4] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, BpRecord obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.systolic)
      ..writeByte(1)
      ..write(obj.diastolic)
      ..writeByte(2)
      ..write(obj.mean)
      ..writeByte(3)
      ..write(obj.pulse)
      ..writeByte(4)
      ..write(obj.time);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BpRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
