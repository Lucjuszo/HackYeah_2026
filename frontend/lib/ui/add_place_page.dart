import 'package:flutter/material.dart';

import 'theme.dart';

/// Visual form for adding a new place.
///
/// The current public API is read-only, so this screen intentionally keeps the
/// entered values local. It gives the UI a complete, ready-to-connect form
/// without changing the existing place-reading flow.
class AddPlacePage extends StatefulWidget {
  const AddPlacePage({super.key});

  @override
  State<AddPlacePage> createState() => _AddPlacePageState();
}

class _AddPlacePageState extends State<AddPlacePage> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _category = 'Kawiarnia';
  String _hours = 'Godziny otwarcia';
  String _atmosphere = 'Spokojnie';
  String _price = '0–20 zł';
  final Set<String> _amenities = <String>{};

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _choose({
    required String title,
    required List<String> options,
    required String value,
    required ValueChanged<String> onSelected,
  }) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final option in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  option == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: option == value ? AppColors.primary : AppColors.muted,
                ),
                title: Text(option),
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (selected != null) onSelected(selected);
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11, color: AppColors.subtle),
    ),
  );

  Widget _textField(
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AppColors.muted),
        filled: true,
        fillColor: const Color(0xFFF5EEDD),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _selector({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(label),
        Material(
          color: const Color(0xFFF5EEDD),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(value, style: const TextStyle(fontSize: 12)),
                  ),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: AppColors.subtle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _choiceRow(
    String title,
    List<String> options,
    String selected,
    ValueChanged<String> onSelected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(title),
        Row(
          children: <Widget>[
            for (final option in options)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    color: selected == option
                        ? AppColors.accent
                        : const Color(0xFFF5EEDD),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => onSelected(option),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Text(
                          option,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _amenity(String label) {
    final selected = _amenities.contains(label);
    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          if (selected) {
            _amenities.remove(label);
          } else {
            _amenities.add(label);
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 17,
                color: selected ? AppColors.open : AppColors.primary,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label, style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Formularz jest gotowy do zapisania.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey<String>('add-place-back'),
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Dodaj miejsce',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(13, 4, 13, 30),
        children: <Widget>[
          Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 106,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFFE8DCC5),
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.image_outlined,
                      size: 30,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Text(
                        'Dodaj zdjęcia',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _label('Nazwa'),
          _textField(_nameController, hint: 'Nazwa miejscówki'),
          const SizedBox(height: 10),
          _label('Adres'),
          _textField(_addressController, hint: 'Adres miejscówki'),
          const SizedBox(height: 10),
          _label('Lokalizacja'),
          Container(
            height: 112,
            decoration: BoxDecoration(
              color: const Color(0xFFE6E9E7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD7D3CA)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Positioned.fill(
                  child: CustomPaint(painter: _MapSketchPainter()),
                ),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.location_on_rounded, size: 20),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _selector(
            label: 'Kategoria',
            value: _category,
            onTap: () => _choose(
              title: 'Kategoria',
              options: const [
                'Kawiarnia',
                'Biblioteka',
                'Restauracja',
                'Przestrzeń coworkingowa',
              ],
              value: _category,
              onSelected: (value) => setState(() => _category = value),
            ),
          ),
          const SizedBox(height: 10),
          _selector(
            label: 'Godziny otwarcia',
            value: _hours,
            onTap: () => _choose(
              title: 'Godziny otwarcia',
              options: const [
                'Pon.–Pt. 8:00–20:00',
                'Codziennie 9:00–22:00',
                'Całą dobę',
              ],
              value: _hours,
              onSelected: (value) => setState(() => _hours = value),
            ),
          ),
          const SizedBox(height: 10),
          _choiceRow(
            'Atmosfera',
            const ['Spokojnie', 'Na pogaduchy', 'Gwarno'],
            _atmosphere,
            (value) {
              setState(() => _atmosphere = value);
            },
          ),
          const SizedBox(height: 10),
          _choiceRow(
            'Cena',
            const ['0–20 zł', '20–40 zł', '40–60 zł'],
            _price,
            (value) {
              setState(() => _price = value);
            },
          ),
          const SizedBox(height: 10),
          _label('Dodatkowe udogodnienia'),
          Row(children: <Widget>[_amenity('Wi-Fi'), _amenity('Toaleta')]),
          Row(
            children: <Widget>[_amenity('Gniazdka'), _amenity('Gastronomia')],
          ),
          Row(
            children: <Widget>[
              _amenity('Klima'),
              _amenity('Dostęp do komputera'),
            ],
          ),
          const SizedBox(height: 10),
          _label('Dodatkowe uwagi'),
          _textField(
            _descriptionController,
            hint: 'Opisz miejsce',
            maxLines: 3,
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.ink,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
              child: const Text('Opublikuj'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapSketchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = const Color(0xFFC9D2D3)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final park = Paint()
      ..color = const Color(0xFFD5E5D4)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .05,
        size.height * .2,
        size.width * .22,
        size.height * .55,
      ),
      park,
    );
    canvas.drawLine(
      Offset(0, size.height * .75),
      Offset(size.width, size.height * .2),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .18, 0),
      Offset(size.width * .72, size.height),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .7, 0),
      Offset(size.width * .45, size.height),
      road,
    );
    canvas.drawLine(
      Offset(0, size.height * .28),
      Offset(size.width, size.height * .8),
      road,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
