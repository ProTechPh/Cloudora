import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handy_tdlib/api.dart' as td;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../infrastructure/database/app_database.dart';
import '../../../infrastructure/storage/preferences.dart';
import '../../../infrastructure/telegram/telegram_client.dart';
import '../../../infrastructure/telegram/telegram_exception.dart';
import '../../auth/data/auth_controller.dart';
import '../../drive/data/channel_messenger.dart';
import '../../drive/data/drive_session.dart';
import '../../drive/data/drive_sync.dart';
import '../../drive/data/index_copies.dart';
import '../../drive/domain/manifest.dart';
import '../../transfers/data/transfer_queue.dart';

enum SetupStep { account, channel, indexing, choose, done }

@immutable
class SetupState {
  const SetupState({
    this.step = SetupStep.account,
    this.createdChannel = false,
    this.error,
    this.timedOut = false,
    this.choices = const [],
    this.sharedGone = false,
  });

  final SetupStep step;

  /// True when this run made a brand new channel rather than finding one.
  final bool createdChannel;
  final String? error;

  /// The [error] is Telegram not answering in time, which on a network
  /// that blocks Telegram is all there is to see.
  final bool timedOut;

  /// The drives found when there is more than one and no own drive, for
  /// the person to pick from.
  final List<DriveOption> choices;

  /// The shared drive this phone last opened is gone, or no longer this
  /// account's to open. Nothing is created in its place.
  final bool sharedGone;

  SetupState copyWith({
    SetupStep? step,
    bool? createdChannel,
    String? error,
    bool? timedOut,
    bool clearError = false,
    List<DriveOption>? choices,
    bool? sharedGone,
  }) => SetupState(
    step: step ?? this.step,
    createdChannel: createdChannel ?? this.createdChannel,
    error: clearError ? null : (error ?? this.error),
    timedOut: clearError ? false : (timedOut ?? this.timedOut),
    choices: choices ?? this.choices,
    sharedGone: sharedGone ?? this.sharedGone,
  );
}

/// Opens the drive after sign-in: identifies the account, finds its storage
/// channel (or creates one), then builds the local index.
///
/// Finding comes first on purpose. Someone signing in on a new phone, or
/// after a reinstall, gets their existing drive back without doing anything.
/// A channel is the drive when it is one this account created and the drive
/// message ([ManifestCodec.encodeDrive]) is in it, pinned or not.
///
/// The setup screen runs it after sign-in. For someone whose drive this
/// phone has opened before, the drive opener runs it behind Home instead,
/// once Telegram has started, and Home says how it is going.
class DriveSetup extends Notifier<SetupState> {
  static const String channelTitle = 'Cloudora';

  /// The description a new drive channel gets. It is for people only.
  static const String _channelDescription =
      'Storage for the Cloudora app. Every file here is part of your drive, '
      'so deleting or editing these messages changes it.';

  Future<void>? _running;

  /// Set while the person asks for a drive of their own, so the search
  /// doesn't hand them someone else's instead.
  bool _creatingOwn = false;

  TelegramClient get _client => ref.read(telegramClientProvider);
  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  SetupState build() => const SetupState();

  Future<void> run() => _running ??= _run().whenComplete(() => _running = null);

