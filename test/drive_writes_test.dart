import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handy_tdlib/api.dart' as td;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';
import 'package:cloudora/features/drive/data/index_copies.dart';
import 'package:cloudora/infrastructure/database/app_database.dart';
import 'package:cloudora/infrastructure/storage/preferences.dart';
import 'package:cloudora/infrastructure/telegram/telegram_client.dart';

import 'support/fake_telegram.dart';

class _Viewer extends DriveSessionNotifier {
  @override
  DriveSession? build() => const DriveSession(
    userId: 1,
    chatId: testChatId,
    channelTitle: 'Cloudora',
    firstName: 'A',
    lastName: '',
    phoneNumber: '',
    username: null,
    isPremium: false,
    role: DriveRole.viewer,
  );
}

class _Telegram extends FakeTelegram {
  final asked = <td.TdFunction>[];

  Iterable<T> askedFor<T>() => asked.whereType<T>();

  @override
  Future<T> send<T extends td.TdObject>(
    td.TdFunction function, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    asked.add(function);
    return super.send(function, timeout: timeout);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('drive_writes_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => support.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    support.deleteSync(recursive: true);
  });

  test('a viewer\'s phone writes no index copy', () async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'drive_card_$testChatId': 50,
      'index_copy_at_$testChatId': DateTime.now()
          .subtract(const Duration(days: 4))
          .millisecondsSinceEpoch,
    });
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final telegram = _Telegram()..messages[50] = driveMessage(50);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(shared),
        appDatabaseProvider.overrideWithValue(db),
        telegramClientProvider.overrideWithValue(telegram),
        driveSessionProvider.overrideWith(_Viewer.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final written = await container
        .read(indexCopiesProvider)
        .writeIfDue(testChatId);

    expect(written, isFalse);
    expect(telegram.askedFor<td.SendMessage>(), isEmpty);
    expect(telegram.askedFor<td.EditMessageMedia>(), isEmpty);
  });
}
