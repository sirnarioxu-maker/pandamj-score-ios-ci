import 'package:flutter_test/flutter_test.dart';
import 'package:pandamj_score/main.dart';

void main() {
  test('normalizes SQLite JSON flags used by the card API', () {
    expect(isActiveFlag(true), isTrue);
    expect(isActiveFlag(1), isTrue);
    expect(isActiveFlag('1'), isTrue);
    expect(isActiveFlag(false), isFalse);
    expect(isActiveFlag(0), isFalse);
    expect(isActiveFlag('0'), isFalse);
  });
  test('ships both score backends', () {
    expect(backends.length, 2);
    expect(backends[0].url, contains('74.82.221.117'));
    expect(backends[1].url, contains('102.134.34.160'));
  });

  testWidgets('renders the native scoring shell', (tester) async {
    await tester.pumpWidget(const ScoreApp());
    await tester.pump();
    expect(find.text('熊猫麻将记分'), findsOneWidget);
  });
}
