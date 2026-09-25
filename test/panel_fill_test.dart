import 'package:bilicross/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `PanelFill` / `panelColor` 是「非卡片面」（占位框、任务页分组头）底色的
/// **唯一来源**。这里锁住两条红线：
/// - 没有 `PanelFill`、或它的值是 `null` → 这些面**一点底色都不加**
///   （默认态必须与旧版一致，零回归）；
/// - 有值 → 原样用在面上。
void main() {
  ThemeData withFill(Color? fill) => ThemeData(
        extensions: <ThemeExtension<dynamic>>[PanelFill(fill)],
      );

  Future<void> pumpEmpty(WidgetTester tester, ThemeData theme) {
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const EmptyState(
          icon: Icons.inbox_outlined,
          title: 't',
          message: 'm',
        ),
      ),
    );
  }

  Color? emptyFill(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(EmptyState),
            matching: find.byType(Container),
          )
          .first,
    );
    return (container.decoration! as BoxDecoration).color;
  }

  testWidgets('没有 PanelFill 时占位框不上底色', (tester) async {
    await pumpEmpty(tester, ThemeData());
    expect(emptyFill(tester), isNull);
  });

  testWidgets('PanelFill 的值为 null 时占位框不上底色', (tester) async {
    await pumpEmpty(tester, withFill(null));
    expect(emptyFill(tester), isNull);
  });

  testWidgets('PanelFill 有值时占位框用这个底色', (tester) async {
    const fill = Color(0xff123456);
    await pumpEmpty(tester, withFill(fill));
    expect(emptyFill(tester), fill);
  });

  Future<void> pumpBox(WidgetTester tester, ThemeData theme) {
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const PanelBox(
          padding: EdgeInsets.all(12),
          child: SizedBox(height: 20),
        ),
      ),
    );
  }

  BoxDecoration? boxDecoration(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(PanelBox),
            matching: find.byType(Container),
          )
          .first,
    );
    return container.decoration as BoxDecoration?;
  }

  testWidgets('PanelBox 默认态只留内边距、不加底色', (tester) async {
    await pumpBox(tester, ThemeData());
    expect(boxDecoration(tester), isNull);

    await pumpBox(tester, withFill(null));
    expect(boxDecoration(tester), isNull);
  });

  testWidgets('PanelBox 有底色时套上该底色与圆角', (tester) async {
    const fill = Color(0xff123456);
    await pumpBox(tester, withFill(fill));
    final decoration = boxDecoration(tester)!;
    expect(decoration.color, fill);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(8),
    );
  });

  test('copyWith 不传值时保留原值，传值时覆盖', () {
    const fill = Color(0xff123456);
    expect(const PanelFill(fill).copyWith().color, fill);
    expect(const PanelFill(null).copyWith(color: fill).color, fill);
  });

  test('lerp 对端不存在时保持自身', () {
    const fill = Color(0xff123456);
    expect(const PanelFill(fill).lerp(null, 0.5).color, fill);
    expect(const PanelFill(null).lerp(const PanelFill(fill), 1).color, fill);
  });
}