  Future<void> _run() async {
    state = const SetupState();
    try {
      final me = await _client.send<td.User>(const td.GetMe());

      // Another account's drive on this phone goes before this one's
      // opens, so its files never show, not even for a moment.
      final last = _prefs.lastUserId;
      if (last != null && last != me.id) {
        await ref.read(authControllerProvider.notifier).wipeDeviceState();
      }
      await _prefs.setLastUserId(me.id);

      // Read before the channel is looked up, since a channel found anew
      // no longer matches it.
      final snapshot = ref.read(driveSnapshotProvider);
      state = state.copyWith(step: SetupStep.channel);
      final located = await _locateOrCreate(me.id);
      if (located == null) return;
      final (chat, created, role) = located;
      if (snapshot != null && chat.id != snapshot.chatId) {
        // The drive channel was replaced. The index read from the old one
        // goes before the new one is read in full, so the two never mix,
        // and Home stops showing it while that runs.
        await ref.read(driveSnapshotProvider.notifier).clear();
        await ref.read(appDatabaseProvider).clearIndex();
        await _prefs.forgetChannel(snapshot.chatId);
      }
      await _prefs.setDriveChatId(me.id, chat.id);
      await _prefs.setDriveOwned(chat.id, role == DriveRole.owner);

      final session = DriveSession(
        userId: me.id,
        chatId: chat.id,
        channelTitle: chat.title,
        firstName: me.firstName,
        lastName: me.lastName,
        phoneNumber: me.phoneNumber,
        username: me.usernames?.activeUsernames.firstOrNull,
        isPremium: me.isPremium,
        role: role,
      );
      final sync = ref.read(driveSyncProvider.notifier);
      ref.read(driveSessionProvider.notifier).open(session);
      await ref.read(driveSnapshotProvider.notifier).save(session);

      if (_prefs.lastFullSync(chat.id) == null) {
        // First time on this device: build the index before showing an
        // empty-looking drive. A copy of the index in the channel opens it
        // at once, and the full read then runs behind Home, settling what
        // changed since the copy was written.
        state = state.copyWith(step: SetupStep.indexing, createdChannel: created);
        if (!created && await ref.read(indexCopiesProvider).restore(chat.id)) {
          unawaited(sync.syncOnOpen());
        } else {
          await sync.syncOnOpen();
        }
      } else {
        // The index is already here; open straight away and catch up in the
        // background.
        unawaited(sync.syncOnOpen());
      }

      state = state.copyWith(step: SetupStep.done);
    } on TelegramException catch (e) {
      state = state.copyWith(error: e.friendlyMessage, timedOut: e.code == 408);
    } catch (e) {
      debugPrint('[DriveSetup] $e');
      state = state.copyWith(error: 'Something went wrong: $e');
    }
  }

  /// Opens the drive this phone last opened, for the background job, and
  /// catches the index up with an incremental read. It changes nothing in
  /// Telegram: it never searches for a channel, makes one or changes how
  /// one looks. It answers null, opening nothing, unless Telegram's account
  /// is the one whose index this phone holds and the saved channel is still
  /// a channel it created; the saved drive counts only once the index has
  /// been read from it in full, which backup needs.
  Future<DriveSession?> openExisting() async {
    final saved = ref.read(driveSnapshotProvider);
    if (saved == null) return null;
    final me = await _client.send<td.User>(const td.GetMe());
    if (me.id != saved.userId || _prefs.lastUserId != me.id) return null;
    final channel = await _driveChannel(saved.chatId, requireMark: false);
    if (channel == null) return null;
    final session = DriveSession(
      userId: me.id,
      chatId: channel.chat.id,
      channelTitle: channel.chat.title,
      firstName: me.firstName,
      lastName: me.lastName,
      phoneNumber: me.phoneNumber,
      username: me.usernames?.activeUsernames.firstOrNull,
      isPremium: me.isPremium,
      role: channel.role,
    );
    ref.read(driveSessionProvider.notifier).open(session);
    await ref.read(driveSyncProvider.notifier).refresh();
    return session;
  }

  /// Opens another drive on this phone: another channel this account can
  /// use, perhaps one someone else shared. Everything this phone kept for
  /// the old drive goes first, so nothing of it shows in the new one.
  Future<void> switchTo(int chatId) async {
    final me = await _client.send<td.User>(const td.GetMe());
    if (await _driveChannel(chatId, requireMark: true) == null) {
      throw const TelegramException(404, 'DRIVE_NOT_FOUND');
    }
    await ref.read(transferQueueProvider.notifier).cancelAll();
    await ref.read(authControllerProvider.notifier).wipeDriveState();
    await _prefs.forgetChannel(chatId);
    await _prefs.setDriveChatId(me.id, chatId);
    await run();
  }

