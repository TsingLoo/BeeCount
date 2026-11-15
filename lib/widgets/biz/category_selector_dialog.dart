import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart';
import '../../data/category_tree.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/shared_ledger_providers.dart';
import '../../utils/category_utils.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../category_icon.dart';

/// 分类过滤器回调类型
/// 返回 true 表示该分类可选，返回 false 表示不可选（置灰）
typedef CategoryFilterCallback = Future<bool> Function(Category category);

/// 显示分类选择器
///
/// [type] 分类类型：'income'、'expense' 或 'all'
/// [currentCategoryId] 当前选中的分类ID（用于高亮显示）
/// [includeParentCategories] 是否包含有子分类的一级分类
/// [excludeNames] 排除的分类名称列表
/// [excludeIds] 排除的分类ID列表
/// [showTransactionCount] 是否显示交易笔数
/// [ledgerId] 如果要显示笔数，需要账本ID
/// [expandChildrenByDefault] 是否默认展开二级分类
/// [onlyTopLevel] 是否只显示一级分类（不显示二级分类）
/// [categoryFilter] 自定义过滤器，决定分类是否可选
/// [title] 自定义标题
Future<Category?> showCategorySelector(
  BuildContext context, {
  required String type,
  int? currentCategoryId,
  bool includeParentCategories = false,
  List<String>? excludeNames,
  List<int>? excludeIds,
  bool showTransactionCount = false,
  int? ledgerId,
  bool expandChildrenByDefault = false,
  bool onlyTopLevel = false,
  CategoryFilterCallback? categoryFilter,
  String? title,
}) {
  return showDialog<Category>(
    context: context,
    builder: (context) => CategorySelectorDialog(
      type: type,
      currentCategoryId: currentCategoryId,
      includeParentCategories: includeParentCategories,
      excludeNames: excludeNames,
      excludeIds: excludeIds,
      showTransactionCount: showTransactionCount,
      ledgerId: ledgerId,
      expandChildrenByDefault: expandChildrenByDefault,
      onlyTopLevel: onlyTopLevel,
      categoryFilter: categoryFilter,
      title: title,
    ),
  );
}

class CategorySelectorDialog extends ConsumerStatefulWidget {
  final String type;
  final int? currentCategoryId;
  final bool includeParentCategories;
  final List<String>? excludeNames;
  final List<int>? excludeIds;
  final bool showTransactionCount;
  final int? ledgerId;
  final bool expandChildrenByDefault;
  final bool onlyTopLevel;
  final CategoryFilterCallback? categoryFilter;
  final String? title;

  const CategorySelectorDialog({
    super.key,
    required this.type,
    this.currentCategoryId,
    this.includeParentCategories = false,
    this.excludeNames,
    this.excludeIds,
    this.showTransactionCount = false,
    this.ledgerId,
    this.expandChildrenByDefault = false,
    this.onlyTopLevel = false,
    this.categoryFilter,
    this.title,
  });

  @override
  ConsumerState<CategorySelectorDialog> createState() =>
      _CategorySelectorDialogState();
}

