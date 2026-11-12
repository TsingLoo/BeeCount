import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/cloud/s3_encrypted_storage.dart';
import 'package:beecount/cloud/s3_incremental_sync_manager.dart';
import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/export/config_export_service.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/providers/sync_providers.dart';

class _MemoryStorage implements CloudStorageService {
  final objects = <String, String>{};

  @override
  Future<void> upload({required String path, required String data,
      Map<String, String>? metadata}) async {
    objects[path] = data;
  }

  @override
  Future<String?> download({required String path}) async => objects[path];

  @override
  Future<bool> exists({required String path}) async => objects.containsKey(path);

  @override
  Future<List<CloudFile>> list({required String path}) async => objects.keys
      .where((key) => key.startsWith(path))
      .map((key) => CloudFile(name: key.split('/').last, path: key))
      .toList();

  @override
  Future<void> delete({required String path}) async { objects.remove(path); }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryProvider implements CloudProvider {
  _MemoryProvider(this.storage);

  @override
  final CloudStorageService storage;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backup S3 and collaboration S3 keep independent configurations', () async {
    final backup = CloudServiceConfig(
      type: CloudBackendType.s3,
      name: 'Backup',
      s3Endpoint: 'backup.example',
      s3AccessKey: 'backup-key',
      s3SecretKey: 'backup-secret',
      s3Bucket: 'backup-bucket',
    );
    final collaboration = CloudServiceConfig(
      type: CloudBackendType.s3Collaboration,
      name: 'Collaboration',
      s3Endpoint: 'sync.example',
      s3AccessKey: 'sync-key',
      s3SecretKey: 'sync-secret',
      s3Bucket: 'sync-bucket',
      s3SyncPassword: 'correct horse battery staple',
    );
    SharedPreferences.setMockInitialValues({
      'cloud_s3_cfg': encodeCloudConfig(backup),
      'cloud_active_type': 's3',
    });
    final store = CloudServiceStore();
    expect((await store.loadActive()).type, CloudBackendType.s3);
    await store.saveOnly(collaboration);
    expect((await store.loadS3())?.s3Bucket, 'backup-bucket');
    expect((await store.loadS3Collaboration())?.s3Bucket, 'sync-bucket');
    expect((await store.loadActive()).type, CloudBackendType.s3);
    expect(await store.activate(CloudBackendType.s3Collaboration), isTrue);
    expect((await store.loadActive()).type, CloudBackendType.s3Collaboration);
    expect(await store.activate(CloudBackendType.s3), isTrue);
    expect((await store.loadActive()).type, CloudBackendType.s3);
  });

  test('configuration export keeps backup and collaboration S3 separate', () {
    const config = AppConfig(
      s3: S3Config(
        endpoint: 'backup.example', region: 'auto', accessKey: 'a',
        secretKey: 'b', bucket: 'backup'),
      s3Collaboration: S3Config(
        endpoint: 'sync.example', region: 'auto', accessKey: 'c',
        secretKey: 'd', bucket: 'sync'),
    );
    final restored = AppConfig.fromYaml(config.toYaml());
    expect(restored.s3?.bucket, 'backup');
    expect(restored.s3Collaboration?.bucket, 'sync');
  });

  test('only collaboration S3 records incremental repository changes', () async {
    Future<bool> hasTracker(CloudBackendType type) async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        activeCloudConfigProvider.overrideWith((ref) async => CloudServiceConfig(
          type: type,
          name: 'S3',
          s3Endpoint: 'example.test',
          s3AccessKey: 'key',
          s3SecretKey: 'secret',
          s3Bucket: 'bucket',
          s3SyncPassword: 'correct horse battery staple',
        )),
      ]);
      try {
        await container.read(activeCloudConfigProvider.future);
        return (container.read(repositoryProvider) as LocalRepository)
                .changeTracker !=
            null;
      } finally {
        container.dispose();
        await db.close();
      }
    }

    expect(await hasTracker(CloudBackendType.s3), isFalse);
    expect(await hasTracker(CloudBackendType.s3Collaboration), isTrue);
  });

  test('a second device imports the initial ledger without overwriting it', () async {
    final storage = _MemoryStorage();
    storage.objects['ledger_1.json'] = 'legacy backup must stay unchanged';
    final config = CloudServiceConfig(
        type: CloudBackendType.s3Collaboration,
        name: 'test',
        s3Endpoint: 'example.test',
        s3Bucket: 'bucket',
        s3AccessKey: 'key',
        s3SecretKey: 'secret',
        s3SyncPassword: 'correct horse battery staple');
    final dbA = BeeDatabase.forTesting(NativeDatabase.memory());
    final dbB = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final ledgerA = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      expect(ledgerA, ledgerB);
      await dbA.into(dbA.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerA,
          type: 'expense',
          amount: 12,
          syncId: const Value('transaction-1')));
      final a = S3IncrementalSyncManager(
          config: config,
          db: dbA,
          repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
          provider: _MemoryProvider(storage));
      final b = S3IncrementalSyncManager(
          config: config,
          db: dbB,
          repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
          provider: _MemoryProvider(storage));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'A'});
      await a.syncIncremental(ledgerId: ledgerA);
      expect(storage.objects['ledger_1.json'], 'legacy backup must stay unchanged');
      expect(storage.objects,
          contains('beecount-sync/v3/ledgers/ledger_$ledgerA.json'));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'B'});
      expect(await b.syncIncremental(ledgerId: ledgerB), 1);
      final imported = await dbB.select(dbB.transactions).get();
      expect(imported, hasLength(1));
      expect(imported.single.syncId, 'transaction-1');
      expect(imported.single.amount, 12);
      await a.deleteRemoteBackup(ledgerId: ledgerA);
      expect(storage.objects['ledger_1.json'], 'legacy backup must stay unchanged');
      expect(storage.objects.keys.where((key) => key.startsWith('beecount-sync/v3/')),
          isEmpty);
    } finally {
      await dbA.close();
      await dbB.close();
    }
  });

  test('same-name independent ledgers stay separate on first collaboration sync', () async {
    final storage = _MemoryStorage();
    final config = CloudServiceConfig(
        type: CloudBackendType.s3Collaboration,
        name: 'test',
        s3Endpoint: 'example.test',
        s3Bucket: 'bucket',
        s3AccessKey: 'key',
        s3SecretKey: 'secret',
        s3SyncPassword: 'correct horse battery staple');
    final dbA = BeeDatabase.forTesting(NativeDatabase.memory());
    final dbB = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final remoteId = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('remote-ledger')));
      final localId = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('local-ledger')));
      await dbA.into(dbA.transactions).insert(TransactionsCompanion.insert(
          ledgerId: remoteId, type: 'expense', amount: 10,
          syncId: const Value('remote-transaction')));
      await dbB.into(dbB.transactions).insert(TransactionsCompanion.insert(
          ledgerId: localId, type: 'expense', amount: 20,
          syncId: const Value('local-transaction')));
      final a = S3IncrementalSyncManager(
          config: config, db: dbA,
          repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
          provider: _MemoryProvider(storage));
      final b = S3IncrementalSyncManager(
          config: config, db: dbB,
          repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
          provider: _MemoryProvider(storage));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'A'});
      await a.syncIncremental(ledgerId: remoteId);
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'B'});
      await expectLater(b.syncIncremental(ledgerId: localId), throwsStateError);
      expect((await dbB.select(dbB.transactions).get()).single.syncId,
          'local-transaction');
      final discovered = await b.getRemoteLedgers();
      expect(discovered, hasLength(1));
      await b.downloadRemoteLedger(
          name: discovered.single.name,
          currency: discovered.single.currency,
          remotePath: S3IncrementalSyncManager.remoteLedgerPath(
              discovered.single.remoteSyncId!));
      final ledgers = await dbB.select(dbB.ledgers).get();
      final transactions = await dbB.select(dbB.transactions).get();
      expect(ledgers, hasLength(2));
      expect(transactions, hasLength(2));
      expect(transactions.where((tx) => tx.ledgerId == localId).single.syncId,
          'local-transaction');
      expect(transactions.where((tx) => tx.ledgerId != localId).single.syncId,
          'remote-transaction');
    } finally {
      await dbA.close();
      await dbB.close();
    }
  });

  test('collaboration objects reach storage as ciphertext only', () async {
    final storage = _MemoryStorage();
    const password = 'correct horse battery staple';
    final config = CloudServiceConfig(
        type: CloudBackendType.s3Collaboration,
        name: 'test',
        s3Endpoint: 'example.test',
        s3Bucket: 'bucket',
        s3AccessKey: 'key',
        s3SecretKey: 'secret',
        s3SyncPassword: password);
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: 'Secret Home Ledger', syncId: const Value('ledger')));
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 1234.56,
          note: const Value('latte-at-midnight'),
          syncId: const Value('transaction-1')));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'A'});
      await S3IncrementalSyncManager(
              config: config,
              db: db,
              repo: LocalRepository(db, changeTracker: ChangeTracker(db)),
              provider: _MemoryProvider(storage))
          .syncIncremental(ledgerId: ledgerId);

      final uploaded = storage.objects.entries
          .where((entry) => entry.key.startsWith('beecount-sync/v3/'))
          .toList();
      expect(uploaded, isNotEmpty);
      for (final entry in uploaded) {
        if (entry.key == S3EncryptedStorage.keyParamsPath) {
          // 密钥封装本身是明文 JSON，但里面的数据密钥是被口令加密过的
          final params = jsonDecode(entry.value) as Map<String, dynamic>;
          expect(params['salt'], isA<String>());
          expect(params['wrappedKey'], isA<String>());
          expect(params['wrapNonce'], isA<String>());
          expect(entry.value, isNot(contains(password)));
          continue;
        }
        final envelope = jsonDecode(entry.value) as Map<String, dynamic>;
        expect(envelope['beecountE2ee'], 1);
        expect(envelope.keys, containsAll(<String>['nonce', 'ciphertext']));
        expect(entry.value, isNot(contains('latte-at-midnight')));
        expect(entry.value, isNot(contains('Secret Home Ledger')));
        expect(entry.value, isNot(contains('1234.56')));
        expect(entry.value, isNot(contains('transaction-1')));
      }

      // 不是写坏了才看不到明文：拿对口令还能原样解回来
      final decrypted = await S3EncryptedStorage(storage,
              password: password, bucket: 'bucket')
          .download(path: 'beecount-sync/v3/ledgers/ledger_$ledgerId.json');
      expect(decrypted, contains('Secret Home Ledger'));
    } finally {
      await db.close();
    }
  });

  test('a wrong sync password is rejected before anything is uploaded', () async {
    final storage = _MemoryStorage();
    CloudServiceConfig configWith(String password) => CloudServiceConfig(
        type: CloudBackendType.s3Collaboration,
        name: 'test',
        s3Endpoint: 'example.test',
        s3Bucket: 'bucket',
        s3AccessKey: 'key',
        s3SecretKey: 'secret',
        s3SyncPassword: password);
    final dbA = BeeDatabase.forTesting(NativeDatabase.memory());
    final dbB = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final ledgerA = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      await dbA.into(dbA.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerA,
          type: 'expense',
          amount: 12,
          syncId: const Value('transaction-1')));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'A'});
      await S3IncrementalSyncManager(
              config: configWith('correct horse battery staple'),
              db: dbA,
              repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
              provider: _MemoryProvider(storage))
          .syncIncremental(ledgerId: ledgerA);
      final snapshot = Map<String, String>.from(storage.objects);

      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      await dbB.into(dbB.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerB,
          type: 'expense',
          amount: 34,
          syncId: const Value('transaction-2')));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'B'});
      final wrong = S3IncrementalSyncManager(
          config: configWith('definitely not the same password'),
          db: dbB,
          repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
          provider: _MemoryProvider(storage));
      await expectLater(wrong.syncIncremental(ledgerId: ledgerB),
          throwsA(isA<S3SyncPasswordMismatch>()));
      await expectLater(
          wrong.getRemoteLedgers(), throwsA(isA<S3SyncPasswordMismatch>()));
      // 用错口令的设备一个对象都没写进去，云端数据不会变成别人解不开的混合体
      expect(storage.objects, snapshot);
    } finally {
      await dbA.close();
      await dbB.close();
    }
  });

  test('changing the sync password rewraps the key without rewriting data', () async {
    final storage = _MemoryStorage();
    const oldPassword = 'correct horse battery staple';
    const newPassword = 'another horse another staple';
    CloudServiceConfig configWith(String password) => CloudServiceConfig(
        type: CloudBackendType.s3Collaboration,
        name: 'test',
        s3Endpoint: 'example.test',
        s3Bucket: 'bucket',
        s3AccessKey: 'key',
        s3SecretKey: 'secret',
        s3SyncPassword: password);
    final dbA = BeeDatabase.forTesting(NativeDatabase.memory());
    final dbB = BeeDatabase.forTesting(NativeDatabase.memory());
    try {
      final ledgerA = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      await dbA.into(dbA.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerA,
          type: 'expense',
          amount: 12,
          syncId: const Value('transaction-1')));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'A'});
      await S3IncrementalSyncManager(
              config: configWith(oldPassword),
              db: dbA,
              repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
              provider: _MemoryProvider(storage))
          .syncIncremental(ledgerId: ledgerA);
      final before = Map<String, String>.from(storage.objects);

      await S3EncryptedStorage(storage, password: oldPassword, bucket: 'bucket')
          .changePassword(newPassword);

      // 只有密钥封装被重写，账本日志一个字节都没动
      expect(storage.objects[S3EncryptedStorage.keyParamsPath],
          isNot(before[S3EncryptedStorage.keyParamsPath]));
      expect(
          Map<String, String>.from(storage.objects)
            ..remove(S3EncryptedStorage.keyParamsPath),
          Map<String, String>.from(before)
            ..remove(S3EncryptedStorage.keyParamsPath));

      // 新口令照样能把老数据同步下来
      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'B'});
      expect(
          await S3IncrementalSyncManager(
                  config: configWith(newPassword),
                  db: dbB,
                  repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
                  provider: _MemoryProvider(storage))
              .syncIncremental(ledgerId: ledgerB),
          1);
      expect((await dbB.select(dbB.transactions).get()).single.syncId,
          'transaction-1');

      // 旧口令从此失效
      SharedPreferences.setMockInitialValues({'s3_collaboration_device_id': 'C'});
      await expectLater(
          S3IncrementalSyncManager(
                  config: configWith(oldPassword),
                  db: dbA,
                  repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
                  provider: _MemoryProvider(storage))
              .getRemoteLedgers(),
          throwsA(isA<S3SyncPasswordMismatch>()));
    } finally {
      await dbA.close();
      await dbB.close();
    }
  });
}
