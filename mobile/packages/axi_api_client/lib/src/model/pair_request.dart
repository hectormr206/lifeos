//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:copy_with_extension/copy_with_extension.dart';
import 'package:json_annotation/json_annotation.dart';

part 'pair_request.g.dart';


@CopyWith()
@JsonSerializable(
  checked: true,
  createToJson: true,
  disallowUnrecognizedKeys: false,
  explicitToJson: true,
)
class PairRequest {
  /// Returns a new [PairRequest] instance.
  PairRequest({

    required  this.code,

     this.deviceName = 'Unnamed device',

     this.devicePubkey,
  });

  @JsonKey(
    
    name: r'code',
    required: true,
    includeIfNull: false,
  )


  final String code;



  @JsonKey(
    defaultValue: 'Unnamed device',
    name: r'device_name',
    required: false,
    includeIfNull: false,
  )


  final String? deviceName;



  @JsonKey(
    
    name: r'device_pubkey',
    required: false,
    includeIfNull: false,
  )


  final String? devicePubkey;





    @override
    bool operator ==(Object other) => identical(this, other) || other is PairRequest &&
      other.code == code &&
      other.deviceName == deviceName &&
      other.devicePubkey == devicePubkey;

    @override
    int get hashCode =>
        code.hashCode +
        deviceName.hashCode +
        (devicePubkey == null ? 0 : devicePubkey.hashCode);

  factory PairRequest.fromJson(Map<String, dynamic> json) => _$PairRequestFromJson(json);

  Map<String, dynamic> toJson() => _$PairRequestToJson(this);

  @override
  String toString() {
    return toJson().toString();
  }

}

