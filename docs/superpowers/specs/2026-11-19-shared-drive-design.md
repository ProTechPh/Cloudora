# Shared drive — design

Cloudora, 2026-11-19. Status: awaiting approval.

## Intent and why

A Cloudora drive is one private channel. A family or a small team wants one
place for its photos and files, without everyone handing over the same
Telegram account. Today only the account that created the channel can open
it (`DriveSetup._ownedDriveChannel` requires `ChatMemberStatusCreator`), so
an invited person sees "no drive" and Cloudora creates them their own.

Make the drive shareable: one person creates it, invites the others, and
each signs in with their own Telegram account and sees the same drive. No
new account, no server, nothing to host. This is the one thing the other
Telegram-drive apps don't do, and the format is already ready: per-field
patches, "another device changed this", a copy of the index in the channel.

## Who

| Role | Who in Telegram | Can |
| --- | --- | --- |
| Owner | Created the channel | Everything, including Private, inviting, deleting |
| Editor | Admin with Post, Edit, Delete rights | Everything with files and folders that the owner can, except Private |
| Viewer | Admin without those rights, or a member | Browse, open, play, download, keep offline, send to a chat |

Cloudora invents no roles: they are read from Telegram's own admin rights
(`chatAdministratorRights.canPostMessages`, `canEditMessages`,
`canDeleteMessages`), which existed and are used by `telegram_chats.dart`
already. Rights can change in Telegram at any time, so they are read on
every open and read again when Telegram refuses a write.

## Goals

- An invited person signs in and lands in the shared drive, without setup
  instructions beyond "join the channel in Telegram".
- An editor can add, rename, move, star, trash, restore, make albums, and
  back up photos, and files show it on every phone.
- The owner can invite from the app and understand what the other person
  will be able to do.
- A viewer never sees an action that Telegram will refuse.
- Changing which drive this phone shows is explicit, never silent.

## Non-goals

- A personal drive and a shared drive side by side on one account. One
  account shows one drive; switching replaces it.
- In-app member list, promotion, removal, or join requests. Telegram's own
  screens do that.
