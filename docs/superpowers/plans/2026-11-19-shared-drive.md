# Shared Drive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Cloudora drive be shared: one owner, editors with Post/Edit/Delete rights, and viewers who can only read, each on their own Telegram account.

**Architecture:** The drive stays one private channel. The role comes from Telegram's own member status and admin rights, is carried in `DriveSession`, and gates the UI and the background writes. Joining happens in Telegram; the app finds the channel, and switching clears the phone's drive-local state first.

**Tech Stack:** Flutter, Riverpod, Drift, TDLib through `handy_tdlib` 2.3.10.

**Spec:** `docs/superpowers/specs/2026-11-19-shared-drive-design.md`

## Global Constraints

- `flutter analyze` and `flutter test` pass before every commit.
- No new dependencies; no Drift schema change, no `build_runner`.
- Captions, the details line and the index copy format stay exactly as they are.
- Copy follows DESIGN.md: plain sentences, no slogans, no dash chains, sentence case.
- One role model only: Telegram's rights. No permission UI of our own.
- Android and iOS both build; no Android-only branch in shared Dart code.

## Review Focus

- A viewer taps a file action after their rights were taken away: no write reaches Telegram, and one plain sentence says why. (Task 5)
- An editor opens Checkup on a public or auto-delete channel: no channel-settings call is made. (Task 9)
- Switching drives while an upload runs: the upload is cancelled and nothing lands in the new channel. (Task 3)
- The channel is deleted or the member is removed while the app is open: "not available yet", never a new empty drive. (Task 4)
- An invited person opens offline: no channel is created, and Retry finds the shared one. (Task 2)
- Two shared drives and no own drive: a chooser opens, and picking one opens only that one. (Task 4)

---

### Task 1: The role on the session

**Files:**
- Modify: `lib/features/drive/data/drive_session.dart`
- Test: `test/drive_role_test.dart` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum DriveRole { owner, editor, viewer }` with `isOwner` and `canEdit`; `DriveSession.role` (default `owner`), `DriveSession.withRole`; `final driveCanEditProvider = Provider<bool>`; `enum DriveWrite` and `bool mayWrite(DriveRole, DriveWrite)`; `DriveRole? roleOf(td.Supergroup)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/drive_role_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';

Map<String, Object?> saved({String? role}) => {
  'userId': 1,
  'chatId': -100,
  'channelTitle': 'Cloudora',
  'firstName': 'A',
  'lastName': '',
  'username': null,
  'isPremium': false,
  if (role != null) 'role': role,
};

void main() {
  test('a drive saved before roles still opens as the owner', () {
    expect(DriveSession.fromJson(saved()).role, DriveRole.owner);
  });

  test('a role survives the saved JSON', () {
    final session = DriveSession.fromJson(saved(role: 'editor'));
    expect(session.role, DriveRole.editor);
    expect(session.toJson()['role'], 'editor');
  });

  test('only a viewer is read-only', () {
    expect(DriveRole.owner.canEdit, isTrue);
    expect(DriveRole.editor.canEdit, isTrue);
    expect(DriveRole.viewer.canEdit, isFalse);
    expect(DriveRole.editor.isOwner, isFalse);
  });

  test('index copies are the owner\'s alone', () {
    expect(mayWrite(DriveRole.owner, DriveWrite.indexCopy), isTrue);
    expect(mayWrite(DriveRole.editor, DriveWrite.indexCopy), isFalse);
    expect(mayWrite(DriveRole.editor, DriveWrite.trashPurge), isTrue);
    expect(mayWrite(DriveRole.viewer, DriveWrite.backup), isFalse);
  });

  test('the provider follows the visible session', () {
    final container = ProviderContainer(
      overrides: [driveSessionProvider.overrideWith(_Viewer.new)],
    );
    addTearDown(container.dispose);
    expect(container.read(driveCanEditProvider), isFalse);
  });
}

