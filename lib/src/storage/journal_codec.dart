import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../session/snapshot.dart';

const journalRecordLimit = 64 * 1024 * 1024;
const journalSnapshotInterval = 128;

class JournalScan {
  JournalScan(
    this.records,
    this.validBytes, {
    this.generation,
    this.lastRecordOffset = 0,
    this.checkpointRevision = 0,
    this.lastRecordCrc = 0,
  });
  final List<SessionSnapshot> records;
  final int validBytes;
  final String? generation;
  final int lastRecordOffset;
  final int checkpointRevision;
  final int lastRecordCrc;
  bool get legacy => records.isNotEmpty && generation == null;
}

String newJournalGeneration() {
  final random = Random.secure();
  return base64Url.encode(List.generate(18, (_) => random.nextInt(256)));
}

bool sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && sameJson(a[key], b[key]));
  }
  return a == b;
}

/// Lists retain their common prefix, then append/replace only the changed tail.
/// This handles messages, summaries, pending results, steering and truncation.
Map<String, Object?> journalRecord(
  Map<String, Object?>? previous,
  Map<String, Object?> next,
  String generation,
) {
  final revision = next['revision']! as int;
  if (previous == null) {
    return {
      'journalVersion': 2,
      'generation': generation,
      'kind': 'snapshot',
      'snapshot': next,
    };
  }
  final set = <String, Object?>{};
  final lists = <String, Object?>{};
  for (final entry in next.entries) {
    final old = previous[entry.key];
    final value = entry.value;
    if (previous.containsKey(entry.key) && sameJson(old, value)) continue;
    if (old is List && value is List) {
      var keep = 0;
      while (keep < old.length &&
          keep < value.length &&
          sameJson(old[keep], value[keep])) {
        keep++;
      }
      lists[entry.key] = {'keep': keep, 'append': value.sublist(keep)};
    } else {
      set[entry.key] = value;
    }
  }
  return {
    'journalVersion': 2,
    'generation': generation,
    'kind': 'delta',
    'id': next['id'],
    'revision': revision,
    'baseRevision': previous['revision'],
    'set': set,
    'lists': lists,
    'remove': previous.keys.where((key) => !next.containsKey(key)).toList(),
  };
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid journal object');
  }
  return value.cast<String, Object?>();
}

Map<String, Object?> replayRecord(
  Map<String, Object?>? previous,
  Map<String, Object?> record,
) {
  if (record['journalVersion'] == null) return record; // v1 read compatibility
  if (record['journalVersion'] != 2) {
    throw const FormatException('Unsupported journal format');
  }
  if (record['kind'] == 'snapshot') return _map(record['snapshot']);
  if (record['kind'] != 'delta' ||
      previous == null ||
      record['baseRevision'] != previous['revision'] ||
      record['id'] != previous['id']) {
    throw const FormatException('Invalid journal delta base');
  }
  final set = _map(record['set']);
  final lists = _map(record['lists']);
  final remove = record['remove'];
  if (remove is! List || remove.any((key) => key is! String)) {
    throw const FormatException('Invalid journal removed fields');
  }
  final next = <String, Object?>{...previous, ...set};
  for (final entry in lists.entries) {
    final old = previous[entry.key];
    final operation = _map(entry.value);
    final keep = operation['keep'];
    final append = operation['append'];
    if (set.containsKey(entry.key) ||
        old is! List ||
        keep is! int ||
        keep < 0 ||
        keep > old.length ||
        append is! List) {
      throw const FormatException('Invalid journal list delta');
    }
    next[entry.key] = [...old.take(keep), ...append];
  }
  for (final key in remove) {
    if (set.containsKey(key) || lists.containsKey(key)) {
      throw const FormatException('Conflicting journal delta');
    }
    next.remove(key);
  }
  if (next['revision'] != record['revision']) {
    throw const FormatException('Invalid journal delta revision');
  }
  return next;
}

