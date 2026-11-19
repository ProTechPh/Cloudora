import 'dart:convert';
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
  _Telegram({
    required this.group,
    this.offline = false,
    this.chats = const [testChatId],
    this.missing = false,
    this.noCard = false,
  });

  /// The account's status in the channel, which a test may change as
  /// Telegram would.
  td.Supergroup group;

  /// Every request fails, as on a phone with no connection.
  final bool offline;

  /// The channels the account is in.
  final List<int> chats;

  /// The saved channel no longer answers.
  final bool missing;

  /// The channel answers, but its drive message is gone.
  final bool noCard;
  final asked = <td.TdFunction>[];

  Iterable<T> askedFor<T>() => asked.whereType<T>();

  @override
  Future<td.TdObject?> answer(td.TdFunction function) async {
    asked.add(function);
    if (offline) throw const TelegramException(408, 'Request timeout');
    switch (function) {
      case td.GetMe():
        return testUser();
      case td.GetChat(:final chatId):
        if (missing) throw const TelegramException(400, 'CHAT_ID_INVALID');
        return channelChat().copyWith(id: chatId);
      case td.GetSupergroup():
        return group;
      case td.SearchChatsOnServer() || td.SearchChats():
        return td.Chats(totalCount: chats.length, chatIds: chats);
      case td.LoadChats():
        throw const TelegramException(404, 'Not Found');
      case td.GetChats():
        return td.Chats(totalCount: chats.length, chatIds: chats);
      case td.GetChatPinnedMessage():
        if (noCard) throw const TelegramException(404, 'Not Found');
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
    List<int> chats = const [testChatId],
    bool missing = false,
    bool owned = true,
    bool noCard = false,
  }) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'last_user_id': 1,
      if (saved) 'drive_chat_1': testChatId,
      if (saved) 'drive_owned_$testChatId': owned,
      if (saved)
        'drive_snapshot': jsonEncode(
          const DriveSession(
            userId: 1,
            chatId: testChatId,
            channelTitle: 'Cloudora',
            firstName: 'A',
            lastName: '',
            phoneNumber: '',
            username: null,
            isPremium: false,
            role: DriveRole.viewer,
          ).toJson(),
        ),
      if (saved) 'full_sync_$testChatId': DateTime.now().millisecondsSinceEpoch,
    });
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final telegram = _Telegram(
      group: group,
      offline: offline,
      chats: chats,
      missing: missing,
      noCard: noCard,
    );
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
    expect(telegram.askedFor<td.AddChatToList>(), isNotEmpty);
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

  test('two shared drives ask which one before opening either', () async {
    const otherChatId = -300;
    final (container, _) = await open(
      memberSupergroup(),
      chats: const [otherChatId, testChatId],
    );

    expect(container.read(driveSetupProvider).step, SetupStep.choose);
    expect(container.read(driveSetupProvider).choices, hasLength(2));
    expect(container.read(driveSessionProvider), isNull);
  });

  test('a shared drive that is gone is reported, not replaced', () async {
    final (container, telegram) = await open(
      memberSupergroup(),
      saved: true,
      missing: true,
      owned: false,
    );

    expect(container.read(driveSetupProvider).sharedGone, isTrue);
    expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);
    // The pointer and the fact it was shared stay, for Check again; what
    // this phone kept for it goes, so Home can't show it over the index.
    expect(container.read(preferencesProvider).driveOwned(testChatId), isFalse);
    expect(container.read(driveSnapshotProvider), isNull);
  });

  test('a shared drive whose drive message is gone is reported too', () async {
    final (container, telegram) = await open(
      memberSupergroup(),
      saved: true,
      owned: false,
      noCard: true,
    );

    expect(container.read(driveSetupProvider).sharedGone, isTrue);
    expect(container.read(driveSessionProvider), isNull);
    expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);
  });

  test('a role read again follows Telegram', () async {
    final (container, telegram) = await open(adminSupergroup());

    expect(container.read(driveSessionProvider)!.role, DriveRole.editor);
    telegram.group = memberSupergroup();
    await container.read(driveSetupProvider.notifier).refreshRole();

    expect(container.read(driveSessionProvider)!.role, DriveRole.viewer);
  });
}