class _Viewer extends DriveSessionNotifier {
  @override
  DriveSession? build() => const DriveSession(
    userId: 1, chatId: -100, channelTitle: 'Cloudora',
    firstName: 'A', lastName: '', phoneNumber: '', username: null,
    isPremium: false, role: DriveRole.viewer,
  );
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `flutter test test/drive_role_test.dart`
Expected: FAIL, `DriveRole` isn't defined.

- [ ] **Step 3: Implement**

In `drive_session.dart`: add the enum with `bool get isOwner => this == DriveRole.owner;` and `bool get canEdit => this != DriveRole.viewer;`. Add `final DriveRole role;` with `this.role = DriveRole.owner` in the constructor. In `fromJson`, map `'editor'` and `'viewer'`, anything else to `owner`. In `toJson`, add `'role': role.name`. Add:

```dart
DriveSession withRole(DriveRole role) => DriveSession(
  userId: userId, chatId: chatId, channelTitle: channelTitle,
  firstName: firstName, lastName: lastName, phoneNumber: phoneNumber,
  username: username, isPremium: isPremium, role: role,
);
```

At the end of the file:

```dart
/// Something the app writes into the channel. Only an owner writes the
/// index copy; a viewer writes nothing at all.
enum DriveWrite { indexCopy, trashPurge, forwardFiling, previews, backup }

bool mayWrite(DriveRole role, DriveWrite write) => switch (role) {
  DriveRole.owner => true,
  DriveRole.editor => write != DriveWrite.indexCopy,
  DriveRole.viewer => false,
};

/// Whether this drive may be written to. Before a drive is open nothing is
/// hidden; the shell isn't shown then.
final driveCanEditProvider = Provider<bool>(
  (ref) => ref.watch(visibleSessionProvider)?.canEdit ?? true,
);
```

- [ ] **Step 4: Run it and see it pass**

Run: `flutter test test/drive_role_test.dart && flutter analyze`
Expected: PASS, no analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add lib/features/drive/data/drive_session.dart test/drive_role_test.dart
git commit -m "feat: carry the drive role in the session"
```

---

### Task 2: Setup reads the role

**Files:**
- Modify: `lib/features/setup/data/drive_setup.dart`
- Modify: `test/support/fake_telegram.dart`
- Test: `test/shared_drive_test.dart` (create)

**Interfaces:**
- Consumes: `DriveRole`, `DriveSession.role`.
- Produces: `_roleOf(td.Supergroup) -> DriveRole?`; `_DriveChannel` becomes `({td.Chat chat, td.Message? card, DriveRole role})`.

- [ ] **Step 1: Add the fake supergroups and write the failing test**

In `test/support/fake_telegram.dart`:

```dart
td.ChatAdministratorRights adminRights({required bool canEdit}) => td.ChatAdministratorRights(
  canManageChat: true, canChangeInfo: true, canPostMessages: true,
  canEditMessages: canEdit, canDeleteMessages: canEdit, canInviteUsers: true,
  canRestrictMembers: false, canPinMessages: canEdit, canManageTopics: false,
  canPromoteMembers: false, canManageVideoChats: false, canPostStories: false,
  canEditStories: false, canDeleteStories: false, isAnonymous: false,
);

td.Supergroup adminSupergroup({bool canEdit = true}) => ownedSupergroup().copyWith(
  status: td.ChatMemberStatusAdministrator(
    customTitle: '', canBeEdited: false, rights: adminRights(canEdit: canEdit),
  ),
);

td.Supergroup memberSupergroup() => ownedSupergroup().copyWith(
  status: const td.ChatMemberStatusMember(memberUntilDate: 0),
);
```

`test/shared_drive_test.dart` uses a `_Telegram extends FakeTelegram` like `drive_card_test.dart`'s, answering `GetMe`, `GetChat`, `GetSupergroup` (from the test), `GetChatPinnedMessage` (a drive message), `SearchChatsOnServer`/`SearchChats` (`[testChatId]`), `LoadChats` (404), `AddChatToList`, `PinChatMessage`, and returning null otherwise. Tests:

```dart
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

test('an invited phone that cannot reach Telegram creates nothing', () async {
  final (container, telegram) = await openOffline();
  expect(container.read(driveSetupProvider).error, isNotNull);
  expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);
});
```

The `open(...)` helper mirrors `drive_card_test.dart`: mock `SharedPreferences` with `last_user_id: 1`, an in-memory `AppDatabase`, override `telegramClientProvider`, call `driveSetupProvider.notifier.run()`.

- [ ] **Step 2: Run it and see it fail**

Run: `flutter test test/shared_drive_test.dart`
Expected: FAIL, the session's role is `owner`.

- [ ] **Step 3: Implement**

In `drive_setup.dart`:

```dart
DriveRole? roleOf(td.Supergroup group) => switch (group.status) {
  td.ChatMemberStatusCreator() => DriveRole.owner,
  td.ChatMemberStatusAdministrator(:final rights)
      when rights.canPostMessages && rights.canEditMessages && rights.canDeleteMessages =>
    DriveRole.editor,
  td.ChatMemberStatusAdministrator() || td.ChatMemberStatusMember() => DriveRole.viewer,
  _ => null,
};
```

The file imports `package:handy_tdlib/api.dart` as `td` for this one function. `_ownedDriveChannel` becomes `_driveChannel(int chatId, {required bool requireMark})`; it returns null when `roleOf` is null, and carries the role. `_locateOrCreate` returns `(td.Chat chat, bool created, DriveRole role)`. Pass `role` into both `DriveSession(...)` constructions (setup and `openExisting`). Only `role == DriveRole.owner` may call `_brand`; anyone else gets `(chat: chat, card: null)` and no `_pinDriveMessage`. `openExisting` no longer requires ownership.

- [ ] **Step 4: Run it and see it pass**

Run: `flutter test test/shared_drive_test.dart test/drive_card_test.dart && flutter analyze`
Expected: PASS; the existing drive tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/features/setup/data/drive_setup.dart test/support/fake_telegram.dart test/shared_drive_test.dart
git commit -m "feat: open a drive shared by another account"
```

