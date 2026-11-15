// 分类「跨类型同名」判重契约测试。
//
// 锁死:分类按 (name, kind) 联合唯一 —— 同 kind 内禁止重名,跨 kind 允许同名。

import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/data/repositories/exceptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('分类跨类型同名 (name, kind)', () {
    test('跨 kind 同名分类可共存(收入红包 + 支出红包)', () async {
      final inc = await repo.createCategory(name: '红包', kind: 'income');
      final exp = await repo.createCategory(name: '红包', kind: 'expense');
      expect(inc, isNot(exp));
    });

    test('同 kind 重名抛 DuplicateNameException', () async {
      await repo.createCategory(name: '红包', kind: 'expense');
      expect(
        () => repo.createCategory(name: '红包', kind: 'expense'),
        throwsA(isA<DuplicateNameException>()),
      );
    });

    test('isCategoryNameDuplicate 按 (name, kind) 判定', () async {
      await repo.createCategory(name: '红包', kind: 'expense');
      expect(
        await repo.isCategoryNameDuplicate(name: '红包', kind: 'expense'),
        isTrue,
      );
      expect(
        await repo.isCategoryNameDuplicate(name: '红包', kind: 'income'),
        isFalse,
      );
    });

    test('upsertCategory 跨 kind 不误复用、同 kind 复用', () async {
      final a = await repo.upsertCategory(name: '红包', kind: 'income');
      final b = await repo.upsertCategory(name: '红包', kind: 'expense');
      expect(a, isNot(b)); // 跨 kind → 建两个独立分类
      final aAgain = await repo.upsertCategory(name: '红包', kind: 'income');
      expect(aAgain, a); // 同 kind → 复用
    });

    test('createSubCategory 跨 kind 同名子分类可共存', () async {
      final pInc = await repo.createCategory(name: '工资', kind: 'income');
      final pExp = await repo.createCategory(name: '餐饮', kind: 'expense');
      final subInc = await repo.createSubCategory(
          parentId: pInc, name: '红包', kind: 'income');
      final subExp = await repo.createSubCategory(
          parentId: pExp, name: '红包', kind: 'expense');
      expect(subInc, isNot(subExp));
    });

    test(
        'createSubCategory 同 kind 重名抛 DuplicateNameException(二级也按 name+kind 全局唯一)',
        () async {
      final p = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createSubCategory(parentId: p, name: '午餐', kind: 'expense');
      expect(
        () => repo.createSubCategory(parentId: p, name: '午餐', kind: 'expense'),
        throwsA(isA<DuplicateNameException>()),
      );
    });
  });

  test('多级分类移动保留 ID，并更新整棵子树的层级', () async {
    final transport = await repo.createCategory(name: '交通', kind: 'expense');
    final car = await repo.createCategory(name: '汽车', kind: 'expense');
    final maintenance = await repo.createSubCategory(
        parentId: car, name: '保养', kind: 'expense');
    await repo.updateCategory(car, parentId: transport);

    expect((await repo.getCategoryById(car))!.level, 2);
    expect((await repo.getCategoryById(maintenance))!.level, 3);
    expect((await repo.getCategoryById(maintenance))!.parentId, car);
    expect(await repo.getCategoryFullName(maintenance), '交通 / 汽车 / 保养');
    expect((await repo.getSubCategories(car)).single.id, maintenance);

    await expectLater(repo.updateCategory(transport, parentId: maintenance),
        throwsStateError);
    expect((await repo.getCategoryById(transport))!.parentId, isNull);
  });

  test('父分类笔数包含所有后代，父节点自身仍可记账', () async {
    final transport = await repo.createCategory(name: '交通', kind: 'expense');
    final car = await repo.createSubCategory(
        parentId: transport, name: '汽车', kind: 'expense');
    final maintenance = await repo.createSubCategory(
        parentId: car, name: '保养', kind: 'expense');
    for (final categoryId in [transport, maintenance]) {
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 10,
            categoryId: d.Value(categoryId),
          ));
    }
    final counts = await repo.watchCategoriesWithCount().first;
    expect(
        counts.firstWhere((c) => c.category.id == transport).transactionCount,
        2);
    expect(counts.firstWhere((c) => c.category.id == car).transactionCount, 1);
    expect((await repo.watchTransactionsByCategory(transport).first).length, 2);
  });

  test('分类预算包含直接账目和第三级账目', () async {
    final ledgerId =
        await db.into(db.ledgers).insert(LedgersCompanion.insert(name: '测试账本'));
    final transport = await repo.createCategory(name: '交通', kind: 'expense');
    final car = await repo.createSubCategory(
        parentId: transport, name: '汽车', kind: 'expense');
    final maintenance = await repo.createSubCategory(
        parentId: car, name: '保养', kind: 'expense');
    final budgetId = await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: ledgerId,
          amount: 100,
          type: const d.Value('category'),
          categoryId: d.Value(transport),
        ));
    for (final categoryId in [transport, maintenance]) {
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 10,
            categoryId: d.Value(categoryId),
          ));
    }
    final usage = await repo.getBudgetUsage(budgetId, DateTime.now());
    expect(usage.used, 20);
  });

  test('迁移分类时整棵子树保留关系并更新层级', () async {
    final source = await repo.createCategory(name: '旧交通', kind: 'expense');
    final target = await repo.createCategory(name: '交通', kind: 'expense');
    final car = await repo.createSubCategory(
        parentId: source, name: '汽车', kind: 'expense');
    final maintenance = await repo.createSubCategory(
        parentId: car, name: '保养', kind: 'expense');
    final repair = await repo.createSubCategory(
        parentId: maintenance, name: '维修', kind: 'expense');
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 10,
          categoryId: d.Value(source),
        ));
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 20,
          categoryId: d.Value(repair),
        ));

    final result = await repo.migrateCategoryTransactions(
        fromCategoryId: source, toCategoryId: target);
    expect(result.migratedTransactions, 1);
    expect(result.migratedSubCategories, 1);
    expect((await repo.getCategoryById(car))!.parentId, target);
    expect((await repo.getCategoryById(repair))!.level, 4);
    expect(await repo.getCategoryFullName(repair), '交通 / 汽车 / 保养 / 维修');
    expect((await repo.watchTransactionsByCategory(target).first).length, 2);
    await expectLater(
        repo.migrateCategoryTransactions(
            fromCategoryId: target, toCategoryId: repair),
        throwsStateError);
  });
}
