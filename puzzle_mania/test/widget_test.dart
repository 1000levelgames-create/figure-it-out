import 'package:flutter_test/flutter_test.dart';

import 'package:puzzle_mania/main.dart';

void main() {
  testWidgets('opens level from menu', (WidgetTester tester) async {
    await tester.pumpWidget(const PuzzleManiaApp());

    expect(find.text('Level 111'), findsOneWidget);
    expect(find.text('Daily Challenge'), findsOneWidget);

    await tester.tap(find.text('Level 111'));
    await tester.pumpAndSettle();

    expect(find.byType(GameScreen), findsOneWidget);
  });
}
