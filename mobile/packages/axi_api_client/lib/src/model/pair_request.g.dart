// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pair_request.dart';

// **************************************************************************
// CopyWithGenerator
// **************************************************************************

abstract class _$PairRequestCWProxy {
  PairRequest code(String code);

  PairRequest deviceName(String? deviceName);

  PairRequest devicePubkey(String? devicePubkey);

  /// This function **does support** nullification of nullable fields. All `null` values passed to `non-nullable` fields will be ignored. You can also use `PairRequest(...).copyWith.fieldName(...)` to override fields one at a time with nullification support.
  ///
  /// Usage
  /// ```dart
  /// PairRequest(...).copyWith(id: 12, name: "My name")
  /// ````
  PairRequest call({String code, String? deviceName, String? devicePubkey});
}

/// Proxy class for `copyWith` functionality. This is a callable class and can be used as follows: `instanceOfPairRequest.copyWith(...)`. Additionally contains functions for specific fields e.g. `instanceOfPairRequest.copyWith.fieldName(...)`
class _$PairRequestCWProxyImpl implements _$PairRequestCWProxy {
  const _$PairRequestCWProxyImpl(this._value);

  final PairRequest _value;

  @override
  PairRequest code(String code) => this(code: code);

  @override
  PairRequest deviceName(String? deviceName) => this(deviceName: deviceName);

  @override
  PairRequest devicePubkey(String? devicePubkey) =>
      this(devicePubkey: devicePubkey);

  @override
  /// This function **does support** nullification of nullable fields. All `null` values passed to `non-nullable` fields will be ignored. You can also use `PairRequest(...).copyWith.fieldName(...)` to override fields one at a time with nullification support.
  ///
  /// Usage
  /// ```dart
  /// PairRequest(...).copyWith(id: 12, name: "My name")
  /// ````
  PairRequest call({
    Object? code = const $CopyWithPlaceholder(),
    Object? deviceName = const $CopyWithPlaceholder(),
    Object? devicePubkey = const $CopyWithPlaceholder(),
  }) {
    return PairRequest(
      code: code == const $CopyWithPlaceholder()
          ? _value.code
          // ignore: cast_nullable_to_non_nullable
          : code as String,
      deviceName: deviceName == const $CopyWithPlaceholder()
          ? _value.deviceName
          // ignore: cast_nullable_to_non_nullable
          : deviceName as String?,
      devicePubkey: devicePubkey == const $CopyWithPlaceholder()
          ? _value.devicePubkey
          // ignore: cast_nullable_to_non_nullable
          : devicePubkey as String?,
    );
  }
}

extension $PairRequestCopyWith on PairRequest {
  /// Returns a callable class that can be used as follows: `instanceOfPairRequest.copyWith(...)` or like so:`instanceOfPairRequest.copyWith.fieldName(...)`.
  // ignore: library_private_types_in_public_api
  _$PairRequestCWProxy get copyWith => _$PairRequestCWProxyImpl(this);
}

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PairRequest _$PairRequestFromJson(Map<String, dynamic> json) => $checkedCreate(
  'PairRequest',
  json,
  ($checkedConvert) {
    $checkKeys(json, requiredKeys: const ['code']);
    final val = PairRequest(
      code: $checkedConvert('code', (v) => v as String),
      deviceName: $checkedConvert(
        'device_name',
        (v) => v as String? ?? 'Unnamed device',
      ),
      devicePubkey: $checkedConvert('device_pubkey', (v) => v as String?),
    );
    return val;
  },
  fieldKeyMap: const {
    'deviceName': 'device_name',
    'devicePubkey': 'device_pubkey',
  },
);

Map<String, dynamic> _$PairRequestToJson(PairRequest instance) =>
    <String, dynamic>{
      'code': instance.code,
      'device_name': ?instance.deviceName,
      'device_pubkey': ?instance.devicePubkey,
    };
