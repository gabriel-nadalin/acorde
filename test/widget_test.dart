import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_application_1/data/repositories.dart';
import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('App launches on the sign-in screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MyApp(auth: AuthController()));

    expect(find.widgetWithText(FilledButton, 'Sign In'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });
}