class _CategorySelectorDialogState
    extends ConsumerState<CategorySelectorDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  Map<int, int> _transactionCounts = {};
  Map<int, bool> _categoryFilterResults = {}; // 存储过滤器结果

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchText = _searchController.text.trim().toLowerCase();
      });
    });
    if (widget.showTransactionCount) {
      _loadTransactionCounts();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 加载所有分类
  Future<List<Category>> _loadAllCategories() async {
    final repo = ref.read(repositoryProvider);

    var allCategories = (await repo.getAllCategories())
        .where((c) => c.kind == 'income' || c.kind == 'expense')
        .toList();

    // §7 共享账本 picker 过滤:Editor + 共享账本 → 走 SharedLedger* 表(下游
    // _buildCategoryGroups 仍按 widget.type 二次过滤,所以这里 topLevelOnly=
    // false 返完整集合,父子关系靠 parent_sync_id 派生 synthetic parent_id)。
    if (repo is LocalRepository) {
      final ctx = await repo.db.loadLedgerPickerContext(widget.ledgerId);
      allCategories = await repo.db
          .filterCategoriesForLedger(allCategories, ctx, topLevelOnly: false);
    }
    if (widget.onlyTopLevel) {
      allCategories = allCategories.where((c) => c.parentId == null).toList();
    }

    // 如果有过滤器，计算每个分类的可选状态
    if (widget.categoryFilter != null) {
      final filterResults = <int, bool>{};
      for (final category in allCategories) {
        filterResults[category.id] = await widget.categoryFilter!(category);
      }
      if (mounted) {
        setState(() {
          _categoryFilterResults = filterResults;
        });
      }
    }

    return allCategories;
  }

  /// 加载每个分类的交易笔数
  Future<void> _loadTransactionCounts() async {
    try {
      final repo = ref.read(repositoryProvider);

      // 获取交易（ledgerId 可选，不传则获取所有账本）
      final transactions = await repo
          .transactionsWithCategoryAll(ledgerId: widget.ledgerId)
          .first;

      // 统计每个分类的笔数
      final counts = <int, int>{};
      for (final item in transactions) {
        if (item.category != null) {
          counts[item.category!.id] = (counts[item.category!.id] ?? 0) + 1;
        }
      }

      if (mounted) {
        setState(() {
          _transactionCounts = counts;
        });
      }
    } catch (e) {
      // 忽略错误
    }
  }

  @override
  Widget build(BuildContext context) {
    // §7 共享账本:WS shared_resource_change 推送后 tick bump 触发 rebuild
    // → 下方 FutureBuilder 拿到新 Future 重查 SharedLedgerCategories。
    // 否则 A 改分类名 B 这边 picker 显示旧名,要重启 app。
    ref.watch(sharedResourceRefreshProvider);
    final l10n = AppLocalizations.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      backgroundColor: BeeTokens.scaffoldBackground(context),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: BoxDecoration(
          color: BeeTokens.scaffoldBackground(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // 顶部栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: BeeTokens.surfaceElevated(context),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                border: Border(
                  bottom: BorderSide(
                    color: BeeTokens.divider(context),
                    width: 0.5,
                  ),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title ??
                              (widget.type == 'income'
                                  ? l10n.categoryIncome
                                  : l10n.categoryExpense),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: BeeTokens.textPrimary(context),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(
                          Icons.close,
                          color: BeeTokens.iconPrimary(context),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 搜索框
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: l10n.searchCategoryHint,
                      prefixIcon: Icon(
                        Icons.search,
                        color: BeeTokens.iconTertiary(context),
                      ),
                      suffixIcon: _searchText.isNotEmpty
                          ? IconButton(
                              onPressed: () => _searchController.clear(),
                              icon: Icon(
                                Icons.clear,
                                color: BeeTokens.iconTertiary(context),
                              ),
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: BeeTokens.border(context),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: ref.watch(primaryColorProvider),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      filled: true,
                      fillColor: BeeTokens.surface(context),
                    ),
                  ),
                ],
              ),
            ),
            // 分类列表
            Expanded(
              child: FutureBuilder<List<Category>>(
                future: _loadAllCategories(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final categories = snapshot.data!
                      .where(
                          (c) => widget.type == 'all' || c.kind == widget.type)
                      .where(
                          (c) => !(widget.excludeIds?.contains(c.id) ?? false))
                      .where((c) =>
                          !(widget.excludeNames?.contains(c.name) ?? false))
                      .toList();
                  final tree = CategoryTree(categories);
                  final roots = categories
                      .where((c) =>
                          c.parentId == null ||
                          !tree.byId.containsKey(c.parentId))
                      .toList()
                    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
                  final groups = roots
                      .where((root) =>
                          _searchText.isEmpty ||
                          CategoryUtils.getDisplayName(root.name, context)
                              .toLowerCase()
                              .contains(_searchText) ||
                          tree.descendantsOf(root.id).any((c) =>
                              CategoryUtils.getDisplayName(c.name, context)
                                  .toLowerCase()
                                  .contains(_searchText)))
                      .toList();

                  if (groups.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search_off,
                            size: 64,
                            color: BeeTokens.textTertiary(context),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchText.isNotEmpty
                                ? l10n.searchNoResults
                                : l10n.categoryEmpty,
                            style: TextStyle(
                              color: BeeTokens.textTertiary(context),
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final root = groups[index];
                      return _TreeCategoryRow(
                        key: ValueKey(root.id),
                        category: root,
                        tree: tree,
                        searchText: _searchText,
                        depth: 0,
                        filterResults: _categoryFilterResults,
                        expandByDefault: widget.expandChildrenByDefault,
                        currentCategoryId: widget.currentCategoryId,
                        showTransactionCount: widget.showTransactionCount,
                        transactionCounts: _transactionCounts,
                        primaryColor: ref.watch(primaryColorProvider),
                        onCategorySelected: (category) {
                          Navigator.pop(context, category);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TreeCategoryRow extends StatefulWidget {
  const _TreeCategoryRow(
      {super.key,
      required this.category,
      required this.tree,
      required this.searchText,
      required this.depth,
      required this.filterResults,
      required this.expandByDefault,
      required this.currentCategoryId,
      required this.showTransactionCount,
      required this.transactionCounts,
      required this.primaryColor,
      required this.onCategorySelected});

  final Category category;
  final CategoryTree tree;
  final String searchText;
  final int depth;
  final Map<int, bool> filterResults;
  final bool expandByDefault;
  final int? currentCategoryId;
  final bool showTransactionCount;
  final Map<int, int> transactionCounts;
  final Color primaryColor;
  final ValueChanged<Category> onCategorySelected;

  @override
  State<_TreeCategoryRow> createState() => _TreeCategoryRowState();
}

class _TreeCategoryRowState extends State<_TreeCategoryRow> {
  bool expanded = false;

  @override
  void initState() {
    super.initState();
    expanded = widget.expandByDefault ||
        widget.tree
            .descendantsOf(widget.category.id)
            .any((c) => c.id == widget.currentCategoryId);
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.tree.childrenOf(widget.category.id);
    final searching = widget.searchText.isNotEmpty;
    final visibleChildren = searching
        ? children
            .where((child) =>
                CategoryUtils.getDisplayName(child.name, context)
                    .toLowerCase()
                    .contains(widget.searchText) ||
                widget.tree.descendantsOf(child.id).any((c) =>
                    CategoryUtils.getDisplayName(c.name, context)
                        .toLowerCase()
                        .contains(widget.searchText)))
            .toList()
        : children;
    return Column(children: [
      Padding(
        padding: EdgeInsets.only(left: widget.depth * 16.0),
        child: Row(children: [
          Expanded(
              child: _CategoryTile(
            category: widget.category,
            isSelected: widget.currentCategoryId == widget.category.id,
            showTransactionCount: widget.showTransactionCount,
            transactionCount: widget.transactionCounts[widget.category.id] ?? 0,
            primaryColor: widget.primaryColor,
            isChild: widget.depth > 0,
            isSelectable: widget.filterResults[widget.category.id] ?? true,
            onTap: () => widget.onCategorySelected(widget.category),
          )),
          if (children.isNotEmpty)
            IconButton(
              tooltip: '展开子分类',
              icon: Icon(expanded || searching
                  ? Icons.expand_less
                  : Icons.expand_more),
              onPressed: () => setState(() => expanded = !expanded),
            ),
        ]),
      ),
      if (expanded || searching)
        for (final child in visibleChildren)
          _TreeCategoryRow(
            key: ValueKey(child.id),
            category: child,
            tree: widget.tree,
            searchText: widget.searchText,
            depth: widget.depth + 1,
            filterResults: widget.filterResults,
            expandByDefault: widget.expandByDefault,
            currentCategoryId: widget.currentCategoryId,
            showTransactionCount: widget.showTransactionCount,
            transactionCounts: widget.transactionCounts,
            primaryColor: widget.primaryColor,
            onCategorySelected: widget.onCategorySelected,
          ),
    ]);
  }
}

/// 分类项组件
class _CategoryTile extends StatelessWidget {
  final Category category;
  final bool isSelected;
  final bool showTransactionCount;
  final int transactionCount;
  final Color primaryColor;
  final bool isChild;
  final bool isSelectable;
  final VoidCallback onTap;

  const _CategoryTile({
    required this.category,
    this.isSelected = false,
    required this.showTransactionCount,
    required this.transactionCount,
    required this.primaryColor,
    this.isChild = false,
    this.isSelectable = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 不可选时显示为半透明
    final opacity = !isSelectable ? 0.5 : 1.0;

    return InkWell(
      onTap: isSelectable ? onTap : null,
      child: Opacity(
        opacity: opacity,
        child: Container(
          decoration: BoxDecoration(
            // 选中状态背景色（通栏）
            color: isSelected ? primaryColor.withValues(alpha: 0.08) : null,
            border: Border(
              bottom: BorderSide(
                color: BeeTokens.divider(context),
                width: 0.5,
              ),
            ),
          ),
          child: Padding(
            // 子分类添加左边距，父分类正常边距
            padding: EdgeInsets.fromLTRB(
              isChild ? 56 : 16, // 左边距：子分类56，父分类16
              12,
              16,
              12,
            ),
            child: Row(
              children: [
                // 分类图标
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? primaryColor.withValues(alpha: 0.15)
                        : primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    // 选中状态添加边框
                    border: isSelected
                        ? Border.all(color: primaryColor, width: 1.5)
                        : null,
                  ),
                  child: CategoryIconWidget(
                    category: category,
                    size: 24,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                // 分类名称
                Expanded(
                  child: Text(
                    CategoryUtils.getDisplayName(category.name, context),
                    style: TextStyle(
                      fontSize: isChild ? 15 : 16,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : (isChild ? FontWeight.normal : FontWeight.w500),
                      color: isSelected
                          ? primaryColor
                          : BeeTokens.textPrimary(context),
                    ),
                  ),
                ),
                // 交易笔数
                if (showTransactionCount && transactionCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: BeeTokens.surface(context),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      AppLocalizations.of(context)
                          .tagTransactionCount(transactionCount),
                      style: TextStyle(
                        fontSize: 12,
                        color: BeeTokens.textSecondary(context),
                      ),
                    ),
                  ),
                // 选中图标
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle,
                      color: primaryColor,
                      size: 20,
                    ),
                  ),
                // 展开/收起图标（父分类总是显示）
              ],
            ),
          ),
        ),
      ),
    );
  }
}