  /// Every channel this account can open that holds a drive, with the role
  /// it has there. Asked only when someone opens the switch list, since it
  /// looks through the account's channels.
  Future<List<DriveOption>> switchableDrives() async {
    await _loadChatList(const td.ChatListMain());
    await _loadChatList(const td.ChatListArchive());
    final ids = <int>{};
    for (final list in const [td.ChatListMain(), td.ChatListArchive()]) {
      try {
        ids.addAll(
          (await _client.send<td.Chats>(
            td.GetChats(chatList: list, limit: 200),
          )).chatIds,
        );
      } catch (e) {
        debugPrint('[DriveSetup] Listing drives: $e');
      }
    }
    final found = <DriveOption>[];
    for (final id in ids) {
      final channel = await _driveChannel(id, requireMark: true);
      if (channel != null) {
        found.add((
          chatId: id,
          title: channel.chat.title,
          role: channel.role,
        ));
      }
    }
    return found;
  }

  /// Opens one of the drives Setup offered when it found several.
  Future<void> openChosen(int chatId) async {
    try {
      await switchTo(chatId);
    } on TelegramException catch (e) {
      state = state.copyWith(error: e.friendlyMessage, timedOut: e.code == 408);
    } catch (e) {
      debugPrint('[DriveSetup] $e');
      state = state.copyWith(error: 'Something went wrong: $e');
    }
  }

  /// Makes a drive of this account's own, leaving someone else's alone.
  Future<void> createOwnDrive() async {
    final me = await _client.send<td.User>(const td.GetMe());
    final saved = _prefs.driveChatId(me.id);
    if (saved != null) {
      await _prefs.forgetChannel(saved);
      await _prefs.clearDriveChatId(me.id);
    }
    _creatingOwn = true;
    try {
      await run();
    } finally {
      _creatingOwn = false;
    }
  }

  Future<(td.Chat, bool, DriveRole)?> _locateOrCreate(int userId) async {
    final saved = _prefs.driveChatId(userId);
    if (saved != null) {
      final channel = await _driveChannel(saved, requireMark: false);
      if (channel != null) {
        return (await _brand(channel), false, channel.role);
      }
      // A drive someone shared that no longer answers is reported rather
      // than quietly replaced by a new, empty one.
      if (!_creatingOwn && !_prefs.driveOwned(saved)) {
        state = state.copyWith(step: SetupStep.done, sharedGone: true);
        return null;
      }
    }

    if (!_creatingOwn) {
      final found = await _searchAll();
      final owned = found
          .where((channel) => channel.role == DriveRole.owner)
          .firstOrNull;
      if (owned != null) return (await _brand(owned), false, owned.role);
      if (found.length == 1) {
        final one = found.single;
        return (await _brand(one), false, one.role);
      }
      if (found.length > 1) {
        state = state.copyWith(
          step: SetupStep.choose,
          choices: [
            for (final channel in found)
              (
                chatId: channel.chat.id,
                title: channel.chat.title,
                role: channel.role,
              ),
          ],
        );
        return null;
      }
    }

    final chat = await _client.send<td.Chat>(
      const td.CreateNewSupergroupChat(
        title: channelTitle,
        isForum: false,
        isChannel: true,
        description: _channelDescription,
        messageAutoDeleteTime: 0,
        forImport: false,
      ),
    );
    // Keep the storage channel out of the way in Telegram's chat list.
    try {
      await _client.send<td.Ok>(
        td.AddChatToList(chatId: chat.id, chatList: const td.ChatListArchive()),
      );
    } catch (e) {
      debugPrint('[DriveSetup] Could not archive the channel: $e');
    }
    return (
      await _brand((chat: chat, card: null, role: DriveRole.owner)),
      true,
      DriveRole.owner,
    );
  }

