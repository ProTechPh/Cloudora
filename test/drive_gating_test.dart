import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloudora/app/theme/app_theme.dart';
import 'package:cloudora/core/files/file_kind.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';
import 'package:cloudora/features/drive/domain/drive_models.dart';
import 'package:cloudora/features/files/presentation/file_actions.dart';
import 'package:cloudora/infrastructure/telegram/telegram_exception.dart';

class _Session extends DriveSessionNotifier {
  _Session(this.role);

  final DriveRole role;

  @override
  DriveSession? build() => DriveSession(
    userId: 1,
    chatId: -100,
    channelTitle: 'Cloudora',
    firstName: 'A',
    lastName: '',
    phoneNumber: '',
    username: null,
    isPremium: false,
    role: role,
  );
}

DriveFile file() {
  final at = DateTime(2026, 9, 26);
  return DriveFile(
    id: 'f1',
    folderId: 'camera',
    name: 'notes.pdf',
    mimeType: 'application/pdf',
    kind: FileKind.document,
    size: 1200,
    createdAt: at,
    modifiedAt: at,
    partCount: 1,
    starred: false,
  );
}

DriveFolder folder() {
  final at = DateTime(2026, 9, 26);
  return DriveFolder(
    id: 'd1',
    parentId: null,
    name: 'Docs',
    createdAt: at,
    modifiedAt: at,
  );
}

void main() {
  Future<void> pumpSheet(WidgetTester tester, DriveRole role) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [driveSessionProvider.overrideWith(() => _Session(role))],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () =>
                      FileActions.showFileSheet(context, ref, file()),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a viewer\'s file sheet offers no writing', (tester) async {
    await pumpSheet(tester, DriveRole.viewer);

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Download to this phone'), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Move to Trash'), findsNothing);
    expect(find.text('Add to Starred'), findsNothing);
  });

  testWidgets('an editor still sees them', (tester) async {
    await pumpSheet(tester, DriveRole.editor);

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move to Trash'), findsOneWidget);
  });

  Future<void> pumpNew(WidgetTester tester, DriveRole role) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [driveSessionProvider.overrideWith(() => _Session(role))],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () => FileActions.showCreateSheet(context, ref),
                  child: const Text('new'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();
  }

  testWidgets('a viewer\'s New button says the drive is read-only', (
    tester,
  ) async {
    await pumpNew(tester, DriveRole.viewer);

    expect(find.textContaining('read-only for you'), findsOneWidget);
    expect(find.text('Upload files'), findsNothing);
  });

  testWidgets('an editor gets the New sheet', (tester) async {
    await pumpNew(tester, DriveRole.editor);

    expect(find.text('Upload files'), findsOneWidget);
  });

  Future<void> pumpFolderSheet(WidgetTester tester, DriveRole role) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [driveSessionProvider.overrideWith(() => _Session(role))],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () =>
                      FileActions.showFolderSheet(context, ref, folder()),
                  child: const Text('open folder'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open folder'));
    await tester.pumpAndSettle();
  }

  testWidgets('an editor cannot move a folder to Private', (tester) async {
    await pumpFolderSheet(tester, DriveRole.editor);

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move to Private'), findsNothing);
  });

  testWidgets('a viewer gets no folder actions at all', (tester) async {
    await pumpFolderSheet(tester, DriveRole.viewer);

    expect(find.text('Rename'), findsNothing);
    expect(find.text('Add to Starred'), findsNothing);
    expect(find.text('Move to Trash'), findsNothing);
  });

  test('a refusal by rights is named, not shown as a raw code', () {
    expect(
      const TelegramException(403, 'CHAT_ADMIN_REQUIRED').needsRights,
      isTrue,
    );
    expect(
      const TelegramException(400, 'MESSAGE_ID_INVALID').needsRights,
      isFalse,
    );
  });
}
