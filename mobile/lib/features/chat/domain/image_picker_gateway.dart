import 'dart:typed_data';

/// Where an attached photo comes from (WhatsApp/Telegram-style attach).
enum PhotoSource { camera, gallery }

/// Seam over `image_picker` so the chat's attach flow is unit-testable with a
/// fake (no platform channel, no OS picker). The concrete
/// [ImagePickerImageGateway] confines the plugin to the edge.
abstract class ImagePickerGateway {
  /// Opens the camera or gallery and returns the chosen image's bytes, or
  /// `null` if the user cancelled.
  Future<Uint8List?> pickImage(PhotoSource source);
}