- Per-member privacy, per-file permissions, an activity log ("who renamed
  this"), ownership transfer.
- End-to-end encryption, multi-account on one phone, macOS.

## Anti-goals

- Private that looks private but isn't.
- A viewer tapping an action and getting a Telegram error.
- Cloudora joining, leaving, promoting or inviting anyone on its own.
- A first run that silently opens someone else's channel without saying it
  is shared.

## Constraints

- No server. Everything through TDLib, on the account's own credentials.
- The caption format (`tgfile2` etc.) and the SQLite schema stay as they
  are. No migration.
- `DriveSession` is JSON in preferences; the new field needs a default so a
  snapshot written by an older build still opens.
- Captions stay editable by any admin with Edit rights; a channel is
  required because a supergroup with posting members would not let one
  member fix another's caption.
- The owner deleting their Telegram account takes the channel with it.

## Approaches

1. **Shared drive is the drive** (chosen). The channel you already have can
   be shared. One channel per account in the app; joining a different one
   is a switch. Smallest change: role detection, gating, join and switch
   paths. Nothing existing moves.
2. **Personal drive plus a shared drive per account.** Rejected: the
   session, preferences, Home, backup, transfers, Checkup and the router all
   assume one `chatId`; making them plural is a wide refactor and adds a
   second concept to explain before the first one works.
3. **A supergroup instead of a channel.** Rejected: members can only edit
   their own messages, so one person could not rename a file another
   added; the drive needs every editor to fix every caption.

## How it works

### Recognising the drive and the role

`_ownedDriveChannel` becomes `_driveChannel(chatId)`: it still requires a
supergroup channel holding a drive message, and now returns a role:

- `ChatMemberStatusCreator` → owner.
- `Administrator` with all three rights → editor; one missing → viewer.
- `Member` → viewer.

Order on open, so nothing surprising happens:

1. The channel this phone last opened, if it still holds the drive message.
2. A drive this account created (today's search).
3. A shared drive this account can see, only when the account has no own
   drive (a first run for an invited person). The archive scan gains the
   main chat list, capped, so a channel just joined is found. A drive the
   owner renamed is found by scanning; the rest by the `Cloudora` title.
   When two or more shared drives turn up this way, the Choose a drive
   screen opens instead of picking one, so nothing opens by accident.

The choice is per phone, not per account: storing it anywhere else would
need a cloud carrier we don't have. Someone who owns an old channel and
switches to the family drive sees their own drive again after a reinstall
or on another phone, and switches again there. The Switch sheet says so in
one line.

`openExisting` (the background job and backup) accepts any role; it never
searches or creates, as today.

Branding (channel photo, pinned drive message) and creating a missing drive
message run only for the owner. For anyone else those calls are skipped
rather than attempted, since they fail best-effort anyway.

### Joining

- **Owner:** Settings → Drive channel → Invite. A sheet copies the
  channel's invite link and states the two steps: the person joins in
  Telegram, then the owner makes them an admin with Post, Edit and Delete
  in Telegram. A line says what happens to the drive if the owner's
  account goes.
- **Invited person:** joins in Telegram, then opens Cloudora. Setup finds
  the channel by scanning, opens it, archives it in their Telegram list
  like the owner's, and Home names it as shared.
- **Someone who already has their own drive:** Settings → Drive channel →
  Switch drive. A list of channels this account is in where a drive
  message is found, each with its role. Choosing one asks first, then
  clears what this phone kept for the old drive and reads the new channel.
  Their old channel stays in Telegram untouched.

  The clearing is the same drive-local wipe as signing out, without the
  account: cancel any transfer in flight, discard waiting changes, forget
  the old channel's sync points and backup marks, delete offline copies and
  the index, and forget watched folders, recent destinations and the
  takeout ledger (`AppDatabase.clearAll` plus the same prefs; today
  `DriveSetup` clears only the index and would leave backup thinking the
  old photos are up, and queued uploads aimed at old folder ids). It runs
  from the saved channel pointer, not the snapshot, so it also works on a
  phone whose first full read never finished. The confirm names the
  transfers that will be called off.

Joining happens in Telegram, never inside the app: Telegram already owns
invite links, join requests and two-step verification, and copying that is
more code with more ways to be wrong.

### When the drive is gone

Removed from the channel, the drive message deleted, or the owner's
account deleted: today the search falls through and silently creates a
fresh empty drive. That is wrong for someone who deliberately joined
someone else's.

The phone remembers, beside `drive_chat_$userId`, whether that channel was
one it owned. If a channel it didn't own no longer holds the drive
message, setup stops with "This shared drive isn't available anymore" and
two choices: Check again, or Create my own drive. It never creates a
channel on its own in that state. An owner whose drive message was
deleted gets the existing recreation, since only they can make one.

### Gating by role

`DriveSession` gains `role`, defaulting to owner when an older snapshot
doesn't have it. When the role is viewer, hide rather than disable, and
say once why on Settings → Drive channel and in Checkup:

- the + sheet and every upload path (picked files, folder upload, camera,
  scanner, share intake's save);
- rename, move, delete, trash, restore, star, notes, tags in file and
  folder menus;
- new folder, album create, add to album, remove from album;
- Make private and Private itself;
- photo backup and watched folders (their rows say the drive is read-only).

Kept for viewer: browsing, search, opening, playing, previews, keeping
offline, downloading, and sending a file to a chat (a forward, which the
channel allows).

Selecting several files still works for what remains. If Telegram refuses
a write anyway, the existing error shows and the role is read again.

Writes that don't come from a tap are gated the same way, since they are
the ones that would otherwise fail quietly on every member's phone:

- **Viewer:** no index copy, trash purge, forward filing, preview rewriting
  or backup. They only read.
- **Editor:** all of them except the index copy, which only the owner
  writes, so several phones never race one copy message and its pointer.
  An editor's drive still gets a copy whenever the owner opens it.
- **Owner:** everything, as today.

### Private

Private is a folder field, so it hides that folder in every Cloudora that
reads the channel, while Telegram still shows its files to every member.
On a shared drive that promise is weaker than it looks, so:

- The owner keeps Private, with one added line in its sheet: "In a shared
  drive, Private hides these from Cloudora only. Telegram still shows them
  to everyone."
- Editors and viewers get no Private row and no Make private action.
- A folder the owner made private stays out of editors' and viewers'
  index, screens and Android picker as it does today.

### Photo backup

Allowed for the owner and editors, hidden for viewers. Each phone keeps
sending into `Photo backup • <device folder>`; the timeline is where the
family sees everything together. The existing name-and-size check keeps
one photo from going up twice, and now also applies between members. Known
risk: two phones with a different photo of the same name and size are
judged the same. Accepted for v1; a per-phone subfolder is the fix if it
bites.

### Copy and Checkup

- Home's status line and Settings → Drive channel name the channel and the
  role when it isn't the owner's ("Shared drive · editor").
- Checkup's channel finding: owner unchanged; editor "You're an editor of
  a shared drive"; viewer "You can view and download files. Ask the owner
  to make you an editor." An info row, not an error.
- The rest of Checkup's checks (two-step, auto-delete, split files, gaps)
  work unchanged for editors and viewers, but the two fixes that need
  `canChangeInfo` — dropping a public link and changing the auto-delete
  timer — are the owner's alone. Editors and viewers see the finding with
  "Only the owner can change this." No role gains rights beyond Post, Edit
  and Delete.

## Decisions made for you

- One drive per account; a shared drive replaces a personal one in the app.
- The chosen drive is remembered per phone, not per account.
- Switching wipes this phone's whole drive-local state, not just the index.
- A shared drive that disappears is reported, never silently replaced by a
  new one.
- Roles are Telegram's rights, not a permission model of our own.
- Joining is done in Telegram; the app only finds and switches.
- Two or more shared drives and no own drive means a chooser, never an
  arbitrary pick.
- Viewer is a supported role.
- Private is owner-only; no per-member privacy.
- Backup is for owner and editors.
- Only the owner writes the index copy and fixes channel settings.
- No patch for an existing user being invited: the invite is the
  instruction, and Settings names the way in.
- No activity log.

## Left to the builder

- Where the role line and the two drive rows sit in Settings, and the
  wording (plain sentences, per DESIGN.md).
- How Switch drive lists candidates: check each channel for the drive
  message when chosen, not for every row up front.
- The single seam every write goes through for the role check, so a refusal
  and a role re-read live in one place rather than in each action.
- How cancel shows in Transfers on a switch, and whether the confirm is a
  sheet or a dialog.
- Whether the invite sheet is also offered once, right after the drive is
  created. Not required.
- Test seams: a fake `td.Supergroup`/`td.Chat` for role detection, and the
  gating widget tests.
- Whether a viewer's + label becomes "Upload" disabled or disappears; one
  of the two, not both.

## Size and risk

A project: setup, session, preferences, Settings and Checkup screens, role
gating across files, photos, backup and private, a switch flow, tests.
About 10–14 files, no schema migration.

- The owner's account deletion deletes the channel and everyone's drive.
- Telegram rights can be revoked mid-session; the app re-reads on open and
  on refusal.
- Identical name plus size can hide a different photo from backup.
- A member can always read the channel's files in Telegram, Private or not.
- Switching drives costs a full read of the new channel; that is the
  existing replace path, not a new one.
- Being invited while already using Cloudora changes nothing on screen
  until Settings is opened. The owner's message is what points them there.
- A shared drive on a phone that also created an old drive needs the
  switch once per phone.
- An editor can't fix the channel's public link or auto-delete timer; only
  the owner can.
- A new member's first open waits for the owner's phone to have written an
  index copy, or reads the channel in full, which is the same as a new
  phone today.
