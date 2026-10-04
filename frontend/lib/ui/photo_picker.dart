import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'theme.dart';

/// A photo chosen on the device, ready to upload.
class PickedPhoto {
  const PickedPhoto(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Gallery (several at once) or camera, where the platform has one. Empty when cancelled.
///
/// Photos are scaled down on the device first: the API keeps at most 1600 px anyway,
/// and a 12 MP phone photo would take long to send over mobile data.
Future<List<PickedPhoto>> pickPhotos(BuildContext context, {int? limit}) async {
  final picker = ImagePicker();
  final source = picker.supportsImageSource(ImageSource.camera)
      ? await showModalBottomSheet<ImageSource>(
          context: context,
          showDragHandle: true,
          backgroundColor: AppColors.surface,
          builder: (BuildContext sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  key: const ValueKey<String>('pick-gallery'),
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Wybierz z galerii'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ImageSource.gallery),
                ),
                ListTile(
                  key: const ValueKey<String>('pick-camera'),
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Zrób zdjęcie'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ImageSource.camera),
                ),
              ],
            ),
          ),
        )
      : ImageSource.gallery;
  if (source == null) return const <PickedPhoto>[];

  const maxSide = 2400.0;
  const quality = 90;
  final List<XFile> files;
  if (source == ImageSource.camera) {
    final file = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: maxSide,
      maxHeight: maxSide,
      imageQuality: quality,
    );
    files = file == null ? const <XFile>[] : <XFile>[file];
  } else if (limit == 1) {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxSide,
      maxHeight: maxSide,
      imageQuality: quality,
    );
    files = file == null ? const <XFile>[] : <XFile>[file];
  } else {
    files = await picker.pickMultiImage(
      maxWidth: maxSide,
      maxHeight: maxSide,
      imageQuality: quality,
      limit: limit,
    );
  }
  final chosen = limit == null ? files : files.take(limit);
  return <PickedPhoto>[
    for (final (i, file) in chosen.indexed)
      // Some platforms give no name; the API only needs one for the multipart part.
      PickedPhoto(
        file.name.isEmpty ? 'photo_${i + 1}.jpg' : file.name,
        await file.readAsBytes(),
      ),
  ];
}
