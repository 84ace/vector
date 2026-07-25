import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/main.dart';

void main() {
  testWidgets('App renders main shell test', (WidgetTester tester) async {
    await tester.pumpWidget(const VectorC2App());
    expect(find.byType(VectorC2App), findsOneWidget);
  });
}
