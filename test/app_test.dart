import 'package:biliharbor/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the primary navigation', (tester) async {
    await tester.pumpWidget(const BiliHarborApp());

    expect(find.text('BiliHarbor'), findsOneWidget);
    expect(find.text('新建下载'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