---

### Task 3: Switch drive

**Files:**
- Modify: `lib/features/auth/data/auth_controller.dart`
- Modify: `lib/features/transfers/data/transfer_queue.dart`
- Modify: `lib/features/setup/data/drive_setup.dart`
- Modify: `lib/features/settings/presentation/settings_screen.dart`
- Modify: `lib/infrastructure/storage/preferences.dart`
- Create: `lib/features/setup/presentation/drive_sheets.dart`
- Test: `test/switch_drive_test.dart` (create), `test/drive_rows_test.dart` (create)

**Interfaces:**
- Consumes: `DriveRole`, `_driveChannel`, `DriveSetup.run`.
- Produces: `AuthController.wipeDriveState()`; `TransferQueue.cancelAll()`; `DriveSetup.switchTo(int chatId)`; `DriveSetup.switchableDrives()` returning `List<DriveOption>`; `typedef DriveOption = ({int chatId, String title, DriveRole role})`; `showInviteSheet`, `showDriveSwitchSheet`; `DriveChoiceList`.

- [ ] **Step 1: Write the failing tests**

`test/switch_drive_test.dart`:

```dart
test('switching wipes what the old drive left on this phone', () async {
  // prefs: drive_chat_1 = old, synced_upto_$old = 900, full_sync_$old set,
  // backup_verified set; db: one folder, one transfer row, one backup asset.
  await container.read(driveSetupProvider.notifier).switchTo(newChatId);

  expect(queue.cancelled, isTrue);
  expect(container.read(driveSessionProvider)!.chatId, newChatId);
  expect(await db.allTransfers(), isEmpty);
  expect(await db.backupAssetMap(), isEmpty);
  expect(await db.allFolders(), isEmpty);
  expect(prefs.lastFullSync(oldChatId), isNull);
  expect(prefs.lastFullSync(newChatId), isNull);
});
```

`queue` is a `_RecordingQueue extends TransferQueue` override whose `build()` returns `const TransfersState()` and whose `cancelAll()` sets a flag. `db` is the in-memory `AppDatabase`.

`test/drive_rows_test.dart` pumps `SettingsScreen` with a viewer session (copy the overrides from `test/settings_save_memory_test.dart`) and asserts:

```dart
expect(find.textContaining('Shared drive · viewer'), findsOneWidget);
expect(find.text('Invite people'), findsNothing);
expect(find.text('Switch drive'), findsOneWidget);
```

and with an owner session: `Invite people` and `Switch drive` both found.

- [ ] **Step 2: Run them and see them fail**

Run: `flutter test test/switch_drive_test.dart test/drive_rows_test.dart`
Expected: FAIL, `switchTo` and the rows don't exist.

- [ ] **Step 3: Implement the drive wipe**

In `auth_controller.dart`, split `wipeDeviceState()` into `wipeDriveState()` (everything from `pendingDeletesProvider.notifier.discardAll()` through the provider invalidations and `_deleteOfflineCopies()`/`deletePdfBlockCache()`) and `wipeDeviceState()` (calls `wipeDriveState()`, then the account-only lines: clear last user, session ended, delete-phone-copy, offline-Wi-Fi, picker off, delete bridge, reset `AuthUiState`). Keep `clearCheckupLastRun`, `clearBackupVerified`, `forgetBackupFullScan`, `forgetBackgroundRun`, recent chats and destinations inside `wipeDriveState`.

