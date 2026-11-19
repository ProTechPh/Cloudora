import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handy_tdlib/api.dart' as td;

import '../../../app/theme/tokens.dart';
import '../../../core/widgets/common.dart';
import '../../../infrastructure/telegram/telegram_client.dart';
import '../../drive/data/drive_session.dart';
import '../data/drive_setup.dart';

/// How a drive's role reads in a list.
String driveRoleLine(DriveRole role) => switch (role) {
  DriveRole.owner => 'Yours',
  DriveRole.editor => 'Shared drive · editor',
  DriveRole.viewer => 'Shared drive · viewer',
};

/// The drives to choose from, as a list of rows. Used where the choice is
/// about to open one, and under Setup when several were found at once.
class DriveChoiceList extends StatelessWidget {
  const DriveChoiceList({
    super.key,
    required this.options,
    required this.onPick,
  });

  final List<DriveOption> options;
  final ValueChanged<DriveOption> onPick;

  @override
  Widget build(BuildContext context) => ListGroup(
    children: [
      for (final option in options)
        ListTile(
          title: Text(option.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(driveRoleLine(option.role)),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: context.colors.text3,
          ),
          onTap: () => onPick(option),
        ),
    ],
  );
}

/// Opens another drive this account can use, after saying what the switch
/// costs: transfers called off, and the new drive read from the beginning.
Future<void> showDriveSwitchSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Space.s),
        child: FutureBuilder<List<DriveOption>>(
          future: ref.read(driveSetupProvider.notifier).switchableDrives(),
          builder: (_, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(Space.xl),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final options = snapshot.data ?? const <DriveOption>[];
            if (snapshot.hasError || options.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(Space.gutter),
                child: Text(
                  snapshot.hasError
                      ? 'Telegram didn\'t answer. Try again in a moment.'
                      : 'No other drive found. Join the channel in Telegram first, then look again.',
                  style: sheetContext.text.bodyMedium,
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.gutter,
                    Space.m,
                    Space.gutter,
                    Space.s,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Switch drive', style: sheetContext.text.titleMedium),
                      const SizedBox(height: Space.xs),
                      Text(
                        'The files stay in Telegram. This phone reads the new '
                        'drive from the beginning, and transfers still waiting '
                        'are cancelled.',
                        style: sheetContext.text.bodySmall,
                      ),
                    ],
                  ),
                ),
                DriveChoiceList(
                  options: options,
                  onPick: (option) => _confirmSwitch(
                    context,
                    ref,
                    sheetContext,
                    option,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _confirmSwitch(
  BuildContext screen,
  WidgetRef ref,
  BuildContext sheet,
  DriveOption option,
) async {
  final yes = await showDialog<bool>(
    context: sheet,
    builder: (dialog) => AlertDialog(
      title: const Text('Switch to this drive?'),
      content: Text(
        'This phone forgets what it kept for the drive it shows now: '
        'waiting uploads, offline copies and which photos are backed up. '
        'Nothing in Telegram is deleted. "${option.title}" opens next.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Switch'),
        ),
      ],
    ),
  );
  if (yes != true || !sheet.mounted) return;
  Navigator.pop(sheet);
  try {
    await ref.read(driveSetupProvider.notifier).switchTo(option.chatId);
    if (screen.mounted) showSnack(screen, 'Opened ${option.title}');
  } catch (e) {
    if (screen.mounted) showSnack(screen, 'Couldn\'t open that drive. Try again.');
  }
}

/// The owner's way to bring someone in: the invite link, then the two
/// things that happen in Telegram, which Cloudora doesn't do for them.
Future<void> showInviteSheet(
  BuildContext context,
  WidgetRef ref,
  DriveSession session,
) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.gutter),
        child: FutureBuilder<td.ChatInviteLink>(
          future: ref.read(telegramClientProvider).send<td.ChatInviteLink>(
            td.CreateChatInviteLink(
              chatId: session.chatId,
              name: 'Cloudora',
              expirationDate: 0,
              memberLimit: 0,
              createsJoinRequest: false,
            ),
          ),
          builder: (_, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final link = snapshot.data?.inviteLink;
            if (link == null) {
              return Text(
                'Telegram didn\'t make a link. Try again in a moment.',
                style: sheetContext.text.bodyMedium,
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Invite people', style: sheetContext.text.titleMedium),
                const SizedBox(height: Space.m),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Space.m),
                  decoration: BoxDecoration(
                    color: sheetContext.colors.surface2,
                    borderRadius: BorderRadius.circular(Radii.field),
                  ),
                  child: SelectableText(
                    link,
                    style: sheetContext.text.bodySmall,
                  ),
                ),
                const SizedBox(height: Space.m),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: link));
                          if (sheetContext.mounted) {
                            showSnack(sheetContext, 'Link copied');
                          }
                        },
                        child: const Text('Copy link'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.l),
                Text(
                  'Send them the link. They join the channel in Telegram, '
                  'then open Cloudora.',
                  style: sheetContext.text.bodyMedium,
                ),
                const SizedBox(height: Space.s),
                Text(
                  'For them to add and change files, make them an admin in '
                  'Telegram with Post, edit and delete. Otherwise they can '
                  'only look and download.',
                  style: sheetContext.text.bodyMedium,
                ),
                const SizedBox(height: Space.l),
                Text(
                  'If the owner\'s Telegram account goes, the drive goes with it.',
                  style: sheetContext.text.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
