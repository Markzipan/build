// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'evaluate_expression_response.dart';

/// A request to evaluate a Dart expression from an app built with
/// build daemon.
///
/// This request is sent by a debugger (via DWDS) to the build daemon. The
/// daemon asks the Frontend Server to compile [expression] to JS,
/// and returns the result in an [EvaluateExpressionResponse].
///
/// See `compileExpressionToJs` in DWDS's `expression_compiler.dart`.
class EvaluateExpressionRequest {
  final String isolateId;
  final String libraryUri;
  final String scriptUri;
  final int line;
  final int column;

  /// A map from variable name to the module name, where variable name is the
  /// name originally used in JS to contain the module object. For example:
  /// {'dart': 'dart_sdk', 'main': '/packages/hello_world_main.dart'}.
  final Map<String, String> jsModules;

  /// A map from JS variable name to its primitive value or another
  /// variable name. For example: {'x': '1', 'y': 'y', 'o': 'null'}.
  final Map<String, String> jsFrameValues;

  final String moduleName;
  final String expression;

  EvaluateExpressionRequest({
    required this.isolateId,
    required this.libraryUri,
    required this.scriptUri,
    required this.line,
    required this.column,
    required this.jsModules,
    required this.jsFrameValues,
    required this.moduleName,
    required this.expression,
  });

  Map<String, dynamic> toJson() => {
    'type': 'EvaluateExpressionRequest',
    'isolateId': isolateId,
    'libraryUri': libraryUri,
    'scriptUri': scriptUri,
    'line': line,
    'column': column,
    'jsModules': jsModules,
    'jsFrameValues': jsFrameValues,
    'moduleName': moduleName,
    'expression': expression,
  };

  factory EvaluateExpressionRequest.fromJson(Map<String, dynamic> json) =>
      EvaluateExpressionRequest(
        isolateId: json['isolateId']?.toString() ?? '',
        libraryUri: json['libraryUri'] as String,
        scriptUri: json['scriptUri'] as String,
        line: (json['line'] as int?) ?? 0,
        column: (json['column'] as int?) ?? 0,
        jsModules: Map<String, String>.from(json['jsModules'] as Map),
        jsFrameValues: Map<String, String>.from(json['jsFrameValues'] as Map),
        moduleName: json['moduleName'] as String,
        expression: json['expression'] as String,
      );
}
