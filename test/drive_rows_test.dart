import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloudora/app/theme/app_theme.dart';
import 'package:cloudora/features/backup/data/backup_controller.dart';
import 'package:cloudora/features/drive/data/drive_repository.dart';
import 'package:cloudora/features/drive/data/drive_session.dart';
import 'package:cloudora/features/drive/data/drive_sync.dart';
import 'package:cloudora/features/drive/domain/drive_models.dart';
import 'package:cloudora/features/network/data/mobile_data.dart';
import 'package:cloudora/features/network/data/proxies.dart';
import 'package:cloudora/features/offline/data/offline_sync.dart';
import 'package:cloudora/features/search/data/content_indexer.dart';
import 'package:cloudora/features/settings/data/settings_providers.dart';
import 'package:cloudora/features/settings/presentation/settings_screen.dart';
import 'package:cloudora/infrastructure/storage/device_profile.dart';
import 'package:cloudora/infrastructure/storage/preferences.dart';

import 'support/fake_telegram.dart';

class _Sync extends DriveSync {
  @override
  SyncState build() => const SyncState();
}

class _Backup extends BackupController {
  @override
  BackupState build() => const BackupState(phase: BackupPhase.off);
}

class _Session extends DriveSessionNotifier {
  _Session(this.role);

  final DriveRole role;

  @override
  DriveSession? build() => DriveSession(
    userId: 1,
    chatId: testChatId,
    channelTitle: 'Cloudora',
    firstName: 'A',
    lastName: '',
    phoneNumber: '',
    username: null,
    isPremium: false,
    role: role,
  );
}

class _MobileData extends MobileDataController {
  @override
  MobileDataState build() => MobileDataState(
    metered: false,
    limit: null,
    renewDay: 1,
    periodStart: DateTime(2026, 10),
    periodEnd: DateTime(2026, 11),
  );
}

class _Proxies extends ProxyController {
  @override
  Future<List<ProxyEntry>> build() async => const [];
}

void main() {
  Future<void> pumpSettings(WidgetTester tester, DriveRole role) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final shared = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(400, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(shared),
          deviceProfileProvider.overrideWithValue(
            const DeviceProfile(lowRam: false, memoryClassMb: 256, totalRamBytes: 6 << 30),
          ),
          driveSessionProvider.overrideWith(() => _Session(role)),
          driveSyncProvider.overrideWith(_Sync.new),
          backupControllerProvider.overrideWith(_Backup.new),
          mobileDataProvider.overrideWith(_MobileData.new),
          proxiesProvider.overrideWith(_Proxies.new),
          storageSummaryProvider.overrideWith(
            (ref) => Stream.value(const StorageSummary(totals: [])),
          ),
          trashProvider.overrideWith(
            (ref) => Stream.value(const TrashContents(folders: [], files: [])),
          ),
          offlineUsageProvider.overrideWith((ref) => Stream.value((0, 0))),
          indexedCountProvider.overrideWith((ref) => Stream.value(0)),
          cacheSizeProvider.overrideWith((ref) async => 0),
          notificationsEnabledProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an owner is offered the invite', (tester) async {
    await pumpSettings(tester, DriveRole.owner);
    expect(find.text('Invite people'), findsOneWidget);
    expect(find.text('Switch drive'), findsOneWidget);
  });

  testWidgets('a viewer sees the shared role and no invite', (tester) async {
    await pumpSettings(tester, DriveRole.viewer);
    expect(find.textContaining('Shared drive · viewer'), findsOneWidget);
    expect(find.text('Invite people'), findsNothing);
    expect(find.text('Switch drive'), findsOneWidget);
  });

  testWidgets('a viewer is not offered Private or photo backup', (
    tester,
  ) async {
    await pumpSettings(tester, DriveRole.viewer);
    expect(find.text('Private'), findsNothing);
    expect(find.text('Read-only drive'), findsOneWidget);
  });

  testWidgets('an owner keeps Private', (tester) async {
    await pumpSettings(tester, DriveRole.owner);
    expect(find.text('Private'), findsOneWidget);
  });

  testWidgets('an editor is not offered Private either', (tester) async {
    await pumpSettings(tester, DriveRole.editor);
    expect(find.text('Private'), findsNothing);
  });
}
