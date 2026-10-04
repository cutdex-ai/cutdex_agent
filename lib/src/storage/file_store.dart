import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../session/snapshot.dart';
import 'store.dart';
import 'journal_codec.dart';

/// Incremental revision journal with periodic snapshots, CRC32 and OS leases.
///
/// Use a single storage isolate per process. POSIX file locks are process-wide;
/// independent isolates must route requests through that owning isolate.
/// Different processes are excluded by OS locks, released on process death.
/// Every save flushes the journal. This guarantees the tested process-crash
/// recovery boundaries, not arbitrary filesystem/device power-loss behavior.
class FileSessionStore implements SessionStore {
  FileSessionStore(this.directory);
  final Directory directory;
  static const int maxRecordBytes = journalRecordLimit;
  static final Map<String, _Lease> _owners = {};
  final Map<String, _Lease> _leases = {};
  final Map<String, Future<void>> _writes = {};

  Future<String> _base(String id) async {
    final bytes = utf8.encode(id);
    if (bytes.isEmpty || bytes.length > 128) {
      throw ArgumentError('Session ID must contain 1–128 UTF-8 bytes');
    }
    await directory.create(recursive: true);
    final root = await directory.resolveSymbolicLinks();
    return '$root/${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  @override
  Future<Object> acquire(String sessionId) async {
    final base = await _base(sessionId);
    if (_owners.containsKey(base)) {
      throw StateError('Session already has a writer: $sessionId');
    }
    final lease = _Lease(base);
    _owners[base] = lease;
    try {
      lease.file = await File('$base.lock').open(mode: FileMode.append);
      await lease.file!.lock(FileLock.exclusive);
      _leases[sessionId] = lease;
      return lease;
    } catch (_) {
      await lease.file?.close();
      _owners.remove(base);
      rethrow;
    }
  }

  @override
  Future<void> release(String sessionId, Object lease) async {
    if (lease is! _Lease || !identical(_leases[sessionId], lease)) {
      throw StateError('Invalid session lease');
    }
    // The caller must not release while its own save is in flight.
    await _writes[sessionId];
    try {
      await lease.file!.close();
    } finally {
      _owners.remove(lease.base);
      _leases.remove(sessionId);
    }
  }

  @override
  Future<SessionSnapshot?> read(String sessionId) async {
    final scan = await _scan(sessionId);
    return scan.records.lastOrNull;
  }

  /// Full checkpoint revisions, useful for auditing state transitions.
  Future<List<SessionSnapshot>> revisions(String sessionId) async =>
      List.unmodifiable((await _scan(sessionId, retainAll: true)).records);

  Future<JournalScan> _scan(
    String sessionId, {
    bool retainAll = false,
    bool useCheckpoint = true,
  }) async {
    final lease = _leases[sessionId];
    if (useCheckpoint && !retainAll && lease?.scan != null) return lease!.scan!;
    final base = await _base(sessionId);
    final scan = await _scanInBackground((
      path: '$base.journal',
      sessionId: sessionId,
      retainAll: retainAll,
      useCheckpoint: useCheckpoint,
    ));
    // Cache only within our exclusive lease. A later owner must rescan.
    // A concurrent read must never replace a newer successfully saved record.
    if (useCheckpoint && !retainAll && lease != null) lease.scan ??= scan;
    return scan;
  }

  /// Full integrity audit, including revisions before the latest snapshot.
  Future<void> verify(String sessionId) async {
    await _scan(sessionId, useCheckpoint: false);
  }

  /// Convert v1 without losing any revision. Refuses migration during a run.
  /// Saving an old journal also performs this conversion under its writer lease.
  Future<void> migrate(String sessionId) async {
    final lease = await acquire(sessionId) as _Lease;
    try {
      lease.scan = await _migrateInBackground(
        '${lease.base}.journal',
        sessionId,
      );
    } finally {
      await release(sessionId, lease);
    }
  }

  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) {
    final previous = _writes[snapshot.id] ?? Future<void>.value();
    final next = previous.then((_) => _save(snapshot, expectedRevision));
    final settled = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace trace) {},
    );
    _writes[snapshot.id] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_writes[snapshot.id], settled)) {
          _writes.remove(snapshot.id);
        }
      }),
    );
    return next;
  }

  Future<void> _save(SessionSnapshot snapshot, int? expectedRevision) async {
    final owned = _leases[snapshot.id];
    final lease = owned ?? await acquire(snapshot.id) as _Lease;
    try {
      var scan = lease.scan ?? await _scan(snapshot.id);
      if (scan.records.lastOrNull?.revision != expectedRevision ||
          snapshot.revision != (expectedRevision ?? -1) + 1) {
        throw StateError('Session revision conflict: ${snapshot.id}');
      }
      if (scan.legacy) {
        scan = await _migrateInBackground('${lease.base}.journal', snapshot.id);
      }
      final generation = scan.generation ?? newJournalGeneration();
      final record = journalRecord(
        scan.records.lastOrNull?.toJson(),
        snapshot.toJson(),
        generation,
      );
      final frame = journalFrame(record);
      final file = await File(
        '${lease.base}.journal',
      ).open(mode: FileMode.append);
      try {
        // Remove only a torn final frame while holding the writer lease.
        await file.truncate(scan.validBytes);
        await file.setPosition(scan.validBytes);
        await file.writeFrom(frame);
        await file.flush();
      } finally {
        await file.close();
      }
      final checkpoint =
          snapshot.revision == 0 ||
          snapshot.revision - scan.checkpointRevision >=
              journalSnapshotInterval;
      final updated = JournalScan(
        [snapshot],
        scan.validBytes + frame.length,
        generation: generation,
        lastRecordOffset: scan.validBytes,
        checkpointRevision: checkpoint
            ? snapshot.revision
            : scan.checkpointRevision,
        lastRecordCrc: ByteData.sublistView(frame).getUint32(4),
      );
      lease.scan = updated;
      if (checkpoint) {
        await _checkpointInBackground(
          '${lease.base}.journal',
          snapshot.id,
          updated,
        );
      }
    } catch (_) {
      // A failed/torn write must be revalidated before another append.
      lease.scan = null;
      rethrow;
    } finally {
      if (owned == null) {
        // Avoid waiting on this save's own queue entry.
        try {
          await lease.file!.close();
        } finally {
          _owners.remove(lease.base);
          _leases.remove(snapshot.id);
        }
      }
    }
  }
}

class _Lease {
  _Lease(this.base);
  final String base;
  RandomAccessFile? file;
  JournalScan? scan;
}

// Workers parse/encode data only. The calling isolate owns all OS leases.
typedef _ScanInput = ({
  String path,
  String sessionId,
  bool retainAll,
  bool useCheckpoint,
});
Future<JournalScan> _scanInBackground(_ScanInput input) => Isolate.run(
  () => scanJournal(
    input.path,
    input.sessionId,
    retainAll: input.retainAll,
    useCheckpoint: input.useCheckpoint,
  ),
);

Future<JournalScan> _migrateInBackground(String path, String id) =>
    Isolate.run(() => migrateJournal(path, id));

Future<void> _checkpointInBackground(
  String path,
  String id,
  JournalScan scan,
) async {
  try {
    await Isolate.run(() => writeJournalCheckpoint(path, id, scan));
  } catch (_) {
    // The committed journal can always recover without the optional checkpoint cache.
  }
}
