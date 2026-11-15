import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/widgets/category/category_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('父分类可直接记账，展开后可继续选第三级', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LocalRepository(db);
    final transport = await repo.createCategory(name: '交通', kind: 'expense');
    final car = await repo.createSubCategory(
        parentId: transport, name: '汽车', kind: 'expense');
    final maintenance = await repo.createSubCategory(
        parentId: car, name: '保养', kind: 'expense');
    final selected = <int>[];

    await tester.pumpWidget(ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: CategorySelector(
          kind: 'expense',
          onCategorySelected: (category) => selected.add(category.id),
        )),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('交通'));
    expect(selected.last, transport);
    await tester.tap(find.byTooltip('展开子分类').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('汽车'));
    expect(selected.last, car);
    await tester.tap(find.byTooltip('展开子分类').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保养'));
    expect(selected.last, maintenance);
  });
}