- [ ] **Step 4: Implement the queue cancel-all**

In `transfer_queue.dart`, rename the body of `_cancelAll(TransferOrigin origin)` to `_cancelPending(bool Function(TransferRow) which)`; `_cancelAll(origin)` calls it with `(r) => r.origin == origin`. Add:

```dart
/// Stops every pending transfer and drops it from the list, for a switch to
/// another drive where folder ids and files mean nothing.
Future<void> cancelAll() => _cancelPending((_) => true);
```

- [ ] **Step 5: Implement the switch**

In `drive_setup.dart`:

```dart
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

Future<List<DriveOption>> switchableDrives() async {
  await _loadChatList(const td.ChatListMain());
  await _loadChatList(const td.ChatListArchive());
  final ids = <int>{};
  for (final list in const [td.ChatListMain(), td.ChatListArchive()]) {
    try {
      ids.addAll((await _client.send<td.Chats>(
        td.GetChats(chatList: list, limit: 200),
      )).chatIds);
    } catch (e) { debugPrint('[DriveSetup] listing drives: $e'); }
  }
  final out = <DriveOption>[];
  for (final id in ids) {
    final found = await _driveChannel(id, requireMark: true);
    if (found != null) {
      out.add((chatId: id, title: found.chat.title, role: found.role));
    }
  }
  return out;
}
```

- [ ] **Step 6: Implement the sheets and the Settings rows**

`drive_sheets.dart` holds `DriveChoiceList({required List<DriveOption> options, required ValueChanged<DriveOption> onPick})` (rows: title, role line, chevron), `showDriveSwitchSheet(context, ref)` (loads `switchableDrives`, then a list; picking shows a confirm that names the transfers being cancelled, then `switchTo`), and `showInviteSheet(context, ref, session)`:

```dart
final link = await ref.read(telegramClientProvider).send<td.ChatInviteLink>(
  td.CreateChatInviteLink(
    chatId: session.chatId, name: 'Cloudora', expirationDate: 0,
    memberLimit: 0, createsJoinRequest: false,
  ),
);
```

The sheet shows the link with Copy, and two numbered steps in plain sentences: join the channel in Telegram; then the owner makes them an admin with Post, edit and delete (in Telegram). One line says the drive goes if the owner's account goes.

In `settings_screen.dart`, replace the drive-channel tile with a title, a role subtitle (`'Shared drive · editor'` / `'Shared drive · viewer'`, the channel description for an owner), and add `Invite people` (owner only) and `Switch drive` tiles under it. In `home_screen.dart`, the line that names the drive adds the same role when it isn't the owner's.

- [ ] **Step 7: Run the tests**

Run: `flutter test test/switch_drive_test.dart test/drive_rows_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/features/auth/data/auth_controller.dart lib/features/transfers/data/transfer_queue.dart \
  lib/features/setup/data/drive_setup.dart lib/features/setup/presentation/drive_sheets.dart \
  lib/features/settings/presentation/settings_screen.dart lib/infrastructure/storage/preferences.dart \
  test/switch_drive_test.dart test/drive_rows_test.dart
git commit -m "feat: switch between a personal and a shared drive"
```

---

### Task 4: Choosing a drive, and a drive that is gone

**Files:**
- Modify: `lib/features/setup/data/drive_setup.dart`
- Modify: `lib/features/setup/presentation/setup_screen.dart`
- Modify: `lib/infrastructure/storage/preferences.dart`
- Test: `test/shared_drive_test.dart`

**Interfaces:**
- Consumes: `DriveOption`, `switchTo`, `DriveChoiceList`.
- Produces: `Preferences.driveOwned(int chatId)`, `setDriveOwned`, `clearDriveChat(int userId)`; `SetupState.choices`, `SetupState.sharedGone`; `DriveSetup.openChosen(int chatId)`, `createOwnDrive()`.

- [ ] **Step 1: Write the failing tests**

In `test/shared_drive_test.dart`:

```dart
test('two shared drives ask which one before opening either', () async {
  final (container, _) = await openWith(found: [otherChatId, testChatId]);
  expect(container.read(driveSetupProvider).step, SetupStep.choose);
  expect(container.read(driveSetupProvider).choices, hasLength(2));
  expect(container.read(driveSessionProvider), isNull);
});

test('a shared drive that is gone is reported, not replaced', () async {
  // prefs: drive_chat_1 = testChatId, drive_owned_-100 = false; GetChat 404.
  final (container, telegram) = await openGone();
  expect(container.read(driveSetupProvider).sharedGone, isTrue);
  expect(telegram.askedFor<td.CreateNewSupergroupChat>(), isEmpty);
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `flutter test test/shared_drive_test.dart`
Expected: FAIL, `choose`/`sharedGone` don't exist.

- [ ] **Step 3: Implement the owned-first search**

Add `'drive_owned_'` to `_channelKeys` in `preferences.dart` with:

```dart
bool driveOwned(int chatId) => _prefs.getBool('drive_owned_$chatId') ?? true;
Future<void> setDriveOwned(int chatId, bool owned) =>
    _prefs.setBool('drive_owned_$chatId', owned);
Future<void> clearDriveChat(int userId) => _prefs.remove('drive_chat_$userId');
```

In `drive_setup.dart`, keep the saved-pointer step. Then `_findOwned()` (the current title search and archive scan, keeping only `role == owner`) and `_findShared()` (title search plus a scan of the main and archived chat lists, keeping every non-null role, deduplicated). `_locateOrCreate`:

- owned found → return it;
- no owned and one shared → return it;
- no owned and several shared → set `step: SetupStep.choose` and `choices`, return null so `_run` stops without opening anything (make `_locateOrCreate` return `(td.Chat, bool, DriveRole)?` and have `_run` return when it is null);
- none → create as today.

`openChosen(chatId)` calls `switchTo`. `createOwnDrive()` calls `prefs.clearDriveChat(me.id)`, `prefs.forgetChannel(saved)`, then `run()`.

Store `setDriveOwned(chat.id, role == DriveRole.owner)` after resolving the channel. When the saved pointer is present but `_driveChannel` returns null and `driveOwned(saved) == false`, set `sharedGone: true`, step done, and do not create.

- [ ] **Step 4: Implement the screen**

In `setup_screen.dart`: when `state.sharedGone`, title "This shared drive isn't available anymore", a sentence saying the owner may have removed them or the channel is gone, and two buttons: Check again (`run`) and Create my own drive (`createOwnDrive`). When `state.choices.isNotEmpty`, show `DriveChoiceList` with `openChosen`.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/shared_drive_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/features/setup/data/drive_setup.dart lib/features/setup/presentation/setup_screen.dart \
  lib/infrastructure/storage/preferences.dart test/shared_drive_test.dart
git commit -m "feat: choose a shared drive, and report one that is gone"
```

---

### Task 5: Gate file and folder actions

**Files:**
- Modify: `lib/infrastructure/telegram/telegram_exception.dart`
- Modify: `lib/features/setup/data/drive_setup.dart`
- Modify: `lib/features/files/presentation/file_actions.dart`
- Modify: `lib/features/files/presentation/file_selection_bar.dart`
- Test: `test/drive_gating_test.dart` (create)

**Interfaces:**
- Consumes: `driveCanEditProvider`, `DriveSession.withRole`, `_roleOf`.
- Produces: `TelegramException.needsRights`; `DriveSetup.refreshRole()`; `_guard(..., WidgetRef? ref)`.

- [ ] **Step 1: Write the failing tests**

```dart
test('a viewer\'s file sheet offers no writing', () async {
  await pumpSheet(tester, role: DriveRole.viewer);
  expect(find.text('Open'), findsOneWidget);
  expect(find.text('Download to this phone'), findsOneWidget);
  expect(find.text('Rename'), findsNothing);
  expect(find.text('Move to Trash'), findsNothing);
  expect(find.text('Add to Starred'), findsNothing);
});

test('an editor still sees them', () async {
  await pumpSheet(tester, role: DriveRole.editor);
  expect(find.text('Rename'), findsOneWidget);
});

test('a refusal by rights is named, not shown as a raw code', () {
  expect(const TelegramException(403, 'CHAT_ADMIN_REQUIRED').needsRights, isTrue);
  expect(const TelegramException(400, 'MESSAGE_ID_INVALID').needsRights, isFalse);
});

test('a role read again follows Telegram', () async {
  // session opened as editor; GetSupergroup now answers a member.
  await container.read(driveSetupProvider.notifier).refreshRole();
  expect(container.read(driveSessionProvider)!.role, DriveRole.viewer);
});
```