  /// Brings a channel in line with how Cloudora presents it: the app icon as
  /// its photo, and the drive message pinned at the top. The title and the
  /// description are the owner's to change. Best-effort — none of this is
  /// needed for the drive to work.
  Future<td.Chat> _brand(_DriveChannel channel) async {
    // Someone else's drive keeps its look: its owner decides those.
    if (channel.role != DriveRole.owner) return channel.chat;
    var chat = channel.chat;
    try {
      if (chat.photo == null) {
        await _client.send<td.Ok>(
          td.SetChatPhoto(
            chatId: chat.id,
            photo: td.InputChatPhotoStatic(
              photo: td.InputFileLocal(path: await _channelPhotoFile()),
            ),
          ),
          timeout: const Duration(minutes: 1),
        );
      }
      chat = await _client.send<td.Chat>(td.GetChat(chatId: chat.id));
    } catch (e) {
      debugPrint('[DriveSetup] Could not update the channel\'s look: $e');
    }
    await _pinDriveMessage(chat.id, channel.card);
    return chat;
  }

  /// Makes sure the drive message is pinned in [chatId]: [known] when the
  /// search already met it, else the one this phone last saw, else one
  /// Telegram finds, pinned again if it came unpinned. Only when Telegram
  /// answers that there is none is a new one sent and pinned, so a lookup
  /// that fails never leaves two.
  Future<void> _pinDriveMessage(int chatId, td.Message? known) async {
    try {
      var card = known;
      if (card == null) {
        if (_prefs.driveCardId(chatId) case final savedId?) {
          card = await _messageIfCard(chatId, savedId);
        }
      }
      if (card == null) {
        final found = await _findDriveMessage(chatId);
        if (!found.sure) return;
        card = found.card;
      }
      if (card == null) {
        final manifest = DriveManifest(id: const Uuid().v4(), createdAt: DateTime.now());
        card = await ref
            .read(channelMessengerProvider)
            .sendText(chatId, ManifestCodec.encodeDrive(manifest));
      }
      if (!card.isPinned) {
        await _client.send<td.Ok>(
          td.PinChatMessage(
            chatId: chatId,
            messageId: card.id,
            disableNotification: true,
            onlyForSelf: false,
          ),
        );
      }
      await _prefs.setDriveCardId(chatId, card.id);
    } catch (e) {
      debugPrint('[DriveSetup] Could not pin the drive message: $e');
    }
  }

  /// Message [messageId] of [chatId] if it is still the drive message, null
  /// when it is gone or something else. Any other failure is thrown.
  Future<td.Message?> _messageIfCard(int chatId, int messageId) async {
    try {
      final message = await _client.send<td.Message>(
        td.GetMessage(chatId: chatId, messageId: messageId),
      );
      return _isDriveMessage(message) ? message : null;
    } on TelegramException catch (e) {
      if (e.code == 404 || e.message.contains('MESSAGE_ID_INVALID')) return null;
      rethrow;
    }
  }

  /// The drive message in [chatId]: the message pinned last, or another
  /// pinned one, or failing those one Telegram's search finds by its kind,
  /// should it have come unpinned. [sure] is false when Telegram couldn't
  /// be asked, so a missing message is never assumed.
  Future<({td.Message? card, bool sure})> _findDriveMessage(int chatId) async {
    try {
      final pinned = await _client.send<td.Message>(
        td.GetChatPinnedMessage(chatId: chatId),
      );
      if (_isDriveMessage(pinned)) return (card: pinned, sure: true);
    } on TelegramException catch (e) {
      if (e.code != 404) return (card: null, sure: false);
    } catch (_) {
      return (card: null, sure: false);
    }
    for (final (query, filter) in const [
      ('', td.SearchMessagesFilterPinned()),
      (ManifestCodec.driveKind, null),
    ]) {
      try {
        final found = await _client.send<td.FoundChatMessages>(
          td.SearchChatMessages(
            chatId: chatId,
            query: query,
            fromMessageId: 0,
            offset: 0,
            limit: 50,
            filter: filter,
            messageThreadId: 0,
            savedMessagesTopicId: 0,
          ),
        );
        for (final message in found.messages) {
          if (_isDriveMessage(message)) return (card: message, sure: true);
        }
      } catch (_) {
        return (card: null, sure: false);
      }
    }
    return (card: null, sure: true);
  }

