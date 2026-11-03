// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $EventRowsTable extends EventRows
    with TableInfo<$EventRowsTable, EventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _calendarIdMeta = const VerificationMeta(
    'calendarId',
  );
  @override
  late final GeneratedColumn<String> calendarId = GeneratedColumn<String>(
    'calendar_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _locationMeta = const VerificationMeta(
    'location',
  );
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
    'location',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _startWallMeta = const VerificationMeta(
    'startWall',
  );
  @override
  late final GeneratedColumn<String> startWall = GeneratedColumn<String>(
    'start_wall',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endWallMeta = const VerificationMeta(
    'endWall',
  );
  @override
  late final GeneratedColumn<String> endWall = GeneratedColumn<String>(
    'end_wall',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tzidMeta = const VerificationMeta('tzid');
  @override
  late final GeneratedColumn<String> tzid = GeneratedColumn<String>(
    'tzid',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _allDayMeta = const VerificationMeta('allDay');
  @override
  late final GeneratedColumn<bool> allDay = GeneratedColumn<bool>(
    'all_day',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("all_day" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _rruleMeta = const VerificationMeta('rrule');
  @override
  late final GeneratedColumn<String> rrule = GeneratedColumn<String>(
    'rrule',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _exdatesMeta = const VerificationMeta(
    'exdates',
  );
  @override
  late final GeneratedColumn<String> exdates = GeneratedColumn<String>(
    'exdates',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _recurringEventIdMeta = const VerificationMeta(
    'recurringEventId',
  );
  @override
  late final GeneratedColumn<String> recurringEventId = GeneratedColumn<String>(
    'recurring_event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _originalStartMeta = const VerificationMeta(
    'originalStart',
  );
  @override
  late final GeneratedColumn<String> originalStart = GeneratedColumn<String>(
    'original_start',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cancelledMeta = const VerificationMeta(
    'cancelled',
  );
  @override
  late final GeneratedColumn<bool> cancelled = GeneratedColumn<bool>(
    'cancelled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("cancelled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _googleIdMeta = const VerificationMeta(
    'googleId',
  );
  @override
  late final GeneratedColumn<String> googleId = GeneratedColumn<String>(
    'google_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _iCalUidMeta = const VerificationMeta(
    'iCalUid',
  );
  @override
  late final GeneratedColumn<String> iCalUid = GeneratedColumn<String>(
    'i_cal_uid',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    calendarId,
    title,
    notes,
    location,
    startWall,
    endWall,
    tzid,
    allDay,
    rrule,
    exdates,
    recurringEventId,
    originalStart,
    cancelled,
    version,
    googleId,
    etag,
    iCalUid,
    deleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'event_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<EventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('calendar_id')) {
      context.handle(
        _calendarIdMeta,
        calendarId.isAcceptableOrUnknown(data['calendar_id']!, _calendarIdMeta),
      );
    } else if (isInserting) {
      context.missing(_calendarIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('location')) {
      context.handle(
        _locationMeta,
        location.isAcceptableOrUnknown(data['location']!, _locationMeta),
      );
    }
    if (data.containsKey('start_wall')) {
      context.handle(
        _startWallMeta,
        startWall.isAcceptableOrUnknown(data['start_wall']!, _startWallMeta),
      );
    } else if (isInserting) {
      context.missing(_startWallMeta);
    }
    if (data.containsKey('end_wall')) {
      context.handle(
        _endWallMeta,
        endWall.isAcceptableOrUnknown(data['end_wall']!, _endWallMeta),
      );
    } else if (isInserting) {
      context.missing(_endWallMeta);
    }
    if (data.containsKey('tzid')) {
      context.handle(
        _tzidMeta,
        tzid.isAcceptableOrUnknown(data['tzid']!, _tzidMeta),
      );
    }
    if (data.containsKey('all_day')) {
      context.handle(
        _allDayMeta,
        allDay.isAcceptableOrUnknown(data['all_day']!, _allDayMeta),
      );
    }
    if (data.containsKey('rrule')) {
      context.handle(
        _rruleMeta,
        rrule.isAcceptableOrUnknown(data['rrule']!, _rruleMeta),
      );
    }
    if (data.containsKey('exdates')) {
      context.handle(
        _exdatesMeta,
        exdates.isAcceptableOrUnknown(data['exdates']!, _exdatesMeta),
      );
    }
    if (data.containsKey('recurring_event_id')) {
      context.handle(
        _recurringEventIdMeta,
        recurringEventId.isAcceptableOrUnknown(
          data['recurring_event_id']!,
          _recurringEventIdMeta,
        ),
      );
    }
    if (data.containsKey('original_start')) {
      context.handle(
        _originalStartMeta,
        originalStart.isAcceptableOrUnknown(
          data['original_start']!,
          _originalStartMeta,
        ),
      );
    }
    if (data.containsKey('cancelled')) {
      context.handle(
        _cancelledMeta,
        cancelled.isAcceptableOrUnknown(data['cancelled']!, _cancelledMeta),
      );
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('google_id')) {
      context.handle(
        _googleIdMeta,
        googleId.isAcceptableOrUnknown(data['google_id']!, _googleIdMeta),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('i_cal_uid')) {
      context.handle(
        _iCalUidMeta,
        iCalUid.isAcceptableOrUnknown(data['i_cal_uid']!, _iCalUidMeta),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EventRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      calendarId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}calendar_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      location: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location'],
      )!,
      startWall: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start_wall'],
      )!,
      endWall: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_wall'],
      )!,
      tzid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tzid'],
      ),
      allDay: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}all_day'],
      )!,
      rrule: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rrule'],
      ),
      exdates: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exdates'],
      )!,
      recurringEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recurring_event_id'],
      ),
      originalStart: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_start'],
      ),
      cancelled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}cancelled'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      googleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}google_id'],
      ),
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      iCalUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}i_cal_uid'],
      ),
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
    );
  }

  @override
  $EventRowsTable createAlias(String alias) {
    return $EventRowsTable(attachedDatabase, alias);
  }
}

