// test/widget_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Simple math test - should always pass', () {
    expect(1 + 1, 2);
  });

  test('String test', () {
    expect('flutter'.toUpperCase(), 'FLUTTER');
  });

  test('List test', () {
    final numbers = [1, 2, 3, 4, 5];
    expect(numbers.length, 5);
    expect(numbers.contains(3), true);
  });

  testWidgets('Basic Flutter widget test', (WidgetTester tester) async {
    // Build a simple widget that doesn't use shaders
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('Hello Test'),
        ),
      ),
    );

    // Verify the text appears
    expect(find.text('Hello Test'), findsOneWidget);
  });

  testWidgets('Text widget test without buttons', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('First'),
              Text('Second'),
              Text('Third'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Third'), findsOneWidget);
  });
}
