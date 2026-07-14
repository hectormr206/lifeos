//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//

// ignore_for_file: unused_element
import 'package:copy_with_extension/copy_with_extension.dart';
import 'package:json_annotation/json_annotation.dart';

part 'validation_error.g.dart';


@CopyWith()
@JsonSerializable(
  checked: true,
  createToJson: true,
  disallowUnrecognizedKeys: false,
  explicitToJson: true,
)
class ValidationError {
  /// Returns a new [ValidationError] instance.
  ValidationError({

     this.ctx,

     this.input,

    required  this.loc,

    required  this.msg,

    required  this.type,
  });

  @JsonKey(
    
    name: r'ctx',
    required: false,
    includeIfNull: false,
  )


  final Object? ctx;



  @JsonKey(
    
    name: r'input',
    required: false,
    includeIfNull: false,
  )


  final Object? input;



  @JsonKey(
    
    name: r'loc',
    required: true,
    includeIfNull: false,
  )


  final List<String> loc;



  @JsonKey(
    
    name: r'msg',
    required: true,
    includeIfNull: false,
  )


  final String msg;



  @JsonKey(
    
    name: r'type',
    required: true,
    includeIfNull: false,
  )


  final String type;





    @override
    bool operator ==(Object other) => identical(this, other) || other is ValidationError &&
      other.ctx == ctx &&
      other.input == input &&
      other.loc == loc &&
      other.msg == msg &&
      other.type == type;

    @override
    int get hashCode =>
        ctx.hashCode +
        (input == null ? 0 : input.hashCode) +
        loc.hashCode +
        msg.hashCode +
        type.hashCode;

  factory ValidationError.fromJson(Map<String, dynamic> json) => _$ValidationErrorFromJson(json);

  Map<String, dynamic> toJson() => _$ValidationErrorToJson(this);

  @override
  String toString() {
    return toJson().toString();
  }

}

