import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app_flutter/main.dart';

void main() {
  testWidgets('SmartCoolingApp loads dashboard properly', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartCoolingApp(autoConnect: false));

    expect(find.text('Smart Cooling & Exhaust'), findsOneWidget);
    expect(find.text('SUHU RUANGAN'), findsOneWidget);
    expect(find.text('KELEMBAPAN'), findsOneWidget);
  });
}
