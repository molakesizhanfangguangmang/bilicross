import 'package:flutter/material.dart';

/// 底部导航的动画样式（存进 `AppSettings.navStyle`）。值与 `core/models.dart`
/// 的 [kNavStyles] 对应，只做 UI 层引用，不另起一份常量。

/// 一组导航目标的最小描述：图标 + 标签。
class NavItem {
  const NavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 底部导航。按 [style] 三选一：
///
/// - `standard`：Material 3 [NavigationBar]，默认观感（零回归）。
/// - `bounce`：选中项图标上弹 + 标签加粗，无背景指示块。
/// - `dock`：胶囊形悬浮底栏，选中项图标放大 + 主色药丸背景。
Widget buildAppNavBar({
  required String style,
  required int selectedIndex,
  required List<NavItem> items,
  required ValueChanged<int> onSelect,
}) {
  switch (style) {
    case 'bounce':
      return _BounceNavBar(
        selectedIndex: selectedIndex,
        items: items,
        onSelect: onSelect,
      );
    case 'dock':
      return _DockNavBar(
        selectedIndex: selectedIndex,
        items: items,
        onSelect: onSelect,
      );
    case 'standard':
    default:
      return NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelect,
        destinations: [
          for (final item in items)
            NavigationDestination(icon: Icon(item.icon), label: item.label),
        ],
      );
  }
}

/// 选中项图标上弹 + 标签加粗，其余与 M3 底栏观感一致。
class _BounceNavBar extends StatelessWidget {
  const _BounceNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
  });

  final int selectedIndex;
  final List<NavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelect,
      indicatorColor: Colors.transparent,
      destinations: [
        for (var i = 0; i < items.length; i++)
          NavigationDestination(
            icon: _BounceIcon(
              selected: i == selectedIndex,
              icon: items[i].icon,
              color: i == selectedIndex
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            label: items[i].label,
          ),
      ],
    );
  }
}

class _BounceIcon extends StatelessWidget {
  const _BounceIcon({
    required this.selected,
    required this.icon,
    required this.color,
  });

  final bool selected;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: selected ? 1.18 : 1.0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      child: Icon(icon, color: color),
    );
  }
}

/// 胶囊形悬浮底栏：整体是一块圆角悬浮面板，选中项图标放大并配主色药丸。
class _DockNavBar extends StatelessWidget {
  const _DockNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
  });

  final int selectedIndex;
  final List<NavItem> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _DockItem(
                    selected: i == selectedIndex,
                    icon: items[i].icon,
                    label: items[i].label,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                icon,
                size: 22,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
