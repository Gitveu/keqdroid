import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/shared/ui/halloween/pumpkin_button.dart';

Widget _button({
  bool connected = false,
  bool connecting = false,
  bool error = false,
  VoidCallback? onTap,
  bool calm = false,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: calm),
        child: Center(
          child: PumpkinConnectButton(
            isConnected: connected,
            isConnecting: connecting,
            isError: error,
            onTap: onTap,
          ),
        ),
      ),
    );

void main() {
  test('у трёх лиц один набор команд — иначе лицо не перетекает, а ломается', () {
    expect(debugPumpkinFacesShareShape(), isTrue);
  });

  testWidgets('нажатие подключает', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_button(onTap: () => taps++));
    await tester.tap(find.byType(PumpkinConnectButton));
    expect(taps, 1);
  });

  testWidgets('без обработчика нажатие ничего не делает', (tester) async {
    // Так выглядит «отключается»: гасить уже нечего.
    await tester.pumpWidget(_button());
    await tester.tap(find.byType(PumpkinConnectButton), warnIfMissed: false);
    await tester.pumpAndSettle();
  });

  for (final calm in [false, true]) {
    testWidgets('весь цикл состояний проходит без ошибок${calm ? ' при уменьшенном движении' : ''}', (tester) async {
      Future<void> go(Widget w, Duration d) async {
        await tester.pumpWidget(w);
        await tester.pump(d);
      }

      await go(_button(calm: calm), const Duration(milliseconds: 100));
      await go(_button(connecting: true, calm: calm), const Duration(seconds: 2));
      await go(_button(connected: true, calm: calm), const Duration(seconds: 3));
      await go(_button(calm: calm), const Duration(milliseconds: 200));
      await go(_button(connecting: true, calm: calm), const Duration(milliseconds: 500));
      await go(_button(error: true, calm: calm), const Duration(seconds: 2));
      await go(_button(connecting: true, calm: calm), const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('спящая и грустная тыква не держат кадры после перехода', (tester) async {
    // Подключение и свеча анимируются бесконечно, а покой — нет: тикер обязан
    // остановиться, иначе неподвижная тыква жгла бы батарею.
    await tester.pumpWidget(_button(connecting: true));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_button());
    await tester.pumpAndSettle();
    await tester.pumpWidget(_button(connecting: true));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_button(error: true));
    await tester.pumpAndSettle();
  });
}