`pumpSheet` builds a `MaterialApp` with a button that calls `FileActions.showFileSheet(context, ref, file)` using a fixture `DriveFile`, and overrides `driveSessionProvider` with a session of the given role.

- [ ] **Step 2: Run them and see them fail**

Run: `flutter test test/drive_gating_test.dart`
Expected: FAIL, `needsRights` and the hidden rows don't exist.

- [ ] **Step 3: Implement the refusal path**

Add to `TelegramException`:

```dart
/// Telegram turned a write down because this account may not make it.
bool get needsRights =>
    code == 403 || message.contains('CHAT_ADMIN_REQUIRED') || message.contains('not enough rights');
```

Add `DriveSetup.refreshRole()`: read the open session, `GetChat` and `GetSupergroup` for it, `_roleOf`, and if it changed, `open(session.withRole(role))` and save the snapshot. Failures are logged and ignored. Read the supergroup id as the codebase already does: `if (chat.type case td.ChatTypeSupergroup(supergroupId: final id))`.

Give `_guard` an optional `WidgetRef? ref`; in the catch, before the generic snack:

```dart
if (e is TelegramException && e.needsRights) {
  unawaited(ref?.read(driveSetupProvider.notifier).refreshRole());
  if (context.mounted) showSnack(context, readOnlyNotice);
  return false;
}
```

`readOnlyNotice` is one constant: `'This drive is read-only for you. Ask the owner to make you an editor.'` Pass `ref` at every `_guard(` call site that already has one.

- [ ] **Step 4: Hide the writing rows**

In `showFileSheet` and the folder sheet, read `final canEdit = ref.read(driveCanEditProvider);` before opening the sheet and wrap Add/Remove Starred, Rename, Move, Move to Trash, and Move to Private in `if (canEdit)`. In `file_selection_bar.dart`, watch the provider and drop Move, Trash and Starring for a viewer; Download and Send stay.

- [ ] **Step 5: Run the tests**

Run: `flutter test test/drive_gating_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/infrastructure/telegram/telegram_exception.dart lib/features/setup/data/drive_setup.dart \
  lib/features/files/presentation/file_actions.dart lib/features/files/presentation/file_selection_bar.dart \
  test/drive_gating_test.dart
git commit -m "feat: hide file actions a viewer cannot make"
```

---

### Task 6: Gate creating, uploading and sharing in

**Files:**
- Modify: `lib/features/files/presentation/file_actions.dart` (the New sheet)
- Modify: `lib/features/home/presentation/home_screen.dart`
- Modify: `lib/features/files/presentation/files_screen.dart`
- Modify: `lib/features/share/presentation/share_sheet.dart`
- Test: `test/drive_gating_test.dart`

**Interfaces:**
- Consumes: `driveCanEditProvider`.
- Produces: the read-only sentence shown instead of the New sheet and the share destinations.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('a viewer\'s New button says the drive is read-only', (tester) async {
  await pumpNewButton(tester, role: DriveRole.viewer);
  await tester.tap(find.byTooltip('New'));
  await tester.pumpAndSettle();
  expect(find.textContaining('read-only for you'), findsOneWidget);
  expect(find.text('Upload files'), findsNothing);
});

testWidgets('an editor gets the New sheet', (tester) async {
  await pumpNewButton(tester, role: DriveRole.editor);
  await tester.tap(find.byTooltip('New'));
  await tester.pumpAndSettle();
  expect(find.text('Upload files'), findsOneWidget);
});
```

`pumpNewButton` pumps a `Builder` whose button calls `FileActions.showCreateSheet(context, ref)`.

- [ ] **Step 2: Run it and see it fail**

Run: `flutter test test/drive_gating_test.dart --plain-name "New"`
Expected: FAIL, the sheet opens for a viewer.

- [ ] **Step 3: Implement**

`showCreateSheet` starts with:

```dart
if (!ref.read(driveCanEditProvider)) {
  showSnack(context, readOnlyNotice);
  return Future<void>.value();
}
```

Hide the two FABs (`home_screen.dart:82`, `files_screen.dart:374`) when `!ref.watch(driveCanEditProvider)`, and hide the Files and Home empty-state upload buttons; the Files empty state keeps the sentence and says the drive is read-only instead.

In `share_sheet.dart`, when `!ref.read(driveCanEditProvider)`, show the read-only sentence in place of destinations; Cancel still clears the intake as it does now.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/drive_gating_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/files/presentation/file_actions.dart lib/features/home/presentation/home_screen.dart \
  lib/features/files/presentation/files_screen.dart lib/features/share/presentation/share_sheet.dart \
  test/drive_gating_test.dart
git commit -m "feat: no new files on a drive you can only read"
```

