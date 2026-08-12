import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HisabFlow Basic Tests', () {
    test('Basic addition calculation', () {
      expect(2 + 2, 4);
    });

    test('Basic subtraction calculation', () {
      expect(10 - 5, 5);
    });

    test('Basic multiplication calculation', () {
      expect(25 * 4, 100);
    });

    test('Basic division calculation', () {
      expect(100 / 4, 25);
    });

    test('Percentage calculation', () {
      final result = 4000 * 20 / 100;
      expect(result, 800);
    });
  });
}