Uint8List journalFrame(Map<String, Object?> record) {
  final payload = utf8.encode(jsonEncode(record));
  if (payload.length > journalRecordLimit) {
    throw ArgumentError('Checkpoint exceeds journal record limit');
  }
  final frame = Uint8List(12 + payload.length);
  final header = ByteData.sublistView(frame, 0, 12)
    ..setUint32(0, payload.length)
    ..setUint32(4, journalCrc(payload));
  header.setUint32(8, journalCrc(Uint8List.sublistView(frame, 0, 8)));
  frame.setRange(12, frame.length, payload);
  return frame;
}

({Map<String, Object?> record, int crc})? _readFrame(RandomAccessFile reader) {
  final bytes = reader.readSync(12);
  if (bytes.length < 12) return null; // torn final header
  final header = ByteData.sublistView(bytes);
  if (journalCrc(Uint8List.sublistView(bytes, 0, 8)) != header.getUint32(8)) {
    throw const FormatException('Journal header checksum mismatch');
  }
  final length = header.getUint32(0);
  if (length > journalRecordLimit) {
    throw const FormatException('Invalid journal record size');
  }
  final payload = reader.readSync(length);
  if (payload.length < length) return null; // torn final payload
  final crc = journalCrc(payload);
  if (crc != header.getUint32(4)) {
    throw const FormatException('Journal checksum mismatch');
  }
  return (record: _map(jsonDecode(utf8.decode(payload))), crc: crc);
}

/// The replaceable snapshot is a cache, anchored to a durable journal frame.
/// Generation, frame checksum, identity, revision and end offset must match.
Map<String, Object?>? _readCheckpoint(
  String path,
  String id,
  String generation,
) {
  try {
    final file = File('$path.checkpoint');
    if (!file.existsSync() || file.lengthSync() > journalRecordLimit + 12) {
      return null;
    }
    final reader = file.openSync();
    try {
      final cache = _readFrame(reader)?.record;
      if (cache?['generation'] != generation ||
          cache?['id'] != id ||
          cache?['offset'] is! int ||
          (cache!['offset']! as int) < 0 ||
          cache['end'] is! int ||
          cache['crc'] is! int) {
        return null;
      }
      return cache;
    } finally {
      reader.closeSync();
    }
  } catch (_) {
    return null;
  }
}

JournalScan scanJournal(
  String path,
  String id, {
  bool retainAll = false,
  bool useCheckpoint = true,
  void Function(Map<String, Object?> state)? onState,
}) {
  final file = File(path);
  if (!file.existsSync()) return JournalScan([], 0);
  final reader = file.openSync();
  final records = <SessionSnapshot>[];
  Map<String, Object?>? latest;
  String? generation;
  var revision = 0;
  var offset = 0;
  var lastRecordOffset = 0;
  var checkpointRevision = 0;
  var lastRecordCrc = 0;
  try {
    final first = _readFrame(reader);
    if (first == null) return JournalScan([], 0);
    if (first.record['journalVersion'] != null) {
      generation = first.record['generation'] as String?;
      final initial = replayRecord(null, first.record);
      if (generation == null ||
          generation.isEmpty ||
          initial['id'] != id ||
          initial['revision'] != 0) {
        throw const FormatException('Invalid journal initial snapshot');
      }
    }
    reader.setPositionSync(0);
    if (useCheckpoint && !retainAll && onState == null && generation != null) {
      final cache = _readCheckpoint(path, id, generation);
      if (cache != null) {
        try {
          final target = cache['offset']! as int;
          if (target >= reader.lengthSync()) throw const FormatException();
          reader.setPositionSync(target);
          final frame = _readFrame(reader);
          final state = _map(cache['state']);
          final anchor = frame?.record['kind'] == 'snapshot'
              ? _map(frame?.record['snapshot'])
              : frame?.record;
          if (frame?.record['generation'] != generation ||
              frame?.crc != cache['crc'] ||
              anchor?['id'] != id ||
              anchor?['revision'] != state['revision'] ||
              state['id'] != id ||
              state['revision'] is! int ||
              reader.positionSync() != cache['end']) {
            throw const FormatException('Stale journal checkpoint');
          }
          SessionSnapshot.fromJson(state); // reject malformed cached state
          latest = state;
          offset = reader.positionSync();
          lastRecordOffset = target;
          lastRecordCrc = frame!.crc;
          checkpointRevision = state['revision']! as int;
          revision = checkpointRevision + 1;
        } catch (_) {
          latest = null;
          offset = 0;
          revision = 0;
          lastRecordOffset = 0;
          lastRecordCrc = 0;
          checkpointRevision = 0;
        }
        reader.setPositionSync(offset);
      }
    }
    while (true) {
      final frame = _readFrame(reader);
      if (frame == null) break;
      final record = frame.record;
      if (generation != record['generation'] ||
          (generation == null && record['journalVersion'] != null)) {
        throw const FormatException('Mixed journal generations');
      }
      final state = replayRecord(latest, record);
      if (state['id'] != id || state['revision'] != revision) {
        throw const FormatException('Journal identity or revision mismatch');
      }
      lastRecordOffset = offset;
      lastRecordCrc = frame.crc;
      if (retainAll) records.add(SessionSnapshot.fromJson(state));
      onState?.call(state);
      latest = state;
      offset = reader.positionSync();
      revision++;
    }
    if (!retainAll && latest != null) {
      records.add(SessionSnapshot.fromJson(latest));
    }
    return JournalScan(
      records,
      offset,
      generation: generation,
      lastRecordOffset: lastRecordOffset,
      checkpointRevision: checkpointRevision,
      lastRecordCrc: lastRecordCrc,
    );
  } finally {
    reader.closeSync();
  }
}

