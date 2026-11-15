// seed 默认分类契约测试:① 无 (name,kind) 重复 ② 无 fallback(段数错位会
// 让名字 fallback 成 snake_case key)。锁死三语言(简/繁/英)seed 二级分类质量。
//
// 历史坑(均已修,见 #118):
//  1. 英文词内连字符(Part-time / Year-end / Ride-hailing)被 split('-') 拆碎 → 改空格。
//  2. 三语言部分分类缺「父分类名」致段数错位、fallback 成 key → 补父名,对齐
//     「子类数 + 1」段。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/data/seed_service.dart';
import 'package:beecount/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // seed 过程中 logger 会把日志持久化到 SharedPreferences,测试环境需 mock 掉。
  SharedPreferences.setMockInitialValues({});

  const locales = [
    Locale('zh'),
    Locale('zh', 'TW'),
    Locale('en'),
  ];
  // seed 解析失败会 `return key`(snake_case),正常分类名不会是全小写下划线串。
  final fallbackPattern = RegExp(r'^[a-z][a-z_]*$');

  for (final locale in locales) {
    final tag = locale.toLanguageTag();
    test('seed 二级分类无重复、无 fallback [$tag]', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      try {
        await SeedService.createHierarchicalCategories(db, l10n);
        final cats = await db.select(db.categories).get();

        // ① 无 (name,kind) 重复
        final seen = <String>{};
        final dups = <String>[];
        for (final c in cats) {
          if (!seen.add('${c.name}|${c.kind}')) {
            dups.add('${c.name}|${c.kind} (L${c.level})');
          }
        }
        expect(dups, isEmpty, reason: '重复分类: $dups');

        // ② 无 fallback(段数错位会让名字 fallback 成 snake_case key)
        final fallbacks = cats
            .where((c) => fallbackPattern.hasMatch(c.name))
            .map((c) => c.name)
            .toList();
        expect(fallbacks, isEmpty, reason: 'fallback 成 key(段数错位): $fallbacks');
      } finally {
        await db.close();
      }
    });
  }

  test('默认交通分类允许直接记账并包含汽车三级分支', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final hierarchical in [false, true]) {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      try {
        if (hierarchical) {
          await SeedService.createHierarchicalCategories(db, l10n);
        } else {
          await SeedService.createFlatCategories(db, l10n);
        }
        final cats = await db.select(db.categories).get();
        final transport = cats.singleWhere((c) =>
            c.syncId ==
            SeedService.deterministicCategorySyncId(
                kind: 'expense', level: 1, key: 'transport'));
        final car = cats.singleWhere((c) =>
            c.syncId ==
            SeedService.deterministicCategorySyncId(
                kind: 'expense', level: 1, key: 'car'));
        expect(car.parentId, transport.id);
        expect(car.level, 2);
        if (hierarchical) {
          expect(cats.where((c) => c.parentId == car.id), isNotEmpty);
          expect(
              cats
                  .where((c) => c.parentId == car.id)
                  .every((c) => c.level == 3),
              isTrue);
        }
      } finally {
        await db.close();
      }
    }
  });

  test('旧账本的默认交通分类自动归入交通，保留 ID 和账目', () async {
    final db = BeeDatabase.forTesting(NativeDatabase.memory());
    final repo = LocalRepository(db);
    try {
      final transport = await repo.createCategory(
          name: '交通',
          kind: 'expense',
          icon: SeedService.getDefaultIcon('transport'));
      final taxi = await repo.createCategory(
          name: '打车',
          kind: 'expense',
          icon: SeedService.getDefaultIcon('taxi'));
      final subway = await repo.createCategory(
          name: '地铁',
          kind: 'expense',
          icon: SeedService.getDefaultIcon('subway'));
      final car = await repo.createCategory(
          name: '汽车', kind: 'expense', icon: SeedService.getDefaultIcon('car'));
      final maintenance = await repo.createSubCategory(
          parentId: car, name: '保养', kind: 'expense');
      final custom = await repo.createCategory(
          name: '我的打车',
          kind: 'expense',
          icon: SeedService.getDefaultIcon('taxi'));
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 30,
              categoryId: d.Value(taxi),
            ),
          );

      expect(await SeedService.nestDefaultCategories(repo), 3);
      expect(await SeedService.nestDefaultCategories(repo), 0);
      for (final id in [taxi, subway, car]) {
        final category = (await repo.getCategoryById(id))!;
        expect(category.parentId, transport);
        expect(category.level, 2);
      }
      expect((await repo.getCategoryById(maintenance))!.level, 3);
      expect((await repo.getCategoryById(maintenance))!.parentId, car);
      expect((await repo.getCategoryById(custom))!.parentId, isNull);
      expect(
          (await (db.select(db.transactions)..where((t) => t.id.equals(txId)))
                  .getSingle())
              .categoryId,
          taxi);
    } finally {
      await db.close();
    }
  });

  test('补充默认分类后，交通细项仍归入交通', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final hierarchical in [false, true]) {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      try {
        await SeedService.addDefaultCategories(
          repository: repo,
          l10n: l10n,
          kind: 'expense',
          hierarchical: hierarchical,
        );
        await SeedService.addDefaultCategories(
          repository: repo,
          l10n: l10n,
          kind: 'income',
          hierarchical: hierarchical,
        );
        final categories = await repo.getAllCategories();
        var checked = 0;
        for (final kind in ['expense', 'income']) {
          final relationships = kind == 'expense'
              ? SeedService.defaultExpenseParentByKey
              : SeedService.defaultIncomeParentByKey;
          for (final entry in relationships.entries) {
            final childSyncId = SeedService.deterministicCategorySyncId(
                kind: kind, level: 1, key: entry.key);
            final parentSyncId = SeedService.deterministicCategorySyncId(
                kind: kind, level: 1, key: entry.value);
            final children =
                categories.where((category) => category.syncId == childSyncId);
            final parents =
                categories.where((category) => category.syncId == parentSyncId);
            if (children.isEmpty || parents.isEmpty) continue;
            expect(children.single.parentId, parents.single.id,
                reason: '$kind ${entry.key} → ${entry.value}');
            expect(children.single.level, 2);
            checked++;
          }
        }
        expect(checked, greaterThan(10));
      } finally {
        await db.close();
      }
    }
  });

  test('新建两种默认分类模式均应用完整层级关系', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final hierarchical in [false, true]) {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      try {
        if (hierarchical) {
          await SeedService.createHierarchicalCategories(db, l10n);
        } else {
          await SeedService.createFlatCategories(db, l10n);
        }
        final repo = LocalRepository(db);
        expect(await SeedService.findDefaultCategoryMoves(repo), isEmpty);
        final all = await repo.getAllCategories();
        final transport = all.singleWhere((category) =>
            category.syncId ==
            SeedService.deterministicCategorySyncId(
                kind: 'expense', level: 1, key: 'transport'));
        final car = all.singleWhere((category) =>
            category.syncId ==
            SeedService.deterministicCategorySyncId(
                kind: 'expense', level: 1, key: 'car'));
        expect(car.parentId, transport.id);
        if (hierarchical) {
          expect(
              all.where((category) => category.parentId == car.id), isNotEmpty);
          expect(
              all
                  .where((category) => category.parentId == car.id)
                  .every((category) => category.level == 3),
              isTrue);
        }
      } finally {
        await db.close();
      }
    }
  });
}
