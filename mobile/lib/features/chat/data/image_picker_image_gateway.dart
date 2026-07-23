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
      // Bound the LONGEST side to ~1024px (encoder-friendly for gemma-4-E2B's
      // vision tower) so borderline high-res photos don't add per-image variance
      // that pushes the sampler into degeneration. Quality 85 keeps it small.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return null;
    return file.readAsBytes();
  }
}
