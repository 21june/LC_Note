import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_listener/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.platformDispatcher.localeTestValue = const Locale('ko');
  });

  tearDown(binding.platformDispatcher.clearLocaleTestValue);

  testWidgets('한국어 외 시스템 언어에서는 영어로 표시된다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    binding.platformDispatcher.localeTestValue = const Locale('en');
    await tester.pumpWidget(const MyListenerApp());

    expect(find.text('What would you like to\nlisten to again?'), findsOneWidget);
    expect(find.text('Changing a Hotel Reservation'), findsWidgets);
    expect(find.text('Playlists'), findsOneWidget);
  });

  testWidgets('핵심 학습 화면이 표시된다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    expect(find.text('오늘은 무엇을\n다시 들어볼까요?'), findsOneWidget);
    expect(find.text('호텔 예약 일정 변경'), findsWidgets);
    expect(find.text('재생목록'), findsOneWidget);
  });

  testWidgets('좁은 화면에서도 플레이어 조작부가 넘치지 않는다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('플레이어'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.repeat_one), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('재생목록을 새로 만들 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('재생목록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '주말 집중 학습');
    await tester.tap(find.text('만들기'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('주말 집중 학습'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('주말 집중 학습'), findsOneWidget);
  });

  testWidgets('클립 관리 메뉴가 실제 동작을 제공한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('클립'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('클립 편집'), findsOneWidget);
    expect(find.text('학습 완료 표시'), findsOneWidget);
    expect(find.text('클립 삭제'), findsOneWidget);
  });

  testWidgets('+5 버튼은 정확히 5초만 이동한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('플레이어'));
    await tester.pumpAndSettle();
    expect(find.text('00:11'), findsOneWidget);
    await tester.tap(find.text('+5'));
    await tester.pump();
    expect(find.text('00:16'), findsOneWidget);
  });

  testWidgets('클립 편집에서 두 가지 구간 지정 방식을 선택할 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('클립'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('클립 만들기'));
    await tester.pumpAndSettle();
    expect(find.text('시간 직접 조정'), findsOneWidget);
    expect(find.text('타임라인 탐색'), findsOneWidget);
    await tester.tap(find.text('타임라인 탐색'));
    await tester.pumpAndSettle();
    expect(find.text('먼저 아래에서 오디오 파일을 선택하세요.'), findsOneWidget);
    expect(find.text('현재 위치 주변 정밀 탐색'), findsOneWidget);
    expect(find.text('15초 확대'), findsOneWidget);
    expect(find.text('30초 확대'), findsOneWidget);
    expect(find.text('60초 확대'), findsOneWidget);
    expect(find.textContaining('현재 위치를 시작으로'), findsOneWidget);
    expect(find.textContaining('현재 위치를 종료로'), findsOneWidget);
  });

  testWidgets('스크립트 없이도 클립을 저장할 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyListenerApp());
    await tester.tap(find.text('클립'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('클립 만들기'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('클립 저장'));
    await tester.pumpAndSettle();
    expect(find.text('새 Conversation'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.textContaining('등록된 스크립트가 없습니다.'), findsOneWidget);
  });
}
