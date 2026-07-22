import 'dart:typed_data';

import 'package:image_picker/image_picker.dart' as ip;

import '../domain/image_picker_gateway.dart';

/// [ImagePickerGateway] backed by the real `image_picker` plugin. Downscales
/// on the way in (maxWidth + quality) so a multi-MB phone photo stays a
/// reasonable payload for the on-device vision model / HTTP upload.
class ImagePickerImageGateway implements ImagePickerGateway {
  ImagePickerImageGateway([ip.ImagePicker? picker]) : _picker = picker ?? ip.ImagePicker();

  final ip.ImagePicker _picker;

  @override
  Future<Uint8List?> pickImage(PhotoSource source) async {
    final file = await _picker.pickImage(
      source: switch (source) {
        PhotoSource.camera => ip.ImageSource.camera,
        PhotoSource.gallery => ip.ImageSource.gallery,
      },
      maxWidth: 1568,
      imageQuality: 85,
    );
    if (file == null) return null;
    return file.readAsBytes();
  }
}
