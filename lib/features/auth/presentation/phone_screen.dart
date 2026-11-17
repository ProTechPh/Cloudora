import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handy_tdlib/api.dart' as td;

import '../../../app/theme/tokens.dart';
import '../../../infrastructure/telegram/telegram_client.dart';
import '../../../infrastructure/telegram/telegram_exception.dart';
import '../../network/presentation/connection_notice.dart';
import '../data/auth_controller.dart';
import '../domain/country.dart';
import 'auth_layout.dart';
import 'country_picker_sheet.dart';

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _numberController = TextEditingController();
  late Country _country;
  bool _busy = false;
  bool _qrBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _country = Country.defaultCountry();
    _numberController.addListener(_handleNumberInput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detectCountryFromTelegram();
    });
  }

  Future<void> _detectCountryFromTelegram() async {
    try {
      final client = ref.read(telegramClientProvider);
      final res = await client.send<td.Text>(const td.GetCountryCode());
      if (res.text.isNotEmpty && mounted && _numberController.text.isEmpty) {
        final match = Country.findByCode(res.text);
        if (match != null && match.code != _country.code) {
          setState(() => _country = match);
        }
      }
    } catch (_) {
      // Ignore if offline or not supported
    }
  }

  @override
  void dispose() {
    _numberController.removeListener(_handleNumberInput);
    _numberController.dispose();
    super.dispose();
  }

  /// Handles paste with country code or leading zeros.
  void _handleNumberInput() {
    final text = _numberController.text;
    if (text.startsWith('+')) {
      // User pasted full international number e.g. +639123456789
      for (final c in Country.all) {
        if (text.startsWith(c.dialCode)) {
          final national = text.substring(c.dialCode.length).replaceAll(RegExp(r'\D'), '');
          setState(() {
            _country = c;
            _numberController.text = national;
            _numberController.selection = TextSelection.collapsed(offset: national.length);
          });
          return;
        }
      }
    } else if (text.startsWith('0')) {
      // Strip leading zero for national format
      final stripped = text.replaceFirst(RegExp(r'^0+'), '');
      _numberController.text = stripped;
      _numberController.selection = TextSelection.collapsed(offset: stripped.length);
    }
  }

  bool get _valid {
    final digits = _numberController.text.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 6;
  }

  Future<void> _submit() async {
    final digits = _numberController.text.replaceAll(RegExp(r'\D'), '');
    if (!_valid) {
      setState(() => _error = 'Please enter your complete phone number.');
      return;
    }

    final fullNumber = '${_country.dialCode}$digits';

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authControllerProvider.notifier).submitPhone(fullNumber);
    } on TelegramException catch (e) {
      if (mounted) setState(() => _error = e.friendlyMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCountry() async {
    final picked = await CountryPickerSheet.show(context, _country);
    if (picked != null && mounted) {
      setState(() => _country = picked);
    }
  }

  Future<void> _useQr() async {
    setState(() {
      _qrBusy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).requestQrCode();
    } on TelegramException catch (e) {
      if (mounted) setState(() => _error = e.friendlyMessage);
    } finally {
      if (mounted) setState(() => _qrBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final auth = ref.watch(authStateProvider).value;
    final editing = ref.watch(authControllerProvider).editingPhone;
    final canGoBack = editing && auth is! td.AuthorizationStateWaitPhoneNumber;

    return AuthLayout(
      title: 'Sign in to Telegram',
      subtitle: const Text(
        'Select your country and enter your phone number to receive a verification code.',
      ),
      onBack: canGoBack
          ? () => ref.read(authControllerProvider.notifier).cancelEditPhone()
          : () => ref.invalidate(authControllerProvider),
      primary: BusyButton(label: 'Send code', busy: _busy, onPressed: _submit),
      secondary: TextButton(
        onPressed: _qrBusy || _busy ? null : _useQr,
        child: _qrBusy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Sign in with a QR code instead'),
      ),
      children: [
        // Country Selector Tile
        InkWell(
          onTap: _pickCountry,
          borderRadius: BorderRadius.circular(Radii.field),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: BorderRadius.circular(Radii.field),
              border: Border.all(color: colors.line),
            ),
            child: Row(
              children: [
                Text(_country.flag, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Text(
                    _country.name,
                    style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _country.dialCode,
                  style: context.text.bodyMedium?.copyWith(
                    color: colors.text2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: Space.xs),
                Icon(Icons.arrow_drop_down_rounded, color: colors.text3),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.m),

        // Phone Number Input with Country Code Badge
        TextField(
          controller: _numberController,
          autofocus: true,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.telephoneNumber],
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]')),
          ],
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: 18,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: 14),
              child: Text(
                _country.dialCode,
                style: context.text.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            hintText: _country.code == 'PH' ? '912 345 6789' : 'Phone number',
          ),
        ),
        FormError(_error),
        const ConnectionNotice(margin: EdgeInsets.only(top: Space.l)),
      ],
    );
  }
}