---

### Task 7: Gate backup, watched folders and Private

**Files:**
- Modify: `lib/features/backup/data/backup_controller.dart`
- Modify: `lib/features/backup/presentation/backup_screen.dart`
- Modify: `lib/features/settings/presentation/settings_screen.dart`
- Modify: `lib/features/private/presentation/private_screen.dart`
- Modify: `lib/features/drive/data/drive_session.dart`
- Test: `test/drive_rows_test.dart`

**Interfaces:**
- Consumes: `driveCanEditProvider`, `visibleSessionProvider`.
- Produces: `final driveIsSharedProvider = FutureProvider<bool>`; the Private row only for an owner.

- [ ] **Step 1: Write the failing tests**

In `test/drive_rows_test.dart`, with a viewer session: `expect(find.text('Private'), findsNothing)` and the Photo backup row's subtitle contains `'read-only'`. With an editor session, the Private row is also absent. With an owner, it is present.

- [ ] **Step 2: Run it and see it fail**

Run: `flutter test test/drive_rows_test.dart`
Expected: FAIL, the row shows for everyone.

- [ ] **Step 3: Implement**

`BackupController.enable()` returns false at its head when `!ref.read(driveCanEditProvider)`. In `backup_screen.dart`, replace the on/off switch with the read-only sentence for a viewer, and hide the "Other folders" (watched folders) row.

In `settings_screen.dart`, wrap the Private tile in `if (session?.isOwner ?? false)`.

`driveIsSharedProvider` reads `GetSupergroup` for the open session and answers `memberCount > 1`; `private_screen.dart` shows one line under the title when it is true: "In a shared drive, Private hides these from Cloudora only. Telegram still shows them to everyone."

- [ ] **Step 4: Run the tests**

Run: `flutter test test/drive_rows_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/backup/data/backup_controller.dart lib/features/backup/presentation/backup_screen.dart \
  lib/features/settings/presentation/settings_screen.dart lib/features/private/presentation/private_screen.dart \
  lib/features/drive/data/drive_session.dart test/drive_rows_test.dart
git commit -m "feat: keep backup and Private to those who may write"
```

---

### Task 8: Gate the writes nobody taps

**Files:**
- Modify: `lib/features/drive/data/index_copies.dart`
- Modify: `lib/features/drive/data/drive_sync.dart`
- Modify: `lib/features/checkup/presentation/checkup_screen.dart` (Make previews entry)
- Test: `test/drive_writes_test.dart` (create)

**Interfaces:**
- Consumes: `mayWrite`, `DriveWrite`, `driveSessionProvider`.
- Produces: the same guards at four call sites.

- [ ] **Step 1: Write the failing test**

```dart
test('a viewer\'s phone writes no index copy', () async {
  // viewer session open; index copy due.
  expect(await container.read(indexCopiesProvider).writeIfDue(testChatId), isFalse);
  expect(telegram.askedFor<td.SendMessage>(), isEmpty);
  expect(telegram.askedFor<td.EditMessageMedia>(), isEmpty);
});
```

Use a `FakeTelegram` subclass that records every function; seed the prefs with a due copy (`index_copy_at_$testChatId` older than three days) and a saved drive card.

- [ ] **Step 2: Run it and see it fail**

Run: `flutter test test/drive_writes_test.dart`
Expected: FAIL, a copy is attempted.

- [ ] **Step 3: Implement**

Where a role is available (`ref.read(driveSessionProvider)?.role`), skip when `!mayWrite(role, write)`:

- `IndexCopies.writeIfDue` → `DriveWrite.indexCopy`, returning false.
- `DriveSync`: `purgeTrash` → `trashPurge`; the forward filer call → `forwardFiling`; the `writeIfDue` call → `indexCopy`.
- The Make previews action and `PreviewMaker.make` → `previews`.
- Backup already gated in Task 7.

