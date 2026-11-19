import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handy_tdlib/api.dart' as td;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';
import 'package:cloudora/features/setup/data/drive_setup.dart';
import 'package:cloudora/infrastructure/database/app_database.dart';
import 'package:cloudora/infrastructure/storage/preferences.dart';
import 'package:cloudora/infrastructure/telegram/telegram_client.dart';
import 'package:cloudora/infrastructure/telegram/telegram_exception.dart';

import 'support/fake_telegram.dart';

/// TDLib for an account in a channel whose status is [group].
class _Telegram extends FakeTelegram {
  _Telegram({required this.group, this.offline = false});

  final td.Supergroup group;

  /// Every request fails, as on a phone with no connection.
  final bool offline;
  final asked = <td.TdFunction>[];

  Iterable<T> askedFor<T>() => asked.whereType<T>();

  @override
  Future<td.TdObject?> answer(td.TdFunction function) async {
    asked.add(function);
    if (offline) throw const TelegramException(408, 'Request timeout');
    switch (function) {
      case td.GetMe():
        return testUser();
      case td.GetChat():
        return channelChat();
      case td.GetSupergroup():
        return group;
      case td.SearchChatsOnServer() || td.SearchChats():
        return const td.Chats(totalCount: 1, chatIds: [testChatId]);
      case td.LoadChats():
        throw const TelegramException(404, 'Not Found');
      case td.GetChats():
        return const td.Chats(totalCount: 1, chatIds: [testChatId]);
      case td.GetChatPinnedMessage():
        return driveMessage(50);
      case td.SearchChatMessages():
        return const td.FoundChatMessages(
          totalCount: 0,
          messages: [],
          nextFromMessageId: 0,
        );
      case td.GetChatHistory():
        return const td.Messages(totalCount: 0, messages: []);
      case td.CreateNewSupergroupChat():
        return channelChat();
      case td.AddChatToList() ||
          td.SetChatPhoto() ||
          td.PinChatMessage() ||
          td.OpenChat():
        return const td.Ok();
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('shared_drive_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => support.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    support.deleteSync(recursive: true);
  });

  Future<(ProviderContainer, _Telegram)> open(
    td.Supergroup group, {
    bool offline = false,
    bool saved = false,
  }) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'last_user_id': 1,
      if (saved) 'drive_chat_1': testChatId,
    });
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final telegram = _Telegram(group: group, offline: offline);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(shared),
        appDatabaseProvider.overrideWithValue(db),
        telegramClientProvider.overrideWithValue(telegram),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await container.read(driveSetupProvider.notifier).run();
    return (container, telegram);
  }

  test('a member opens the owner\'s drive as a viewer', () async {
    final (container, telegram) = await open(memberSupergroup());

    expect(container.read(driveSessionProvider)!.role, DriveRole.viewer);
    expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);
    expect(telegram.askedFor<td.SetChatPhoto>(), isEmpty);
    expect(telegram.askedFor<td.PinChatMessage>(), isEmpty);
  });

  test('an admin with post, edit and delete is an editor', () async {
    final (container, _) = await open(adminSupergroup());
    expect(container.read(driveSessionProvider)!.role, DriveRole.editor);
  });

  test('an admin without edit and delete is a viewer', () async {
    final (container, _) = await open(adminSupergroup(canEdit: false));
    expect(container.read(driveSessionProvider)!.role, DriveRole.viewer);
  });

  test('an invited phone that cannot reach Telegram opens nothing', () async {
    final (container, _) = await open(
      memberSupergroup(),
      offline: true,
      saved: true,
    );
    expect(container.read(driveSetupProvider).error, isNotNull);
    expect(container.read(driveSessionProvider), isNull);
  });
}
