import 'package:beecount/data/db.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup selects an existing ledger when the saved ID is stale', () async {
    SharedPreferences.setMockInitialValues({'current_ledger_id': 1});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
    ]);
    try {
      await db.into(db.ledgers).insert(
            LedgersCompanion.insert(id: const Value(7), name: 'Existing'),
          );

      await container.read(appInitProvider.future);

      expect(container.read(currentLedgerIdProvider), 7);
      expect((await SharedPreferences.getInstance()).getInt('current_ledger_id'),
          7);
    } finally {
      container.dispose();
      await db.close();
    }
  });
}
