// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'evaluate_expression_request.dart';

/// The response to an [EvaluateExpressionRequest].
class EvaluateExpressionResponse {
  /// The compiled JS expression or an error message if `isError` is true.
  final String result;
  final bool isError;

  EvaluateExpressionResponse({required this.result, required this.isError});

  Map<String, dynamic> toJson() => {
    'type': 'EvaluateExpressionResponse',
    'result': result,
    'isError': isError,
  };

  factory EvaluateExpressionResponse.fromJson(Map<String, dynamic> json) =>
      EvaluateExpressionResponse(
        result: json['result'] as String,
        isError: json['isError'] as bool,
      );
}