No session means the drive is not open, and the call is skipped as it is today.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/drive_writes_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/drive/data/index_copies.dart lib/features/drive/data/drive_sync.dart \
  lib/features/checkup/presentation/checkup_screen.dart test/drive_writes_test.dart
git commit -m "feat: a viewer's phone writes nothing to the channel"
```

---

### Task 9: Checkup knows the role

**Files:**
- Modify: `lib/features/checkup/data/drive_checkup.dart`
- Modify: `lib/features/checkup/presentation/checkup_screen.dart`
- Test: `test/checkup_test.dart`

**Interfaces:**
- Consumes: `DriveRole`, `visibleSessionProvider`, `_roleOf` behavior.
- Produces: `RoleFinding(DriveRole role)` in the report; owner-only fixes.

- [ ] **Step 1: Write the failing test**

In `test/checkup_test.dart`, with a member/administrator supergroup instead of a creator:

```dart
test('an editor is told they share the drive, not told they lost it', () async {
  final report = await runCheckup(adminSupergroup());
  expect(report.findings.whereType<RoleFinding>().single.role, DriveRole.editor);
  expect(report.findings.whereType<ChannelFinding>().single.error, isNull);
});

test('an editor\'s Make private does nothing', () async {
  await checkup.makePrivate(7);
  expect(telegram.askedFor<td.SetSupergroupUsername>(), isEmpty);
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `flutter test test/checkup_test.dart`
Expected: FAIL, `RoleFinding` doesn't exist and the channel reads as unreachable.

- [ ] **Step 3: Implement**

Add `RoleFinding` beside `ChannelFinding`: `const RoleFinding(this.role)`, severity `neutral`, no error. In `_channel`, resolve the role with `roleOf`; a non-creator is no longer `unreachable` — it still checks public link and auto-delete, and the report adds `RoleFinding(role)`. In `checkup_screen.dart`, render it as an info row: editor "You're an editor of a shared drive."; viewer "You can view and download files. Ask the owner to make you an editor." Wrap the `Turn off` and `Make private` fixes in `if (session?.isOwner ?? false)`, and make `turnOffAutoDelete`/`makePrivate` return without a request unless the session is an owner.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/checkup_test.dart && flutter analyze`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/checkup/data/drive_checkup.dart lib/features/checkup/presentation/checkup_screen.dart \
  test/checkup_test.dart
git commit -m "feat: Checkup names the role and keeps channel fixes with the owner"
```

---

### Task 10: Write it down

**Files:**
- Modify: `TECHNICAL.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the finished behavior.
- Produces: documentation only.

- [ ] **Step 1: Update the docs**

Add a "Shared drive" section to `TECHNICAL.md` covering: roles from Telegram rights; joining in Telegram then opening Cloudora; Switch drive and what it clears; the owner-only index copy; Private's weaker promise; backup merging in one timeline; the owner's account deletion taking the channel. Add the new known limits: no prompt when invited while already using Cloudora; the switch is per phone; an editor can't change channel settings; matching name and size can hide a different photo from backup. Add one bullet to README's "What it does": a drive you can share with your family.

- [ ] **Step 2: Verify nothing else broke**

Run: `flutter analyze && flutter test`
Expected: clean and green.

- [ ] **Step 3: Commit**

```bash
git add TECHNICAL.md README.md
git commit -m "docs: how a shared drive works"
```

---

## Self-Review

- Spec coverage: roles (Tasks 1–2), joining (Tasks 2–4), switching and wipe (Task 3), unavailable drive (Task 4), viewer gating across files/photos/backup/private (Tasks 5–7), background writes and owner-only index copy (Task 8), Checkup (Task 9), docs (Task 10).
- Types and names: `DriveRole`, `roleOf`, `DriveOption`, `DriveWrite`, `mayWrite`, `driveCanEditProvider`, `switchTo`, `switchableDrives`, `refreshRole`, `openChosen`, `createOwnDrive`, `driveOwned` are used with the same names in every task that touches them.
- Review Focus tests: rights-revoked refusal (Task 5, `needsRights` + `refreshRole`), Checkup on an editor (Task 9), switch with a live upload (Task 3 `cancelAll` flag), gone drive (Task 4), offline first open (Task 2), two shared drives (Task 4).
- Open for the implementer: exact Settings row placement, the switch confirm's shape, the share sheet's read-only layout, and test helpers for pumping sheets. None changes behavior.
