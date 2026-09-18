import 'package:flutter_test/flutter_test.dart';
import 'package:camera_parent/main.dart';

void main() {
  testWidgets('Camera Parent app test', (WidgetTester tester) async {

    await tester.pumpWidget(
      const CameraParentApp(),
    );

    expect(
      find.byType(CameraParentApp),
      findsOneWidget,
    );

  });
}
