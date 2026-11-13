import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' as d;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/db.dart';
import '../models/ledger_display_item.dart';
import '../services/data_import_service.dart';
import '../utils/app_localizations_resolver.dart';
import 'sync_diff_service.dart';
import 's3_encrypted_storage.dart';
import 'transactions_json.dart';
import 'transactions_sync_manager.dart';
import 'sync_service.dart';

/// Append-only S3 journal. Each device writes its own immutable keys, so two
/// devices never overwrite each other's changes. Collaboration discovery files
/// live under beecount-sync/v3, leaving legacy and unencrypted objects untouched.
class S3IncrementalSyncManager extends TransactionsSyncManager {
  S3IncrementalSyncManager({
    required super.config,
    required super.db,
    required super.repo,
    required super.provider,
  }) : _storage = S3EncryptedStorage(provider.storage,
          password: config.s3SyncPassword!, bucket: config.s3Bucket!);

  final S3EncryptedStorage _storage;
  final Map<int, Future<int>> _inFlight = {};
  final Map<int, int> _remoteLedgerIds = {};

  /// 解不开云端的密钥封装就别往上写东西。[S3EncryptedStorage] 内部缓存了结果,
  /// 所以 30 秒轮询不会每次都多一个 GET。
  Future<void> _ensurePassword() => _storage.ensureKey();

  String get _namespace => sha256
      .convert(utf8.encode('${config.type.name}|${config.s3Endpoint}|${config.s3Bucket}|${config.s3AccessKey}'))
      .toString()
      .substring(0, 20);

  Future<String> _deviceId(SharedPreferences prefs) async {
    final key = 's3_collaboration_device_id';
    final existing = prefs.getString(key);
    if (existing != null) return existing;
    final created = const Uuid().v4();
    await prefs.setString(key, created);
    return created;
  }

  int _remoteId(int ledgerId) => _remoteLedgerIds[ledgerId] ?? ledgerId;
  String _prefix(int ledgerId) =>
      'beecount-sync/v3/ledger_${_remoteId(ledgerId)}/';
  static const _discoveryPrefix = 'beecount-sync/v3/ledgers/';
  static String remoteLedgerPath(String remoteId) =>
      '${_discoveryPrefix}ledger_$remoteId.json';
  String _discoveryPath(int ledgerId) =>
      remoteLedgerPath(_remoteId(ledgerId).toString());
  String _mappingKey(int ledgerId) =>
      's3_journal_$_namespace.$ledgerId.remote_ledger_id';

  void _loadMapping(int ledgerId, SharedPreferences prefs) {
    final remoteId = prefs.getInt(_mappingKey(ledgerId));
    if (remoteId != null) _remoteLedgerIds[ledgerId] = remoteId;
  }
  String _cursorKey(int ledgerId, String deviceId) =>
      's3_journal_$_namespace.$ledgerId.${_remoteId(ledgerId) == 0 ? 'unassigned.' : ''}$deviceId';
  String _entityVersionKey(int ledgerId, String syncId) =>
      's3_journal_$_namespace.$ledgerId.${_remoteId(ledgerId) == 0 ? 'unassigned.' : ''}entity.$syncId';

  /// Publish local edits before applying remote edits, so an offline edit is
  /// durable even if the other device changed the same transaction meanwhile.
  Future<int> syncIncremental({required int ledgerId}) async {
    final active = _inFlight[ledgerId];
    if (active != null) return active;
    final work = () async {
      var applied = 0;
      final ledger = await (db.select(db.ledgers)
            ..where((row) => row.id.equals(ledgerId)))
          .getSingleOrNull();
      if (ledger == null) {
        final anyLedger = await (db.select(db.ledgers)..limit(1)).get();
        if (anyLedger.isNotEmpty) {
          throw StateError(resolveAppLocalizations(null).ledgerMissing);
        }
        _remoteLedgerIds[ledgerId] = 0;
      } else if (_remoteLedgerIds[ledgerId] == 0) {
        _remoteLedgerIds.remove(ledgerId);
      }
      await _ensurePassword();
      final prefs = await SharedPreferences.getInstance();
      _loadMapping(ledgerId, prefs);
      if (ledger == null) _remoteLedgerIds[ledgerId] = 0;
      if (prefs.getInt(_mappingKey(ledgerId)) == null) {
        final discovery = await _storage.download(path: _discoveryPath(ledgerId));
        if (discovery != null) {
          final remote = jsonDecode(discovery) as Map<String, dynamic>;
          final expected = ledger?.syncId ??
              (ledger == null ? '__unassigned__' : ledgerId.toString());
          if ((remote['ledgerSyncId'] as String? ?? ledgerId.toString()) != expected ||
              (remote['unassigned'] == true) != (ledger == null)) {
            throw StateError(
                'S3 remote ledger ID belongs to another ledger; discover remote ledgers before syncing');
          }
        }
      }
      final deviceId = await _deviceId(prefs);
      applied += await _importDiscoverySnapshotIfEmpty(ledgerId, prefs);
      await _push(ledgerId, prefs, deviceId);
      applied += await _pull(ledgerId, prefs, deviceId);
      return applied;
    }();
    _inFlight[ledgerId] = work;
    try {
      return await work;
    } finally {
      if (identical(_inFlight[ledgerId], work)) _inFlight.remove(ledgerId);
    }
  }

