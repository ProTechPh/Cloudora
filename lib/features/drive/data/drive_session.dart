import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/storage/preferences.dart';

/// What this account may do in the drive, read from Telegram's own
/// membership and admin rights rather than kept by Cloudora.
enum DriveRole {
  owner,
  editor,
  viewer;

  bool get isOwner => this == DriveRole.owner;

  /// A viewer writes nothing: no file, folder, album or backup.
  bool get canEdit => this != DriveRole.viewer;
}

/// Something the app writes into the channel. Only an owner writes the
/// index copy; a viewer writes nothing at all.
enum DriveWrite { indexCopy, trashPurge, forwardFiling, previews, backup }

bool mayWrite(DriveRole role, DriveWrite write) => switch (role) {
  DriveRole.owner => true,
  DriveRole.editor => write != DriveWrite.indexCopy,
  DriveRole.viewer => false,
};

/// What a person is told when they try to write to a drive they may only
/// read.
const readOnlyNotice =
    'This drive is read-only for you. Ask the owner to make you an editor.';

/// The signed-in account and the channel its drive lives in. Null until
/// setup has found or created the channel.
@immutable
class DriveSession {
  const DriveSession({
    required this.userId,
    required this.chatId,
    required this.channelTitle,
    required this.firstName,
    required this.lastName,
    required this.phoneNumber,
    required this.username,
    required this.isPremium,
    this.role = DriveRole.owner,
  });

  /// A session saved with [toJson], whose phone number is not known.
  factory DriveSession.fromJson(Map<String, Object?> json) => DriveSession(
    userId: json['userId']! as int,
    chatId: json['chatId']! as int,
    channelTitle: json['channelTitle']! as String,
    firstName: json['firstName']! as String,
    lastName: json['lastName']! as String,
    phoneNumber: '',
    username: json['username'] as String?,
    isPremium: json['isPremium']! as bool,
    // A snapshot written before roles existed was always the owner's.
    role: switch (json['role']) {
      'editor' => DriveRole.editor,
      'viewer' => DriveRole.viewer,
      _ => DriveRole.owner,
    },
  );

  final int userId;
  final int chatId;
  final String channelTitle;
  final String firstName;
  final String lastName;
  final String phoneNumber;
  final String? username;
  final bool isPremium;
  final DriveRole role;

  DriveSession withRole(DriveRole role) => DriveSession(
    userId: userId,
    chatId: chatId,
    channelTitle: channelTitle,
    firstName: firstName,
    lastName: lastName,
    phoneNumber: phoneNumber,
    username: username,
    isPremium: isPremium,
    role: role,
  );

  String get displayName => [firstName, lastName]
      .where((s) => s.trim().isNotEmpty)
      .join(' ')
      .trim();

  bool get isOwner => role.isOwner;

  bool get canEdit => role.canEdit;

  String get initials {
    final parts = displayName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  /// What the phone keeps to show the drive before Telegram answers. The
  /// phone number stays out: it sits unencrypted on the phone, and nothing
  /// shown before Telegram answers needs it.
  Map<String, Object?> toJson() => {
    'userId': userId,
    'chatId': chatId,
    'channelTitle': channelTitle,
    'firstName': firstName,
    'lastName': lastName,
    'username': username,
    'isPremium': isPremium,
    'role': role.name,
  };
}

class DriveSessionNotifier extends Notifier<DriveSession?> {
  @override
  DriveSession? build() => null;

  // ignore: use_setters_to_change_properties
  void open(DriveSession session) => state = session;

  void close() => state = null;
}

final driveSessionProvider =
    NotifierProvider<DriveSessionNotifier, DriveSession?>(
      DriveSessionNotifier.new,
    );

/// The drive as it was last opened on this phone, so a returning person
/// lands on Home from the index while Telegram is still starting. It
/// counts only while it is still true: the account's drive is still that
/// channel, the index has been read from it in full, and Telegram hasn't
/// ended the session since. Anything else is a drive Home can't show yet,
/// and opening it waits for Telegram as it does the first time.
class DriveSnapshotNotifier extends Notifier<DriveSession?> {
  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  DriveSession? build() {
    final saved = ref.watch(preferencesProvider).driveSnapshot;
    if (saved == null) return null;
    try {
      final session = DriveSession.fromJson(
        (jsonDecode(saved) as Map).cast<String, Object?>(),
      );
      return _stands(session) ? session : null;
    } catch (e) {
      debugPrint('[DriveSnapshot] Unreadable: $e');
      return null;
    }
  }

  bool _stands(DriveSession session) =>
      _prefs.driveChatId(session.userId) == session.chatId &&
      _prefs.lastFullSync(session.chatId) != null &&
      _prefs.sessionEndedAt == null;

  /// Keeps [session] for the next start. It shows the drive from then on
  /// only once the index has been read in full, so a first sign-in still
  /// narrates building it.
  Future<void> save(DriveSession session) async {
    await _prefs.setDriveSnapshot(jsonEncode(session.toJson()));
    state = _stands(session) ? session : null;
  }

  Future<void> clear() async {
    state = null;
    await _prefs.clearDriveSnapshot();
  }
}

final driveSnapshotProvider =
    NotifierProvider<DriveSnapshotNotifier, DriveSession?>(
      DriveSnapshotNotifier.new,
    );

/// The account and channel to show: the open session, or until it opens,
/// the one saved when the drive last opened. Its phone number is known
/// only once the session is open.
final visibleSessionProvider = Provider<DriveSession?>(
  (ref) => ref.watch(driveSessionProvider) ?? ref.watch(driveSnapshotProvider),
);

/// Whether this drive may be written to. Before a drive is open nothing is
/// hidden; the shell isn't shown then.
final driveCanEditProvider = Provider<bool>(
  (ref) => ref.watch(visibleSessionProvider)?.canEdit ?? true,
);
