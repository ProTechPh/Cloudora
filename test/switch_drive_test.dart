import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handy_tdlib/api.dart' as td;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';
import 'package:cloudora/features/setup/data/drive_setup.dart';
import 'package:cloudora/features/transfers/data/transfer_queue.dart';
import 'package:cloudora/infrastructure/database/app_database.dart';
import 'package:cloudora/infrastructure/storage/preferences.dart';
import 'package:cloudora/infrastructure/telegram/telegram_client.dart';
import 'package:cloudora/infrastructure/telegram/telegram_exception.dart';

import 'support/fake_telegram.dart';

const _oldChatId = -200;
const _newChatId = -300;

/// The queue, told to stop everything, without touching a database.
class _Queue extends TransferQueue {
  bool cancelled = false;

  @override
  TransfersState build() => TransfersState.empty;

  @override
  Future<void> cancelAll() async => cancelled = true;
}

class _Telegram extends FakeTelegram {
  final asked = <td.TdFunction>[];

  Iterable<T> askedFor<T>() => asked.whereType<T>();

  @override
  Future<td.TdObject?> answer(td.TdFunction function) async {
    asked.add(function);
    switch (function) {
      case td.GetMe():
        return testUser();
      case td.GetChat(:final chatId):
        return channelChat().copyWith(id: chatId);
      case td.GetSupergroup():
        return ownedSupergroup();
      case td.SearchChatsOnServer() || td.SearchChats():
        return const td.Chats(totalCount: 1, chatIds: [_newChatId]);
      case td.LoadChats():
        throw const TelegramException(404, 'Not Found');
      case td.GetChats():
        return const td.Chats(totalCount: 1, chatIds: [_newChatId]);
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
    support = Directory.systemTemp.createTempSync('switch_drive_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => support.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    support.deleteSync(recursive: true);
  });

  test('switching wipes what the old drive left on this phone', () async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'last_user_id': 1,
      'drive_chat_1': _oldChatId,
      'synced_upto_$_oldChatId': 900,
      'full_sync_$_oldChatId': DateTime(2026, 9, 26).millisecondsSinceEpoch,
    });
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final telegram = _Telegram();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(shared),
        appDatabaseProvider.overrideWithValue(db),
        telegramClientProvider.overrideWithValue(telegram),
        transferQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final queue = container.read(transferQueueProvider.notifier) as _Queue;
    final now = DateTime(2026, 9, 26);
    await db.upsertFolder(
      FoldersCompanion.insert(
        id: 'docs',
        name: 'Docs',
        messageId: 1,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    await db.markAssetBackedUp('photo-1', 'file-1');

    await container.read(driveSetupProvider.notifier).switchTo(_newChatId);

    expect(queue.cancelled, isTrue);
    expect(container.read(driveSessionProvider)!.chatId, _newChatId);
    expect(await db.allFolders(), isEmpty);
    expect(await db.backupAssetMap(), isEmpty);
    expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);

    final prefs = container.read(preferencesProvider);
    expect(prefs.lastFullSync(_oldChatId), isNull);
    expect(prefs.lastFullSync(_newChatId), isNotNull);
  });
}
