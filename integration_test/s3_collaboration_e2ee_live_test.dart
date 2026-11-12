// 真机验证 S3 云端协同的端到端加密：PBKDF2/AES-GCM 跑在设备 CPU 和真实 isolate 上,
// 存储层用内存假对象,所以不需要任何真实的 S3 端点或凭证。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/cloud/s3_encrypted_storage.dart';
import 'package:beecount/cloud/s3_incremental_sync_manager.dart';
import 'package:beecount/cloud/sync/change_tracker.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';

class _MemoryStorage implements CloudStorageService {
  final objects = <String, String>{};

  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {
    objects[path] = data;
  }

  @override
  Future<String?> download({required String path}) async => objects[path];

  @override
  Future<bool> exists({required String path}) async =>
      objects.containsKey(path);

  @override
  Future<List<CloudFile>> list({required String path}) async => objects.keys
      .where((key) => key.startsWith(path))
      .map((key) => CloudFile(name: key.split('/').last, path: key))
      .toList();

  @override
  Future<void> delete({required String path}) async {
    objects.remove(path);
  }

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

CloudServiceConfig _configWith(String password) => CloudServiceConfig(
    type: CloudBackendType.s3Collaboration,
    name: 'device',
    s3Endpoint: 'example.test',
    s3Bucket: 'bucket',
    s3AccessKey: 'key',
    s3SecretKey: 'secret',
    s3SyncPassword: password);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const password = 'correct horse battery staple';

  testWidgets('设备上首次启用与解封装的实际耗时', (tester) async {
    final storage = _MemoryStorage();

    final create = Stopwatch()..start();
    await S3EncryptedStorage(storage, password: password, bucket: 'bucket')
        .ensureKey();
    create.stop();

    final unwrap = Stopwatch()..start();
    await S3EncryptedStorage(storage, password: password, bucket: 'bucket')
        .ensureKey();
    unwrap.stop();

    final cold = S3EncryptedStorage(storage,
        password: password, bucket: 'bucket');
    await cold.ensureKey();
    final cached = Stopwatch()..start();
    await cold.ensureKey();
    cached.stop();

    debugPrint('[E2EE] 首次启用(生成DEK+PBKDF2+上传) ${create.elapsedMilliseconds}ms');
    debugPrint('[E2EE] 其他设备解封装(PBKDF2+解包) ${unwrap.elapsedMilliseconds}ms');
    debugPrint('[E2EE] 命中缓存 ${cached.elapsedMicroseconds}us');

    // 真机上 20 万次 PBKDF2 不能慢到让"测试连接"像卡死。天玑 8100 实测约 1s,
    // 阈值留给低端机 3 倍余量;要是有人把 KDF 换回 pointycastle 这里会红。
    expect(unwrap.elapsedMilliseconds, lessThan(3000));
    // 缓存必须生效,否则 30 秒轮询会反复做密钥派生
    expect(cached.elapsedMilliseconds, lessThan(50));
  });

  testWidgets('设备上整条协同链路只把密文交给存储', (tester) async {
    final storage = _MemoryStorage();
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
      SharedPreferences.setMockInitialValues(
          {'s3_collaboration_device_id': 'phone-A'});

      final sync = Stopwatch()..start();
      await S3IncrementalSyncManager(
              config: _configWith(password),
              db: db,
              repo: LocalRepository(db, changeTracker: ChangeTracker(db)),
              provider: _MemoryProvider(storage))
          .syncIncremental(ledgerId: ledgerId);
      sync.stop();
      debugPrint('[E2EE] 首次全量上传 ${sync.elapsedMilliseconds}ms, '
          '${storage.objects.length} 个对象');

      for (final entry in storage.objects.entries) {
        if (entry.key == S3EncryptedStorage.keyParamsPath) {
          final params = jsonDecode(entry.value) as Map<String, dynamic>;
          expect(params['wrappedKey'], isA<String>());
          expect(entry.value, isNot(contains(password)));
          continue;
        }
        final envelope = jsonDecode(entry.value) as Map<String, dynamic>;
        expect(envelope['beecountE2ee'], 1);
        expect(envelope['ciphertext'], isA<String>());
        for (final secret in const [
          'latte-at-midnight',
          'Secret Home Ledger',
          '1234.56',
          'transaction-1',
        ]) {
          expect(entry.value, isNot(contains(secret)));
        }
      }

      final decrypted = await S3EncryptedStorage(storage,
              password: password, bucket: 'bucket')
          .download(path: 'beecount-sync/v3/ledgers/ledger_$ledgerId.json');
      expect(decrypted, contains('Secret Home Ledger'));
    } finally {
      await db.close();
    }
  });

  testWidgets('设备上换口令只重封装密钥,错口令写不进任何东西', (tester) async {
    const newPassword = 'another horse another staple';
    final storage = _MemoryStorage();
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
      SharedPreferences.setMockInitialValues(
          {'s3_collaboration_device_id': 'phone-A'});
      await S3IncrementalSyncManager(
              config: _configWith(password),
              db: dbA,
              repo: LocalRepository(dbA, changeTracker: ChangeTracker(dbA)),
              provider: _MemoryProvider(storage))
          .syncIncremental(ledgerId: ledgerA);
      final before = Map<String, String>.from(storage.objects);

      // 错口令的设备在写任何对象之前就被拦住
      SharedPreferences.setMockInitialValues(
          {'s3_collaboration_device_id': 'phone-X'});
      await expectLater(
          S3IncrementalSyncManager(
                  config: _configWith('definitely not the same password'),
                  db: dbB,
                  repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
                  provider: _MemoryProvider(storage))
              .getRemoteLedgers(),
          throwsA(isA<S3SyncPasswordMismatch>()));
      expect(storage.objects, before);

      final rotate = Stopwatch()..start();
      await S3EncryptedStorage(storage, password: password, bucket: 'bucket')
          .changePassword(newPassword);
      rotate.stop();
      debugPrint('[E2EE] 换口令 ${rotate.elapsedMilliseconds}ms, '
          '改写 1 个对象');

      expect(storage.objects[S3EncryptedStorage.keyParamsPath],
          isNot(before[S3EncryptedStorage.keyParamsPath]));
      expect(
          Map<String, String>.from(storage.objects)
            ..remove(S3EncryptedStorage.keyParamsPath),
          Map<String, String>.from(before)
            ..remove(S3EncryptedStorage.keyParamsPath));

      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(name: 'Home', syncId: const Value('ledger')));
      SharedPreferences.setMockInitialValues(
          {'s3_collaboration_device_id': 'phone-B'});
      expect(
          await S3IncrementalSyncManager(
                  config: _configWith(newPassword),
                  db: dbB,
                  repo: LocalRepository(dbB, changeTracker: ChangeTracker(dbB)),
                  provider: _MemoryProvider(storage))
              .syncIncremental(ledgerId: ledgerB),
          1);
      expect((await dbB.select(dbB.transactions).get()).single.syncId,
          'transaction-1');

      SharedPreferences.setMockInitialValues(
          {'s3_collaboration_device_id': 'phone-C'});
      await expectLater(
          S3EncryptedStorage(storage, password: password, bucket: 'bucket')
              .ensureKey(),
          throwsA(isA<S3SyncPasswordMismatch>()));
    } finally {
      await dbA.close();
      await dbB.close();
    }
  });
}
