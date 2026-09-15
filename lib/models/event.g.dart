// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'event.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Event _$EventFromJson(Map<String, dynamic> json) => Event(
  id: json['id'] as String?,
  title: json['title'] as String,
  description: json['description'] as String?,
  start: DateTime.parse(json['start'] as String),
  end: DateTime.parse(json['end'] as String),
  venueId: json['venueId'] as String?,
  performers:
      (json['performers'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
  createdBy: json['createdBy'] as String?,
  created: json['created'] == null
      ? null
      : DateTime.parse(json['created'] as String),
  venueName: json['venueName'] as String?,
  performerNames:
      (json['performerNames'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const [],
);

Map<String, dynamic> _$EventToJson(Event instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'description': instance.description,
  'start': instance.start.toIso8601String(),
  'end': instance.end.toIso8601String(),
  'venueId': instance.venueId,
  'performers': instance.performers,
  'createdBy': instance.createdBy,
  'created': instance.created.toIso8601String(),
  'venueName': instance.venueName,
  'performerNames': instance.performerNames,
};