  Future<int> _importDiscoverySnapshotIfEmpty(
      int ledgerId, SharedPreferences prefs) async {
    final key = 's3_journal_$_namespace.$ledgerId.discovery_checked';
    if (prefs.getBool(key) ?? false) return 0;
    var inserted = 0;
    final local = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..limit(1))
        .get();
    final raw = await _storage.download(path: _discoveryPath(ledgerId));
    if (raw != null) {
      if (local.isEmpty) {
        final result = await importTransactionsJson(repo, ledgerId, raw,
            recordChanges: false);
        inserted = result.inserted;
      } else {
        // A discovery snapshot may contain transactions created on another
        // device. Import only missing IDs, and respect local delete tombstones.
        final data = parseJsonToImportData(raw);
        final current = await (db.select(db.transactions)
              ..where((t) => t.ledgerId.equals(ledgerId)))
            .get();
        final known = current.map((tx) => tx.syncId).toSet();
        final deletions = await (db.select(db.localChanges)
              ..where((c) => c.entityType.equals('transaction') &
                  c.action.equals('delete')))
            .get();
        final deleted = deletions.map((change) => change.entitySyncId).toSet();
        final additions = data.transactions
            .where((tx) => tx.syncId != null &&
                !known.contains(tx.syncId) &&
                !deleted.contains(tx.syncId))
            .map((tx) => SyncChange(
                type: SyncChangeType.added, cloudTransaction: tx))
            .toList();
        final result = await syncDiffService.applySyncChanges(
          repo: repo,
          ledgerId: ledgerId,
          importData: data,
          selectedChanges: additions,
          recordChanges: false,
        );
        if (result.addedCount != additions.length) {
          throw StateError('S3 collaboration discovery import was incomplete');
        }
        inserted = result.addedCount;
      }
    }
    await prefs.setBool(key, true);
    return inserted;
  }

  Future<int> _pull(int ledgerId, SharedPreferences prefs, String ownId) async {
    final prefix = _prefix(ledgerId);
    final names = await _storage.list(path: prefix);
    final pending = <({String path, String device, int sequence})>[];
    for (final file in names) {
      final suffix = file.path.substring(prefix.length);
      final parts = suffix.split('/');
      if (parts.length != 2 || !parts[1].endsWith('.json')) continue;
      final sequence = int.tryParse(parts[1].replaceFirst('.json', ''));
      if (sequence == null || parts[0] == ownId) continue;
      if (sequence > (prefs.getInt(_cursorKey(ledgerId, parts[0])) ?? -1)) {
        pending.add((path: file.path, device: parts[0], sequence: sequence));
      }
    }
    final downloaded = <({String path, String device, int sequence, Map<String, dynamic> event})>[];
    for (final item in pending) {
      final raw = await _storage.download(path: item.path);
      if (raw == null) throw StateError('S3 journal entry disappeared: ${item.path}');
      downloaded.add((
        path: item.path,
        device: item.device,
        sequence: item.sequence,
        event: jsonDecode(raw) as Map<String, dynamic>,
      ));
    }
    // Keep each writer's cursor contiguous. Entity versions below determine
    // which writer wins when two devices edited the same transaction.
    downloaded.sort((a, b) {
      final byDevice = a.device.compareTo(b.device);
      return byDevice != 0 ? byDevice : a.sequence.compareTo(b.sequence);
    });
    var applied = 0;
    for (final item in downloaded) {
      final event = item.event;
      if (event['action'] == 'bootstrap') {
        final snapshot = event['snapshot'] as Map<String, dynamic>;
        final importData = parseJsonToImportData(jsonEncode(snapshot));
        final additions = <SyncChange>[];
        for (final tx in importData.transactions) {
          final syncId = tx.syncId;
          if (syncId == null) continue;
          final existing = await (db.select(db.transactions)
                ..where((t) => t.syncId.equals(syncId)))
              .getSingleOrNull();
          if (existing == null) {
            additions.add(SyncChange(
                type: SyncChangeType.added, cloudTransaction: tx));
          }
        }
        final result = await syncDiffService.applySyncChanges(
          repo: repo,
          ledgerId: ledgerId,
          importData: importData,
          recordChanges: false,
          selectedChanges: additions,
        );
        if (result.addedCount != additions.length) {
          throw StateError('S3 bootstrap import was incomplete');
        }
        applied += result.totalCount;
      } else if (event['action'] == 'metadata') {
        final snapshot = event['snapshot'] as Map<String, dynamic>;
        final importData = parseJsonToImportData(jsonEncode(snapshot));
        await dataImportService.importCategories(repo, importData.categories);
        await dataImportService.importAccounts(repo, importData.accounts,
            defaultCurrency: importData.currency ?? 'CNY');
        await dataImportService.importTags(repo, importData.tags);
        applied++;
      } else {
        final syncId = event['syncId'] as String;
        final version = '${event['createdAt']}|${item.device}';
        final versionKey = _entityVersionKey(ledgerId, syncId);
        final previousVersion = prefs.getString(versionKey);
        if (previousVersion != null && version.compareTo(previousVersion) <= 0) {
          await prefs.setInt(_cursorKey(ledgerId, item.device), item.sequence);
          continue;
        }
        final latestLocal = await (db.select(db.localChanges)
              ..where((c) => c.entityType.equals('transaction') &
                  c.entitySyncId.equals(syncId))
              ..orderBy([(c) => d.OrderingTerm.desc(c.id)])
              ..limit(1))
            .getSingleOrNull();
        final remoteTime = DateTime.parse(event['createdAt'] as String);
        if (latestLocal != null &&
            ('${latestLocal.createdAt.toUtc().toIso8601String()}|$ownId')
                    .compareTo('${remoteTime.toUtc().toIso8601String()}|${item.device}') >
                0) {
          await prefs.setInt(_cursorKey(ledgerId, item.device), item.sequence);
          continue;
        }
        if (event['action'] == 'delete') {
          applied += await repo.deleteTransactionsBatchBySyncIds(
              [syncId], recordChanges: false);
        } else {
        final snapshot = event['snapshot'] as Map<String, dynamic>;
        final importData = parseJsonToImportData(jsonEncode(snapshot));
        if (importData.transactions.length != 1) {
          throw FormatException('S3 journal entry must contain one transaction');
        }
        final existing = await (db.select(db.transactions)
              ..where((t) => t.syncId.equals(syncId)))
            .getSingleOrNull();
        final result = await syncDiffService.applySyncChanges(
          repo: repo,
          ledgerId: ledgerId,
          importData: importData,
          recordChanges: false,
          selectedChanges: [SyncChange(
            type: existing == null ? SyncChangeType.added : SyncChangeType.modified,
            cloudTransaction: importData.transactions.single,
            localTransaction: existing,
          )],
        );
        if (result.totalCount != 1) {
          throw StateError('S3 journal import was incomplete: $syncId');
        }
        applied += result.totalCount;
        }
        await prefs.setString(versionKey, version);
      }
      await prefs.setInt(_cursorKey(ledgerId, item.device), item.sequence);
    }
    if (applied > 0) clearStatusCache(ledgerId: ledgerId);
    return applied;
  }

  Future<void> _push(int ledgerId, SharedPreferences prefs, String deviceId) async {
    final cursorKey = _cursorKey(ledgerId, deviceId);
    final unassigned = _remoteId(ledgerId) == 0;
    final snapshot = jsonDecode(await exportTransactionsJson(db, ledgerId,
        allowMissingLedger: unassigned))
        as Map<String, dynamic>;
    if (unassigned) {
      snapshot['ledgerSyncId'] = '__unassigned__';
    } else {
      final ledger = await (db.select(db.ledgers)
            ..where((row) => row.id.equals(ledgerId)))
          .getSingle();
      snapshot['ledgerSyncId'] = ledger.syncId ?? ledgerId.toString();
    }
    final bootstrapKey = '$cursorKey.bootstrap';
    if (!(prefs.getBool(bootstrapKey) ?? false)) {
      await _storage.upload(
        path: '${_prefix(ledgerId)}$deviceId/000000000000.json',
        data: jsonEncode({
          'version': 1,
          'action': 'bootstrap',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'snapshot': snapshot,
        }),
      );
      // Discovery seed is separate from the old S3 snapshot backup format.
      final discoveryPath = _discoveryPath(ledgerId);
      if (await _storage.download(path: discoveryPath) == null) {
        await _storage.upload(path: discoveryPath, data: jsonEncode(snapshot));
      }
      await prefs.setBool(bootstrapKey, true);
    }
    final lastSent = prefs.getInt(cursorKey) ?? -1;
    final changes = await (db.select(db.localChanges)
          ..where((c) => c.id.isBiggerThanValue(lastSent) &
              ((c.ledgerId.equals(ledgerId) &
                      c.entityType.equals('transaction')) |
                  (c.ledgerId.equals(0) &
                      c.entityType.isIn(['account', 'category', 'tag']))))
          ..orderBy([(c) => d.OrderingTerm.asc(c.id)]))
        .get();
    if (changes.isEmpty) return;
    final byId = <String, Map<String, dynamic>>{
      for (final item in snapshot['items'] as List)
        if ((item as Map<String, dynamic>)['syncId'] is String)
          item['syncId'] as String: item,
    };
    for (final change in changes) {
      if (change.ledgerId == 0) {
        await _storage.upload(
          path: '${_prefix(ledgerId)}$deviceId/${change.id.toString().padLeft(12, '0')}.json',
          data: jsonEncode({
            'version': 1,
            'action': 'metadata',
            'createdAt': change.createdAt.toUtc().toIso8601String(),
            'snapshot': snapshot,
          }),
        );
        await prefs.setInt(cursorKey, change.id);
        continue;
      }
      final item = byId[change.entitySyncId];
      final action = change.action == 'delete' || item == null
          ? 'delete'
          : 'upsert';
      final event = <String, dynamic>{
        'version': 1,
        'syncId': change.entitySyncId,
        'action': action,
        'createdAt': change.createdAt.toUtc().toIso8601String(),
        if (item != null && action == 'upsert')
          'snapshot': {...snapshot, 'count': 1, 'items': [item]},
      };
      await _storage.upload(
        path: '${_prefix(ledgerId)}$deviceId/${change.id.toString().padLeft(12, '0')}.json',
        data: jsonEncode(event),
      );
      await prefs.setInt(cursorKey, change.id);
    }
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async {
    try {
      final ledger = await (db.select(db.ledgers)
            ..where((row) => row.id.equals(ledgerId)))
          .getSingleOrNull();
      if (ledger == null) {
        final anyLedger = await (db.select(db.ledgers)..limit(1)).get();
        if (anyLedger.isNotEmpty) {
          return SyncStatus(
              diff: SyncDiff.error,
              localCount: 0,
              localFingerprint: '',
              message: resolveAppLocalizations(null).ledgerMissing);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      _loadMapping(ledgerId, prefs);
      if (ledger == null) {
        _remoteLedgerIds[ledgerId] = 0;
      } else if (_remoteLedgerIds[ledgerId] == 0) {
        _remoteLedgerIds.remove(ledgerId);
      }
      final ownId = await _deviceId(prefs);
      final cursor = prefs.getInt(_cursorKey(ledgerId, ownId)) ?? -1;
      final local = await (db.select(db.localChanges)
            ..where((c) => c.id.isBiggerThanValue(cursor) &
                ((c.ledgerId.equals(ledgerId) &
                        c.entityType.equals('transaction')) |
                    (c.ledgerId.equals(0) &
                        c.entityType.isIn(['account', 'category', 'tag']))))
            ..limit(1))
          .get();
      final files = await _storage.list(path: _prefix(ledgerId));
      final hasDiscovery = files.isEmpty &&
          await _storage.download(path: _discoveryPath(ledgerId)) != null;
      var remotePending = false;
      for (final file in files) {
        final suffix = file.path.substring(_prefix(ledgerId).length);
        final parts = suffix.split('/');
        if (parts.length != 2 || parts[0] == ownId) continue;
        final sequence = int.tryParse(parts[1].replaceFirst('.json', ''));
        if (sequence != null &&
            sequence > (prefs.getInt(_cursorKey(ledgerId, parts[0])) ?? -1)) {
          remotePending = true;
          break;
        }
      }
      final transactions = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(ledgerId)))
          .get();
      final count = transactions.length;
      final fingerprintRows = transactions
          .map((tx) => '${tx.syncId}|${tx.type}|${tx.amount}|${tx.note}|${tx.happenedAt}')
          .toList()
        ..sort();
      final localFingerprint = sha256
          .convert(utf8.encode(fingerprintRows.join('\n')))
          .toString();
      final diff = files.isEmpty
          ? hasDiscovery
              ? count == 0 ? SyncDiff.cloudNewer : SyncDiff.different
              : SyncDiff.noRemote
          : local.isNotEmpty && remotePending
              ? SyncDiff.different
              : local.isNotEmpty
                  ? SyncDiff.localNewer
                  : remotePending
                      ? SyncDiff.cloudNewer
                      : SyncDiff.inSync;
      return SyncStatus(
          diff: diff, localCount: count, localFingerprint: localFingerprint);
    } catch (e) {
      return SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: e.toString());
    }
  }

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    await getStatus(ledgerId: ledgerId);
    return (fingerprint: null, count: null, exportedAt: null);
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    final prefs = await SharedPreferences.getInstance();
    _loadMapping(ledgerId, prefs);
    final files = await _storage.list(path: _prefix(ledgerId));
    for (final file in files) {
      await _storage.delete(path: file.path);
    }
    await _storage.delete(path: _discoveryPath(ledgerId));
    // 最后一个账本删完,密钥封装对象也一起收掉:云端已经没有用这把 DEK 加密的
    // 数据了,留着只会让下次启用继续绑在旧 DEK 上。本机缓存同时失效,下次同步
    // 会生成新的 DEK。
    final remaining = await _storage.list(path: 'beecount-sync/v3/');
    if (remaining
        .every((file) => file.path == S3EncryptedStorage.keyParamsPath)) {
      await _storage.delete(path: S3EncryptedStorage.keyParamsPath);
      _storage.invalidateKeyCache();
    }
    final prefix = 's3_journal_$_namespace.$ledgerId.';
    for (final key in prefs.getKeys().where((key) => key.startsWith(prefix))) {
      await prefs.remove(key);
    }
    clearStatusCache(ledgerId: ledgerId);
  }

  @override
  Future<int?> downloadRemoteLedger({
    required String name,
    required String currency,
    required String remotePath,
  }) async {
    final remoteId = int.tryParse(RegExp(
            r'^beecount-sync/v3/ledgers/ledger_(\d+)\.json$')
        .firstMatch(remotePath)
        ?.group(1) ?? '');
    if (remoteId == null) throw FormatException('Invalid S3 ledger path: $remotePath');
    final raw = await _storage.download(path: remotePath);
    if (raw == null) return null;
    final remoteJson = jsonDecode(raw) as Map<String, dynamic>;
    final remoteSyncId = remoteJson['ledgerSyncId'] as String? ??
        remoteId.toString();
    final existingBySyncId = await (db.select(db.ledgers)
          ..where((t) => t.syncId.equals(remoteSyncId)))
        .getSingleOrNull();
    int ledgerId;
    if (existingBySyncId != null) {
      ledgerId = existingBySyncId.id;
    } else {
      ledgerId = await db.transaction(() async {
        final hadLedgers =
            (await (db.select(db.ledgers)..limit(1)).get()).isNotEmpty;
        final occupied = await (db.select(db.ledgers)
              ..where((t) => t.id.equals(remoteId)))
            .getSingleOrNull();
        final id = await db.into(db.ledgers).insert(LedgersCompanion.insert(
              id: occupied == null ? d.Value(remoteId) : const d.Value.absent(),
              name: name,
              currency: d.Value(currency),
              syncId: d.Value(remoteSyncId),
            ));
        if (!hadLedgers) {
          await db.update(db.transactions).write(
              TransactionsCompanion(ledgerId: d.Value(id)));
          await (db.update(db.localChanges)
                ..where((change) => change.entityType.equals('transaction')))
              .write(LocalChangesCompanion(ledgerId: d.Value(id)));
        }
        return id;
      });
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_mappingKey(ledgerId), remoteId);
    _remoteLedgerIds[ledgerId] = remoteId;
    await prefs.remove('s3_journal_$_namespace.$ledgerId.discovery_checked');
    await syncIncremental(ledgerId: ledgerId);
    return ledgerId;
  }

  @override
  Future<List<LedgerDisplayItem>> getRemoteLedgers() async {
    await _ensurePassword();
    final files = await _storage.list(path: _discoveryPrefix);
    final local = await db.select(db.ledgers).get();
    final prefs = await SharedPreferences.getInstance();
    for (final ledger in local) {
      _loadMapping(ledger.id, prefs);
    }
    final usedRemoteIds = <int>{
      ...local.map((ledger) => _remoteId(ledger.id)),
    };
    for (final file in files) {
      final match = RegExp(r'^beecount-sync/v3/ledgers/ledger_(\d+)\.json$')
          .firstMatch(file.path);
      if (match != null) usedRemoteIds.add(int.parse(match.group(1)!));
    }
    var nextRemoteId = usedRemoteIds.isEmpty
        ? 1
        : usedRemoteIds.reduce((a, b) => a > b ? a : b) + 1;
    final result = <LedgerDisplayItem>[];
    for (final file in files) {
      final match = RegExp(r'^beecount-sync/v3/ledgers/ledger_(\d+)\.json$')
          .firstMatch(file.path);
      if (match == null) continue;
      final remoteId = int.parse(match.group(1)!);
      final raw = await _storage.download(path: file.path);
      if (raw == null) continue;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['unassigned'] == true) continue;
      final name = json['ledgerName'] as String? ?? 'Unknown';
      final remoteSyncId = json['ledgerSyncId'] as String? ??
          remoteId.toString();
      for (final ledger in local) {
        if (ledger.syncId == remoteSyncId && _remoteId(ledger.id) != remoteId) {
          await prefs.setInt(_mappingKey(ledger.id), remoteId);
          _remoteLedgerIds[ledger.id] = remoteId;
        }
      }
      // An unrelated local ledger may have the same integer ID. Move its S3
      // namespace before the remote ledger is restored under a new local ID.
      for (final ledger in local) {
        if (ledger.id != remoteId ||
            ledger.syncId == remoteSyncId ||
            prefs.getInt(_mappingKey(ledger.id)) != null) {
          continue;
        }
        await prefs.setInt(_mappingKey(ledger.id), nextRemoteId);
        _remoteLedgerIds[ledger.id] = nextRemoteId++;
      }
      final matching = local.where((ledger) =>
          ledger.syncId == remoteSyncId);
      if (matching.isNotEmpty) {
        final localRows = await (db.select(db.transactions)
              ..where((tx) => tx.ledgerId.equals(matching.first.id))
              ..limit(1))
            .get();
        if (localRows.isNotEmpty) continue;
      }
      final items = (json['items'] as List?) ?? const [];
      var balance = 0.0;
      for (final rawItem in items) {
        final item = rawItem as Map<String, dynamic>;
        final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
        if (item['type'] == 'income') balance += amount;
        if (item['type'] == 'expense') balance -= amount;
      }
      result.add(LedgerDisplayItem.fromRemote(
        remoteSyncId: remoteId.toString(),
        name: name,
        currency: json['currency'] as String? ?? 'CNY',
        updatedAt: DateTime.tryParse(json['exportedAt'] as String? ?? '') ??
            DateTime.now(),
        transactionCount: (json['count'] as num?)?.toInt() ?? items.length,
        balance: balance,
      ));
    }
    return result;
  }

  @override
  Future<({int success, int failed})> restoreAllRemoteLedgers() async {
    final remote = await getRemoteLedgers();
    var success = 0;
    var failed = 0;
    for (final ledger in remote) {
      try {
        final remoteId = ledger.remoteSyncId;
        if (remoteId == null) throw StateError('Remote ledger ID is missing');
        final restored = await downloadRemoteLedger(
          name: ledger.name,
          currency: ledger.currency,
          remotePath: remoteLedgerPath(remoteId),
        );
        if (restored == null) {
          failed++;
        } else {
          success++;
        }
      } catch (_) {
        failed++;
      }
    }
    return (success: success, failed: failed);
  }

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    await syncIncremental(ledgerId: ledgerId);
  }

  @override
  Future<({int inserted, int deletedDup})>
      downloadAndRestoreToCurrentLedger({required int ledgerId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('s3_journal_$_namespace.$ledgerId.discovery_checked');
    final count = await syncIncremental(ledgerId: ledgerId);
    return (inserted: count, deletedDup: 0);
  }
}
