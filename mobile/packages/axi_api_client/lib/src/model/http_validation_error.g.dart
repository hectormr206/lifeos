// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'http_validation_error.dart';

// **************************************************************************
// CopyWithGenerator
// **************************************************************************

abstract class _$HTTPValidationErrorCWProxy {
  HTTPValidationError detail(List<ValidationError>? detail);

  /// This function **does support** nullification of nullable fields. All `null` values passed to `non-nullable` fields will be ignored. You can also use `HTTPValidationError(...).copyWith.fieldName(...)` to override fields one at a time with nullification support.
  ///
  /// Usage
  /// ```dart
  /// HTTPValidationError(...).copyWith(id: 12, name: "My name")
  /// ````
  HTTPValidationError call({List<ValidationError>? detail});
}

/// Proxy class for `copyWith` functionality. This is a callable class and can be used as follows: `instanceOfHTTPValidationError.copyWith(...)`. Additionally contains functions for specific fields e.g. `instanceOfHTTPValidationError.copyWith.fieldName(...)`
class _$HTTPValidationErrorCWProxyImpl implements _$HTTPValidationErrorCWProxy {
  const _$HTTPValidationErrorCWProxyImpl(this._value);

  final HTTPValidationError _value;

  @override
  HTTPValidationError detail(List<ValidationError>? detail) =>
      this(detail: detail);

  @override
  /// This function **does support** nullification of nullable fields. All `null` values passed to `non-nullable` fields will be ignored. You can also use `HTTPValidationError(...).copyWith.fieldName(...)` to override fields one at a time with nullification support.
  ///
  /// Usage
  /// ```dart
  /// HTTPValidationError(...).copyWith(id: 12, name: "My name")
  /// ````
  HTTPValidationError call({Object? detail = const $CopyWithPlaceholder()}) {
    return HTTPValidationError(
      detail: detail == const $CopyWithPlaceholder()
          ? _value.detail
          // ignore: cast_nullable_to_non_nullable
          : detail as List<ValidationError>?,
    );
  }
}

extension $HTTPValidationErrorCopyWith on HTTPValidationError {
  /// Returns a callable class that can be used as follows: `instanceOfHTTPValidationError.copyWith(...)` or like so:`instanceOfHTTPValidationError.copyWith.fieldName(...)`.
  // ignore: library_private_types_in_public_api
  _$HTTPValidationErrorCWProxy get copyWith =>
      _$HTTPValidationErrorCWProxyImpl(this);
}

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

HTTPValidationError _$HTTPValidationErrorFromJson(Map<String, dynamic> json) =>
    $checkedCreate('HTTPValidationError', json, ($checkedConvert) {
      final val = HTTPValidationError(
        detail: $checkedConvert(
          'detail',
          (v) => (v as List<dynamic>?)
              ?.map((e) => ValidationError.fromJson(e as Map<String, dynamic>))
              .toList(),
        ),
      );
      return val;
    });

Map<String, dynamic> _$HTTPValidationErrorToJson(
  HTTPValidationError instance,
) => <String, dynamic>{
  'detail': ?instance.detail?.map((e) => e.toJson()).toList(),
};