  static bool _isDriveMessage(td.Message message) =>
      message.content is td.MessageText &&
      ManifestCodec.decodeDrive((message.content as td.MessageText).text.text) != null;

  /// The bundled channel photo, copied to disk where TDLib can read it.
  static Future<String> _channelPhotoFile() async {
    final data = await rootBundle.load('assets/brand/channel_photo.jpg');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/cloudora-channel-photo.jpg');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  /// Finds every drive this account can open — the reinstall, new-phone and
  /// shared-drive path.
  ///
  /// A fresh sign-in knows none of the account's chats yet, and the drive
  /// sits in the Archive, so a title search alone can miss it. If it does,
  /// the chat lists are loaded and each channel is checked for the drive
  /// message — which also finds a drive someone renamed, and one someone
  /// else shared.
  Future<List<_DriveChannel>> _searchAll() async {
    final found = <int, _DriveChannel>{};

    Future<void> take(Iterable<int> ids) async {
      for (final id in ids) {
        if (found.containsKey(id)) continue;
        final channel = await _driveChannel(id, requireMark: true);
        if (channel != null) found[id] = channel;
      }
    }

    await take(await _searchByTitle());
    await _loadChatList(const td.ChatListArchive());
    await _loadChatList(const td.ChatListMain());
    await take(await _searchByTitle());

    for (final list in const [td.ChatListMain(), td.ChatListArchive()]) {
      try {
        final chats = await _client.send<td.Chats>(
          td.GetChats(chatList: list, limit: 200),
        );
        await take(chats.chatIds);
      } catch (e) {
        debugPrint('[DriveSetup] Chat list scan failed: $e');
      }
    }
    return found.values.toList();
  }

  /// Pulls a chat list into TDLib, a page at a time, until it is complete
  /// (TDLib answers 404) or [maxPages] pages are in.
  Future<void> _loadChatList(td.ChatList list, {int maxPages = 10}) async {
    for (var page = 0; page < maxPages; page++) {
      try {
        await _client.send<td.Ok>(td.LoadChats(chatList: list, limit: 100));
      } on TelegramException catch (e) {
        if (e.code != 404) debugPrint('[DriveSetup] LoadChats: ${e.message}');
        return;
      }
    }
  }

  Future<List<int>> _searchByTitle() async {
    final candidates = <int>{};
    for (final title in const [channelTitle, 'Cloudora']) {
      for (final request in [
        td.SearchChatsOnServer(query: title, limit: 50),
        td.SearchChats(query: title, limit: 50),
      ]) {
        try {
          candidates.addAll((await _client.send<td.Chats>(request)).chatIds);
        } catch (e) {
          debugPrint('[DriveSetup] ${request.runtimeType} failed: $e');
        }
      }
    }
    return candidates.toList();
  }

  /// [chatId] if it is a channel holding the drive, with the role this
  /// account has in it (and, when searching, one with the drive message in
  /// it).
  Future<_DriveChannel?> _driveChannel(
    int chatId, {
    required bool requireMark,
  }) async {
    try {
      final chat = await _client.send<td.Chat>(td.GetChat(chatId: chatId));
      final type = chat.type;
      if (type is! td.ChatTypeSupergroup || !type.isChannel) return null;

      final supergroup = await _client.send<td.Supergroup>(
        td.GetSupergroup(supergroupId: type.supergroupId),
      );
      final role = roleOf(supergroup);
      if (role == null) return null;
      if (!requireMark) return (chat: chat, card: null, role: role);

      final found = await _findDriveMessage(chat.id);
      if (found.card == null) return null;
      return (chat: chat, card: found.card, role: role);
    } catch (_) {
      return null;
    }
  }
}

/// A channel taken for the drive, with its drive message when looking for
/// the channel already met it, and what this account may do there.
typedef _DriveChannel = ({td.Chat chat, td.Message? card, DriveRole role});

/// A drive this account can open: its channel, its title and the role.
typedef DriveOption = ({int chatId, String title, DriveRole role});

final driveSetupProvider = NotifierProvider<DriveSetup, SetupState>(
  DriveSetup.new,
);
