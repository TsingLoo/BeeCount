import 'db.dart';

/// Tree operations use parentId as the source of truth. [Category.level] is a
/// cached depth for older consumers and sync payloads.
class CategoryTree {
  CategoryTree(Iterable<Category> categories)
      : byId = {for (final category in categories) category.id: category} {
    for (final category in byId.values) {
      if (category.parentId != null) {
        children.putIfAbsent(category.parentId!, () => []).add(category);
      }
    }
    for (final siblings in children.values) {
      siblings.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }
  }

  final Map<int, Category> byId;
  final Map<int, List<Category>> children = {};

  List<Category> childrenOf(int id) => children[id] ?? const [];

  List<Category> ancestorsOf(int id) {
    final result = <Category>[];
    final seen = <int>{id};
    var parentId = byId[id]?.parentId;
    while (parentId != null && seen.add(parentId)) {
      final parent = byId[parentId];
      if (parent == null) break;
      result.add(parent);
      parentId = parent.parentId;
    }
    return result.reversed.toList();
  }

  List<Category> descendantsOf(int id) {
    final result = <Category>[];
    final seen = <int>{id};
    void visit(int parentId) {
      for (final child in childrenOf(parentId)) {
        if (seen.add(child.id)) {
          result.add(child);
          visit(child.id);
        }
      }
    }

    visit(id);
    return result;
  }

  int rootIdOf(int id) => ancestorsOf(id).firstOrNull?.id ?? id;
}