void writeJournalCheckpoint(String path, String id, JournalScan scan) {
  if (scan.generation == null || scan.records.isEmpty) return;
  final temp = File('$path.checkpoint.tmp');
  try {
    temp.writeAsBytesSync(
      journalFrame({
        'id': id,
        'generation': scan.generation,
        'offset': scan.lastRecordOffset,
        'end': scan.validBytes,
        'crc': scan.lastRecordCrc,
        'state': scan.records.last.toJson(),
      }),
      flush: true,
    );
    temp.renameSync('$path.checkpoint');
  } catch (_) {
    // A committed journal remains authoritative even if the cache cannot save.
  } finally {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } catch (_) {}
  }
}

/// Caller holds the writer lease. Original remains authoritative until the
/// verified replacement is flushed and renamed over it in the same directory.
JournalScan migrateJournal(
  String path,
  String id, {
  void Function(String boundary)? onBoundary,
}) {
  final initial = scanJournal(path, id, useCheckpoint: false);
  if (!initial.legacy) return initial;
  final temp = File('$path.migrating');
  final generation = newJournalGeneration();
  Map<String, Object?>? previous;
  final writer = temp.openSync(mode: FileMode.write);
  try {
    scanJournal(
      path,
      id,
      useCheckpoint: false,
      onState: (state) {
        final record = journalRecord(previous, state, generation);
        final frame = journalFrame(record);
        // Compare every reconstructed revision, including pending tool states.
        final encoded = _map(jsonDecode(utf8.decode(frame.sublist(12))));
        final replayed = replayRecord(previous, encoded);
        if (!sameJson(replayed, state)) {
          throw const FormatException('Migration mismatch');
        }
        writer.writeFromSync(frame);
        previous = state;
      },
    );
    writer.flushSync();
  } catch (_) {
    writer.closeSync();
    if (temp.existsSync()) temp.deleteSync();
    rethrow;
  }
  writer.closeSync();
  try {
    onBoundary?.call('staged');
    final verified = scanJournal(temp.path, id, useCheckpoint: false);
    if (!sameJson(
      verified.records.last.toJson(),
      initial.records.last.toJson(),
    )) {
      throw const FormatException('Migration final checkpoint mismatch');
    }
    onBoundary?.call('verified');
    temp.renameSync(path);
    onBoundary?.call('replaced');
    writeJournalCheckpoint(path, id, verified);
    return scanJournal(path, id);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

final _crcTable = List<int>.generate(256, (value) {
  var crc = value;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
  }
  return crc;
});

int journalCrc(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xff];
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
