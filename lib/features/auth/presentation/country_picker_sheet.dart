import 'package:flutter/material.dart';

import '../../../app/theme/tokens.dart';
import '../domain/country.dart';

class CountryPickerSheet extends StatefulWidget {
  const CountryPickerSheet({
    super.key,
    required this.selectedCountry,
  });

  final Country selectedCountry;

  static Future<Country?> show(BuildContext context, Country current) {
    return showModalBottomSheet<Country>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CountryPickerSheet(selectedCountry: current),
    );
  }

  @override
  State<CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<CountryPickerSheet> {
  final _searchController = TextEditingController();
  List<Country> _filtered = Country.all;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = Country.all;
      } else {
        _filtered = Country.all.where((c) {
          final nameMatch = c.name.toLowerCase().contains(query);
          final codeMatch = c.code.toLowerCase().contains(query);
          final dialMatch = c.dialCode.contains(query);
          return nameMatch || codeMatch || dialMatch;
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final media = MediaQuery.of(context);

    return Container(
      height: media.size.height * 0.78,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.card)),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        children: [
          const SizedBox(height: Space.s),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.text3.withOpacity(0.4),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.s, Space.s),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Select Country',
                    style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.xs),
            child: TextField(
              controller: _searchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: 'Search country or code...',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                filled: true,
                fillColor: colors.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.field),
                  borderSide: BorderSide(color: colors.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.field),
                  borderSide: BorderSide(color: colors.line),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Text(
                        'No country found matching "${_searchController.text}"',
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(color: colors.text3),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final country = _filtered[index];
                      final isSelected = country.code == widget.selectedCountry.code;

                      return ListTile(
                        leading: Text(
                          country.flag,
                          style: const TextStyle(fontSize: 24),
                        ),
                        title: Text(
                          country.name,
                          style: text.bodyLarge?.copyWith(
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            color: isSelected ? colors.accent : colors.text,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              country.dialCode,
                              style: text.bodyMedium?.copyWith(
                                color: isSelected ? colors.accent : colors.text2,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: Space.s),
                              Icon(Icons.check_rounded, color: colors.accent, size: 18),
                            ],
                          ],
                        ),
                        onTap: () => Navigator.of(context).pop(country),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
