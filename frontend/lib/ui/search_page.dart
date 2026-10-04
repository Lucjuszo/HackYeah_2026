import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Search screen from Figma p9: the field and recent searches. Pops with the query ('' clears it).
class SearchPage extends StatefulWidget {
  const SearchPage({this.initial = '', this.recent = const <String>[], super.key});

  final String initial;
  final List<String> recent;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? text]) => Navigator.of(context).pop((text ?? _controller.text).trim());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            const Align(alignment: Alignment.centerLeft, child: BackChevron()),
            const SizedBox(height: 22),
            TextField(
              key: const ValueKey<String>('search-input'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 16, color: AppColors.ink),
              decoration: InputDecoration(
                hintText: 'Szukaj miejscówki',
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(left: 18, right: 10),
                  child: Icon(Icons.search_rounded, size: 28, color: AppColors.ink),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 56),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Wyczyść',
                        icon: const Icon(Icons.close_rounded, color: AppColors.secondary),
                        onPressed: () => setState(_controller.clear),
                      ),
              ),
            ),
            const SizedBox(height: 26),
            if (widget.recent.isNotEmpty)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final query in widget.recent)
                    OutlinePill(
                      key: ValueKey<String>('recent-$query'),
                      label: query,
                      fontSize: 13,
                      height: 34,
                      leading: const Icon(Icons.schedule_rounded, size: 16, color: AppColors.ink),
                      onPressed: () => _submit(query),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