class EventRow extends DataClass implements Insertable<EventRow> {
  final String id;
  final String calendarId;
  final String title;
  final String notes;
  final String location;
  final String startWall;
  final String endWall;
  final String? tzid;
  final bool allDay;
  final String? rrule;
  final String exdates;
  final String? recurringEventId;
  final String? originalStart;
  final bool cancelled;
  final int version;
  final String? googleId;
  final String? etag;
  final String? iCalUid;
  final bool deleted;
  const EventRow({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.notes,
    required this.location,
    required this.startWall,
    required this.endWall,
    this.tzid,
    required this.allDay,
    this.rrule,
    required this.exdates,
    this.recurringEventId,
    this.originalStart,
    required this.cancelled,
    required this.version,
    this.googleId,
    this.etag,
    this.iCalUid,
    required this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['calendar_id'] = Variable<String>(calendarId);
    map['title'] = Variable<String>(title);
    map['notes'] = Variable<String>(notes);
    map['location'] = Variable<String>(location);
    map['start_wall'] = Variable<String>(startWall);
    map['end_wall'] = Variable<String>(endWall);
    if (!nullToAbsent || tzid != null) {
      map['tzid'] = Variable<String>(tzid);
    }
    map['all_day'] = Variable<bool>(allDay);
    if (!nullToAbsent || rrule != null) {
      map['rrule'] = Variable<String>(rrule);
    }
    map['exdates'] = Variable<String>(exdates);
    if (!nullToAbsent || recurringEventId != null) {
      map['recurring_event_id'] = Variable<String>(recurringEventId);
    }
    if (!nullToAbsent || originalStart != null) {
      map['original_start'] = Variable<String>(originalStart);
    }
    map['cancelled'] = Variable<bool>(cancelled);
    map['version'] = Variable<int>(version);
    if (!nullToAbsent || googleId != null) {
      map['google_id'] = Variable<String>(googleId);
    }
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    if (!nullToAbsent || iCalUid != null) {
      map['i_cal_uid'] = Variable<String>(iCalUid);
    }
    map['deleted'] = Variable<bool>(deleted);
    return map;
  }

  EventRowsCompanion toCompanion(bool nullToAbsent) {
    return EventRowsCompanion(
      id: Value(id),
      calendarId: Value(calendarId),
      title: Value(title),
      notes: Value(notes),
      location: Value(location),
      startWall: Value(startWall),
      endWall: Value(endWall),
      tzid: tzid == null && nullToAbsent ? const Value.absent() : Value(tzid),
      allDay: Value(allDay),
      rrule: rrule == null && nullToAbsent
          ? const Value.absent()
          : Value(rrule),
      exdates: Value(exdates),
      recurringEventId: recurringEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(recurringEventId),
      originalStart: originalStart == null && nullToAbsent
          ? const Value.absent()
          : Value(originalStart),
      cancelled: Value(cancelled),
      version: Value(version),
      googleId: googleId == null && nullToAbsent
          ? const Value.absent()
          : Value(googleId),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      iCalUid: iCalUid == null && nullToAbsent
          ? const Value.absent()
          : Value(iCalUid),
      deleted: Value(deleted),
    );
  }

  factory EventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventRow(
      id: serializer.fromJson<String>(json['id']),
      calendarId: serializer.fromJson<String>(json['calendarId']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String>(json['notes']),
      location: serializer.fromJson<String>(json['location']),
      startWall: serializer.fromJson<String>(json['startWall']),
      endWall: serializer.fromJson<String>(json['endWall']),
      tzid: serializer.fromJson<String?>(json['tzid']),
      allDay: serializer.fromJson<bool>(json['allDay']),
      rrule: serializer.fromJson<String?>(json['rrule']),
      exdates: serializer.fromJson<String>(json['exdates']),
      recurringEventId: serializer.fromJson<String?>(json['recurringEventId']),
      originalStart: serializer.fromJson<String?>(json['originalStart']),
      cancelled: serializer.fromJson<bool>(json['cancelled']),
      version: serializer.fromJson<int>(json['version']),
      googleId: serializer.fromJson<String?>(json['googleId']),
      etag: serializer.fromJson<String?>(json['etag']),
      iCalUid: serializer.fromJson<String?>(json['iCalUid']),
      deleted: serializer.fromJson<bool>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'calendarId': serializer.toJson<String>(calendarId),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String>(notes),
      'location': serializer.toJson<String>(location),
      'startWall': serializer.toJson<String>(startWall),
      'endWall': serializer.toJson<String>(endWall),
      'tzid': serializer.toJson<String?>(tzid),
      'allDay': serializer.toJson<bool>(allDay),
      'rrule': serializer.toJson<String?>(rrule),
      'exdates': serializer.toJson<String>(exdates),
      'recurringEventId': serializer.toJson<String?>(recurringEventId),
      'originalStart': serializer.toJson<String?>(originalStart),
      'cancelled': serializer.toJson<bool>(cancelled),
      'version': serializer.toJson<int>(version),
      'googleId': serializer.toJson<String?>(googleId),
      'etag': serializer.toJson<String?>(etag),
      'iCalUid': serializer.toJson<String?>(iCalUid),
      'deleted': serializer.toJson<bool>(deleted),
    };
  }

  EventRow copyWith({
    String? id,
    String? calendarId,
    String? title,
    String? notes,
    String? location,
    String? startWall,
    String? endWall,
    Value<String?> tzid = const Value.absent(),
    bool? allDay,
    Value<String?> rrule = const Value.absent(),
    String? exdates,
    Value<String?> recurringEventId = const Value.absent(),
    Value<String?> originalStart = const Value.absent(),
    bool? cancelled,
    int? version,
    Value<String?> googleId = const Value.absent(),
    Value<String?> etag = const Value.absent(),
    Value<String?> iCalUid = const Value.absent(),
    bool? deleted,
  }) => EventRow(
    id: id ?? this.id,
    calendarId: calendarId ?? this.calendarId,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    location: location ?? this.location,
    startWall: startWall ?? this.startWall,
    endWall: endWall ?? this.endWall,
    tzid: tzid.present ? tzid.value : this.tzid,
    allDay: allDay ?? this.allDay,
    rrule: rrule.present ? rrule.value : this.rrule,
    exdates: exdates ?? this.exdates,
    recurringEventId: recurringEventId.present
        ? recurringEventId.value
        : this.recurringEventId,
    originalStart: originalStart.present
        ? originalStart.value
        : this.originalStart,
    cancelled: cancelled ?? this.cancelled,
    version: version ?? this.version,
    googleId: googleId.present ? googleId.value : this.googleId,
    etag: etag.present ? etag.value : this.etag,
    iCalUid: iCalUid.present ? iCalUid.value : this.iCalUid,
    deleted: deleted ?? this.deleted,
  );
  EventRow copyWithCompanion(EventRowsCompanion data) {
    return EventRow(
      id: data.id.present ? data.id.value : this.id,
      calendarId: data.calendarId.present
          ? data.calendarId.value
          : this.calendarId,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      location: data.location.present ? data.location.value : this.location,
      startWall: data.startWall.present ? data.startWall.value : this.startWall,
      endWall: data.endWall.present ? data.endWall.value : this.endWall,
      tzid: data.tzid.present ? data.tzid.value : this.tzid,
      allDay: data.allDay.present ? data.allDay.value : this.allDay,
      rrule: data.rrule.present ? data.rrule.value : this.rrule,
      exdates: data.exdates.present ? data.exdates.value : this.exdates,
      recurringEventId: data.recurringEventId.present
          ? data.recurringEventId.value
          : this.recurringEventId,
      originalStart: data.originalStart.present
          ? data.originalStart.value
          : this.originalStart,
      cancelled: data.cancelled.present ? data.cancelled.value : this.cancelled,
      version: data.version.present ? data.version.value : this.version,
      googleId: data.googleId.present ? data.googleId.value : this.googleId,
      etag: data.etag.present ? data.etag.value : this.etag,
      iCalUid: data.iCalUid.present ? data.iCalUid.value : this.iCalUid,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventRow(')
          ..write('id: $id, ')
          ..write('calendarId: $calendarId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('location: $location, ')
          ..write('startWall: $startWall, ')
          ..write('endWall: $endWall, ')
          ..write('tzid: $tzid, ')
          ..write('allDay: $allDay, ')
          ..write('rrule: $rrule, ')
          ..write('exdates: $exdates, ')
          ..write('recurringEventId: $recurringEventId, ')
          ..write('originalStart: $originalStart, ')
          ..write('cancelled: $cancelled, ')
          ..write('version: $version, ')
          ..write('googleId: $googleId, ')
          ..write('etag: $etag, ')
          ..write('iCalUid: $iCalUid, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    calendarId,
    title,
    notes,
    location,
    startWall,
    endWall,
    tzid,
    allDay,
    rrule,
    exdates,
    recurringEventId,
    originalStart,
    cancelled,
    version,
    googleId,
    etag,
    iCalUid,
    deleted,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventRow &&
          other.id == this.id &&
          other.calendarId == this.calendarId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.location == this.location &&
          other.startWall == this.startWall &&
          other.endWall == this.endWall &&
          other.tzid == this.tzid &&
          other.allDay == this.allDay &&
          other.rrule == this.rrule &&
          other.exdates == this.exdates &&
          other.recurringEventId == this.recurringEventId &&
          other.originalStart == this.originalStart &&
          other.cancelled == this.cancelled &&
          other.version == this.version &&
          other.googleId == this.googleId &&
          other.etag == this.etag &&
          other.iCalUid == this.iCalUid &&
          other.deleted == this.deleted);
}

class EventRowsCompanion extends UpdateCompanion<EventRow> {
  final Value<String> id;
  final Value<String> calendarId;
  final Value<String> title;
  final Value<String> notes;
  final Value<String> location;
  final Value<String> startWall;
  final Value<String> endWall;
  final Value<String?> tzid;
  final Value<bool> allDay;
  final Value<String?> rrule;
  final Value<String> exdates;
  final Value<String?> recurringEventId;
  final Value<String?> originalStart;
  final Value<bool> cancelled;
  final Value<int> version;
  final Value<String?> googleId;
  final Value<String?> etag;
  final Value<String?> iCalUid;
  final Value<bool> deleted;
  final Value<int> rowid;
  const EventRowsCompanion({
    this.id = const Value.absent(),
    this.calendarId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.location = const Value.absent(),
    this.startWall = const Value.absent(),
    this.endWall = const Value.absent(),
    this.tzid = const Value.absent(),
    this.allDay = const Value.absent(),
    this.rrule = const Value.absent(),
    this.exdates = const Value.absent(),
    this.recurringEventId = const Value.absent(),
    this.originalStart = const Value.absent(),
    this.cancelled = const Value.absent(),
    this.version = const Value.absent(),
    this.googleId = const Value.absent(),
    this.etag = const Value.absent(),
    this.iCalUid = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventRowsCompanion.insert({
    required String id,
    required String calendarId,
    required String title,
    this.notes = const Value.absent(),
    this.location = const Value.absent(),
    required String startWall,
    required String endWall,
    this.tzid = const Value.absent(),
    this.allDay = const Value.absent(),
    this.rrule = const Value.absent(),
    this.exdates = const Value.absent(),
    this.recurringEventId = const Value.absent(),
    this.originalStart = const Value.absent(),
    this.cancelled = const Value.absent(),
    this.version = const Value.absent(),
    this.googleId = const Value.absent(),
    this.etag = const Value.absent(),
    this.iCalUid = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       calendarId = Value(calendarId),
       title = Value(title),
       startWall = Value(startWall),
       endWall = Value(endWall);
  static Insertable<EventRow> custom({
    Expression<String>? id,
    Expression<String>? calendarId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? location,
    Expression<String>? startWall,
    Expression<String>? endWall,
    Expression<String>? tzid,
    Expression<bool>? allDay,
    Expression<String>? rrule,
    Expression<String>? exdates,
    Expression<String>? recurringEventId,
    Expression<String>? originalStart,
    Expression<bool>? cancelled,
    Expression<int>? version,
    Expression<String>? googleId,
    Expression<String>? etag,
    Expression<String>? iCalUid,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (calendarId != null) 'calendar_id': calendarId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (location != null) 'location': location,
      if (startWall != null) 'start_wall': startWall,
      if (endWall != null) 'end_wall': endWall,
      if (tzid != null) 'tzid': tzid,
      if (allDay != null) 'all_day': allDay,
      if (rrule != null) 'rrule': rrule,
      if (exdates != null) 'exdates': exdates,
      if (recurringEventId != null) 'recurring_event_id': recurringEventId,
      if (originalStart != null) 'original_start': originalStart,
      if (cancelled != null) 'cancelled': cancelled,
      if (version != null) 'version': version,
      if (googleId != null) 'google_id': googleId,
      if (etag != null) 'etag': etag,
      if (iCalUid != null) 'i_cal_uid': iCalUid,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventRowsCompanion copyWith({
    Value<String>? id,
    Value<String>? calendarId,
    Value<String>? title,
    Value<String>? notes,
    Value<String>? location,
    Value<String>? startWall,
    Value<String>? endWall,
    Value<String?>? tzid,
    Value<bool>? allDay,
    Value<String?>? rrule,
    Value<String>? exdates,
    Value<String?>? recurringEventId,
    Value<String?>? originalStart,
    Value<bool>? cancelled,
    Value<int>? version,
    Value<String?>? googleId,
    Value<String?>? etag,
    Value<String?>? iCalUid,
    Value<bool>? deleted,
    Value<int>? rowid,
  }) {
    return EventRowsCompanion(
      id: id ?? this.id,
      calendarId: calendarId ?? this.calendarId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      location: location ?? this.location,
      startWall: startWall ?? this.startWall,
      endWall: endWall ?? this.endWall,
      tzid: tzid ?? this.tzid,
      allDay: allDay ?? this.allDay,
      rrule: rrule ?? this.rrule,
      exdates: exdates ?? this.exdates,
      recurringEventId: recurringEventId ?? this.recurringEventId,
      originalStart: originalStart ?? this.originalStart,
      cancelled: cancelled ?? this.cancelled,
      version: version ?? this.version,
      googleId: googleId ?? this.googleId,
      etag: etag ?? this.etag,
      iCalUid: iCalUid ?? this.iCalUid,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (calendarId.present) {
      map['calendar_id'] = Variable<String>(calendarId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (startWall.present) {
      map['start_wall'] = Variable<String>(startWall.value);
    }
    if (endWall.present) {
      map['end_wall'] = Variable<String>(endWall.value);
    }
    if (tzid.present) {
      map['tzid'] = Variable<String>(tzid.value);
    }
    if (allDay.present) {
      map['all_day'] = Variable<bool>(allDay.value);
    }
    if (rrule.present) {
      map['rrule'] = Variable<String>(rrule.value);
    }
    if (exdates.present) {
      map['exdates'] = Variable<String>(exdates.value);
    }
    if (recurringEventId.present) {
      map['recurring_event_id'] = Variable<String>(recurringEventId.value);
    }
    if (originalStart.present) {
      map['original_start'] = Variable<String>(originalStart.value);
    }
    if (cancelled.present) {
      map['cancelled'] = Variable<bool>(cancelled.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (googleId.present) {
      map['google_id'] = Variable<String>(googleId.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (iCalUid.present) {
      map['i_cal_uid'] = Variable<String>(iCalUid.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventRowsCompanion(')
          ..write('id: $id, ')
          ..write('calendarId: $calendarId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('location: $location, ')
          ..write('startWall: $startWall, ')
          ..write('endWall: $endWall, ')
          ..write('tzid: $tzid, ')
          ..write('allDay: $allDay, ')
          ..write('rrule: $rrule, ')
          ..write('exdates: $exdates, ')
          ..write('recurringEventId: $recurringEventId, ')
          ..write('originalStart: $originalStart, ')
          ..write('cancelled: $cancelled, ')
          ..write('version: $version, ')
          ..write('googleId: $googleId, ')
          ..write('etag: $etag, ')
          ..write('iCalUid: $iCalUid, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxRowsTable extends OutboxRows
    with TableInfo<$OutboxRowsTable, OutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [seq, eventId, op, attempts, lastError];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<OutboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {seq};
  @override
  OutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxRow(
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      op: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $OutboxRowsTable createAlias(String alias) {
    return $OutboxRowsTable(attachedDatabase, alias);
  }
}

class OutboxRow extends DataClass implements Insertable<OutboxRow> {
  final int seq;
  final String eventId;
  final String op;
  final int attempts;
  final String? lastError;
  const OutboxRow({
    required this.seq,
    required this.eventId,
    required this.op,
    required this.attempts,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['seq'] = Variable<int>(seq);
    map['event_id'] = Variable<String>(eventId);
    map['op'] = Variable<String>(op);
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  OutboxRowsCompanion toCompanion(bool nullToAbsent) {
    return OutboxRowsCompanion(
      seq: Value(seq),
      eventId: Value(eventId),
      op: Value(op),
      attempts: Value(attempts),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
    );
  }

  factory OutboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxRow(
      seq: serializer.fromJson<int>(json['seq']),
      eventId: serializer.fromJson<String>(json['eventId']),
      op: serializer.fromJson<String>(json['op']),
      attempts: serializer.fromJson<int>(json['attempts']),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'seq': serializer.toJson<int>(seq),
      'eventId': serializer.toJson<String>(eventId),
      'op': serializer.toJson<String>(op),
      'attempts': serializer.toJson<int>(attempts),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  OutboxRow copyWith({
    int? seq,
    String? eventId,
    String? op,
    int? attempts,
    Value<String?> lastError = const Value.absent(),
  }) => OutboxRow(
    seq: seq ?? this.seq,
    eventId: eventId ?? this.eventId,
    op: op ?? this.op,
    attempts: attempts ?? this.attempts,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  OutboxRow copyWithCompanion(OutboxRowsCompanion data) {
    return OutboxRow(
      seq: data.seq.present ? data.seq.value : this.seq,
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      op: data.op.present ? data.op.value : this.op,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxRow(')
          ..write('seq: $seq, ')
          ..write('eventId: $eventId, ')
          ..write('op: $op, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(seq, eventId, op, attempts, lastError);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxRow &&
          other.seq == this.seq &&
          other.eventId == this.eventId &&
          other.op == this.op &&
          other.attempts == this.attempts &&
          other.lastError == this.lastError);
}

class OutboxRowsCompanion extends UpdateCompanion<OutboxRow> {
  final Value<int> seq;
  final Value<String> eventId;
  final Value<String> op;
  final Value<int> attempts;
  final Value<String?> lastError;
  const OutboxRowsCompanion({
    this.seq = const Value.absent(),
    this.eventId = const Value.absent(),
    this.op = const Value.absent(),
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
  });
  OutboxRowsCompanion.insert({
    this.seq = const Value.absent(),
    required String eventId,
    required String op,
    this.attempts = const Value.absent(),
    this.lastError = const Value.absent(),
  }) : eventId = Value(eventId),
       op = Value(op);
  static Insertable<OutboxRow> custom({
    Expression<int>? seq,
    Expression<String>? eventId,
    Expression<String>? op,
    Expression<int>? attempts,
    Expression<String>? lastError,
  }) {
    return RawValuesInsertable({
      if (seq != null) 'seq': seq,
      if (eventId != null) 'event_id': eventId,
      if (op != null) 'op': op,
      if (attempts != null) 'attempts': attempts,
      if (lastError != null) 'last_error': lastError,
    });
  }

  OutboxRowsCompanion copyWith({
    Value<int>? seq,
    Value<String>? eventId,
    Value<String>? op,
    Value<int>? attempts,
    Value<String?>? lastError,
  }) {
    return OutboxRowsCompanion(
      seq: seq ?? this.seq,
      eventId: eventId ?? this.eventId,
      op: op ?? this.op,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxRowsCompanion(')
          ..write('seq: $seq, ')
          ..write('eventId: $eventId, ')
          ..write('op: $op, ')
          ..write('attempts: $attempts, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }
}

class $MetaRowsTable extends MetaRows with TableInfo<$MetaRowsTable, MetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'meta_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<MetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $MetaRowsTable createAlias(String alias) {
    return $MetaRowsTable(attachedDatabase, alias);
  }
}

class MetaRow extends DataClass implements Insertable<MetaRow> {
  final String key;
  final String value;
  const MetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MetaRowsCompanion toCompanion(bool nullToAbsent) {
    return MetaRowsCompanion(key: Value(key), value: Value(value));
  }

  factory MetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  MetaRow copyWith({String? key, String? value}) =>
      MetaRow(key: key ?? this.key, value: value ?? this.value);
  MetaRow copyWithCompanion(MetaRowsCompanion data) {
    return MetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MetaRow && other.key == this.key && other.value == this.value);
}

class MetaRowsCompanion extends UpdateCompanion<MetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MetaRowsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaRowsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<MetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetaRowsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MetaRowsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetaRowsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $EventRowsTable eventRows = $EventRowsTable(this);
  late final $OutboxRowsTable outboxRows = $OutboxRowsTable(this);
  late final $MetaRowsTable metaRows = $MetaRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    eventRows,
    outboxRows,
    metaRows,
  ];
}

typedef $$EventRowsTableCreateCompanionBuilder = EventRowsCompanion Function({
  required String id,
  required String calendarId,
  required String title,
  Value<String> notes,
  Value<String> location,
  required String startWall,
  required String endWall,
  Value<String?> tzid,
  Value<bool> allDay,
  Value<String?> rrule,
  Value<String> exdates,
  Value<String?> recurringEventId,
  Value<String?> originalStart,
  Value<bool> cancelled,
  Value<int> version,
  Value<String?> googleId,
  Value<String?> etag,
  Value<String?> iCalUid,
  Value<bool> deleted,
  Value<int> rowid,
});
typedef $$EventRowsTableUpdateCompanionBuilder = EventRowsCompanion Function({
  Value<String> id,
  Value<String> calendarId,
  Value<String> title,
  Value<String> notes,
  Value<String> location,
  Value<String> startWall,
  Value<String> endWall,
  Value<String?> tzid,
  Value<bool> allDay,
  Value<String?> rrule,
  Value<String> exdates,
  Value<String?> recurringEventId,
  Value<String?> originalStart,
  Value<bool> cancelled,
  Value<int> version,
  Value<String?> googleId,
  Value<String?> etag,
  Value<String?> iCalUid,
  Value<bool> deleted,
  Value<int> rowid,
});

class $$EventRowsTableFilterComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get calendarId => $composableBuilder(
    column: $table.calendarId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get startWall => $composableBuilder(
    column: $table.startWall,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get endWall => $composableBuilder(
    column: $table.endWall,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tzid => $composableBuilder(
    column: $table.tzid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rrule => $composableBuilder(
    column: $table.rrule,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get exdates => $composableBuilder(
    column: $table.exdates,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recurringEventId => $composableBuilder(
    column: $table.recurringEventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalStart => $composableBuilder(
    column: $table.originalStart,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get cancelled => $composableBuilder(
    column: $table.cancelled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get googleId => $composableBuilder(
    column: $table.googleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get iCalUid => $composableBuilder(
    column: $table.iCalUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EventRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get calendarId => $composableBuilder(
    column: $table.calendarId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get startWall => $composableBuilder(
    column: $table.startWall,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get endWall => $composableBuilder(
    column: $table.endWall,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tzid => $composableBuilder(
    column: $table.tzid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rrule => $composableBuilder(
    column: $table.rrule,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get exdates => $composableBuilder(
    column: $table.exdates,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recurringEventId => $composableBuilder(
    column: $table.recurringEventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalStart => $composableBuilder(
    column: $table.originalStart,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get cancelled => $composableBuilder(
    column: $table.cancelled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get googleId => $composableBuilder(
    column: $table.googleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get iCalUid => $composableBuilder(
    column: $table.iCalUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EventRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $EventRowsTable> {
  $$EventRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get calendarId => $composableBuilder(
    column: $table.calendarId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get location =>
      $composableBuilder(column: $table.location, builder: (column) => column);

  GeneratedColumn<String> get startWall =>
      $composableBuilder(column: $table.startWall, builder: (column) => column);

  GeneratedColumn<String> get endWall =>
      $composableBuilder(column: $table.endWall, builder: (column) => column);

  GeneratedColumn<String> get tzid =>
      $composableBuilder(column: $table.tzid, builder: (column) => column);

  GeneratedColumn<bool> get allDay =>
      $composableBuilder(column: $table.allDay, builder: (column) => column);

  GeneratedColumn<String> get rrule =>
      $composableBuilder(column: $table.rrule, builder: (column) => column);

  GeneratedColumn<String> get exdates =>
      $composableBuilder(column: $table.exdates, builder: (column) => column);

  GeneratedColumn<String> get recurringEventId => $composableBuilder(
    column: $table.recurringEventId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get originalStart => $composableBuilder(
    column: $table.originalStart,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get cancelled =>
      $composableBuilder(column: $table.cancelled, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<String> get googleId =>
      $composableBuilder(column: $table.googleId, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<String> get iCalUid =>
      $composableBuilder(column: $table.iCalUid, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);
}

class $$EventRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $EventRowsTable,
          EventRow,
          $$EventRowsTableFilterComposer,
          $$EventRowsTableOrderingComposer,
          $$EventRowsTableAnnotationComposer,
          $$EventRowsTableCreateCompanionBuilder,
          $$EventRowsTableUpdateCompanionBuilder,
          (EventRow, BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>),
          EventRow,
          PrefetchHooks Function()
        > {
  $$EventRowsTableTableManager(_$AppDatabase db, $EventRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EventRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EventRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EventRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> calendarId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String> location = const Value.absent(),
                Value<String> startWall = const Value.absent(),
                Value<String> endWall = const Value.absent(),
                Value<String?> tzid = const Value.absent(),
                Value<bool> allDay = const Value.absent(),
                Value<String?> rrule = const Value.absent(),
                Value<String> exdates = const Value.absent(),
                Value<String?> recurringEventId = const Value.absent(),
                Value<String?> originalStart = const Value.absent(),
                Value<bool> cancelled = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<String?> googleId = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> iCalUid = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventRowsCompanion(
                id: id,
                calendarId: calendarId,
                title: title,
                notes: notes,
                location: location,
                startWall: startWall,
                endWall: endWall,
                tzid: tzid,
                allDay: allDay,
                rrule: rrule,
                exdates: exdates,
                recurringEventId: recurringEventId,
                originalStart: originalStart,
                cancelled: cancelled,
                version: version,
                googleId: googleId,
                etag: etag,
                iCalUid: iCalUid,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String calendarId,
                required String title,
                Value<String> notes = const Value.absent(),
                Value<String> location = const Value.absent(),
                required String startWall,
                required String endWall,
                Value<String?> tzid = const Value.absent(),
                Value<bool> allDay = const Value.absent(),
                Value<String?> rrule = const Value.absent(),
                Value<String> exdates = const Value.absent(),
                Value<String?> recurringEventId = const Value.absent(),
                Value<String?> originalStart = const Value.absent(),
                Value<bool> cancelled = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<String?> googleId = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> iCalUid = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EventRowsCompanion.insert(
                id: id,
                calendarId: calendarId,
                title: title,
                notes: notes,
                location: location,
                startWall: startWall,
                endWall: endWall,
                tzid: tzid,
                allDay: allDay,
                rrule: rrule,
                exdates: exdates,
                recurringEventId: recurringEventId,
                originalStart: originalStart,
                cancelled: cancelled,
                version: version,
                googleId: googleId,
                etag: etag,
                iCalUid: iCalUid,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EventRowsTable, EventRow>(table),
                  BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EventRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $EventRowsTable,
      EventRow,
      $$EventRowsTableFilterComposer,
      $$EventRowsTableOrderingComposer,
      $$EventRowsTableAnnotationComposer,
      $$EventRowsTableCreateCompanionBuilder,
      $$EventRowsTableUpdateCompanionBuilder,
      (EventRow, BaseReferences<_$AppDatabase, $EventRowsTable, EventRow>),
      EventRow,
      PrefetchHooks Function()
    >;
typedef $$OutboxRowsTableCreateCompanionBuilder = OutboxRowsCompanion Function({
  Value<int> seq,
  required String eventId,
  required String op,
  Value<int> attempts,
  Value<String?> lastError,
});
typedef $$OutboxRowsTableUpdateCompanionBuilder = OutboxRowsCompanion Function({
  Value<int> seq,
  Value<String> eventId,
  Value<String> op,
  Value<int> attempts,
  Value<String?> lastError,
});

class $$OutboxRowsTableFilterComposer
    extends Composer<_$AppDatabase, $OutboxRowsTable> {
  $$OutboxRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $OutboxRowsTable> {
  $$OutboxRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $OutboxRowsTable> {
  $$OutboxRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get eventId =>
      $composableBuilder(column: $table.eventId, builder: (column) => column);

  GeneratedColumn<String> get op =>
      $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);
}

class $$OutboxRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OutboxRowsTable,
          OutboxRow,
          $$OutboxRowsTableFilterComposer,
          $$OutboxRowsTableOrderingComposer,
          $$OutboxRowsTableAnnotationComposer,
          $$OutboxRowsTableCreateCompanionBuilder,
          $$OutboxRowsTableUpdateCompanionBuilder,
          (
            OutboxRow,
            BaseReferences<_$AppDatabase, $OutboxRowsTable, OutboxRow>,
          ),
          OutboxRow,
          PrefetchHooks Function()
        > {
  $$OutboxRowsTableTableManager(_$AppDatabase db, $OutboxRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> seq = const Value.absent(),
                Value<String> eventId = const Value.absent(),
                Value<String> op = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => OutboxRowsCompanion(
                seq: seq,
                eventId: eventId,
                op: op,
                attempts: attempts,
                lastError: lastError,
              ),
          createCompanionCallback:
              ({
                Value<int> seq = const Value.absent(),
                required String eventId,
                required String op,
                Value<int> attempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => OutboxRowsCompanion.insert(
                seq: seq,
                eventId: eventId,
                op: op,
                attempts: attempts,
                lastError: lastError,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OutboxRowsTable, OutboxRow>(table),
                  BaseReferences<_$AppDatabase, $OutboxRowsTable, OutboxRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OutboxRowsTable,
      OutboxRow,
      $$OutboxRowsTableFilterComposer,
      $$OutboxRowsTableOrderingComposer,
      $$OutboxRowsTableAnnotationComposer,
      $$OutboxRowsTableCreateCompanionBuilder,
      $$OutboxRowsTableUpdateCompanionBuilder,
      (OutboxRow, BaseReferences<_$AppDatabase, $OutboxRowsTable, OutboxRow>),
      OutboxRow,
      PrefetchHooks Function()
    >;
typedef $$MetaRowsTableCreateCompanionBuilder = MetaRowsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MetaRowsTableUpdateCompanionBuilder = MetaRowsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MetaRowsTableFilterComposer
    extends Composer<_$AppDatabase, $MetaRowsTable> {
  $$MetaRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MetaRowsTableOrderingComposer
    extends Composer<_$AppDatabase, $MetaRowsTable> {
  $$MetaRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MetaRowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MetaRowsTable> {
  $$MetaRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MetaRowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MetaRowsTable,
          MetaRow,
          $$MetaRowsTableFilterComposer,
          $$MetaRowsTableOrderingComposer,
          $$MetaRowsTableAnnotationComposer,
          $$MetaRowsTableCreateCompanionBuilder,
          $$MetaRowsTableUpdateCompanionBuilder,
          (MetaRow, BaseReferences<_$AppDatabase, $MetaRowsTable, MetaRow>),
          MetaRow,
          PrefetchHooks Function()
        > {
  $$MetaRowsTableTableManager(_$AppDatabase db, $MetaRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetaRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetaRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetaRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MetaRowsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MetaRowsCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MetaRowsTable, MetaRow>(table),
                  BaseReferences<_$AppDatabase, $MetaRowsTable, MetaRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetaRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MetaRowsTable,
      MetaRow,
      $$MetaRowsTableFilterComposer,
      $$MetaRowsTableOrderingComposer,
      $$MetaRowsTableAnnotationComposer,
      $$MetaRowsTableCreateCompanionBuilder,
      $$MetaRowsTableUpdateCompanionBuilder,
      (MetaRow, BaseReferences<_$AppDatabase, $MetaRowsTable, MetaRow>),
      MetaRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$EventRowsTableTableManager get eventRows =>
      $$EventRowsTableTableManager(_db, _db.eventRows);
  $$OutboxRowsTableTableManager get outboxRows =>
      $$OutboxRowsTableTableManager(_db, _db.outboxRows);
  $$MetaRowsTableTableManager get metaRows =>
      $$MetaRowsTableTableManager(_db, _db.metaRows);
}
