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
  'role': ?role,
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
    userId: 1,
    chatId: -100,
    channelTitle: 'Cloudora',
    firstName: 'A',
    lastName: '',
    phoneNumber: '',
    username: null,
    isPremium: false,
    role: DriveRole.viewer,
  );
}
