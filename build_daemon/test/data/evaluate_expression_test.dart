// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:build_daemon/data/evaluate_expression_request.dart';
import 'package:build_daemon/data/evaluate_expression_response.dart';
import 'package:test/test.dart';

void main() {
  group('EvaluateExpressionRequest', () {
    test('can be serialized and deserialized', () {
      final request = EvaluateExpressionRequest(
        isolateId: '1',
        libraryUri: 'org-dartlang-app:///web/main.dart',
        scriptUri: 'web/main.dart',
        line: 10,
        column: 1,
        jsModules: {'dart': 'dart_sdk'},
        jsFrameValues: {'x': '1'},
        moduleName: 'web/main.dart',
        expression: 'x + 1',
      );

      final json = request.toJson();
      final deserialized = EvaluateExpressionRequest.fromJson(json);

      expect(deserialized.isolateId, request.isolateId);
      expect(deserialized.libraryUri, request.libraryUri);
      expect(deserialized.scriptUri, request.scriptUri);
      expect(deserialized.line, request.line);
      expect(deserialized.column, request.column);
      expect(deserialized.jsModules, request.jsModules);
      expect(deserialized.jsFrameValues, request.jsFrameValues);
      expect(deserialized.moduleName, request.moduleName);
      expect(deserialized.expression, request.expression);
    });

    test('handles missing or null line and column', () {
      final json = {
        'isolateId': '1',
        'libraryUri': 'org-dartlang-app:///web/main.dart',
        'scriptUri': 'web/main.dart',
        'jsModules': <String, String>{},
        'jsFrameValues': <String, String>{},
        'moduleName': 'web/main.dart',
        'expression': 'x + 1',
      };

      final deserialized = EvaluateExpressionRequest.fromJson(json);

      expect(deserialized.line, 0);
      expect(deserialized.column, 0);
    });

    test('handles non-string isolateId', () {
      final json = {
        'isolateId': 1,
        'libraryUri': 'org-dartlang-app:///web/main.dart',
        'scriptUri': 'web/main.dart',
        'line': 10,
        'column': 1,
        'jsModules': <String, String>{},
        'jsFrameValues': <String, String>{},
        'moduleName': 'web/main.dart',
        'expression': 'x + 1',
      };

      final deserialized = EvaluateExpressionRequest.fromJson(json);

      expect(deserialized.isolateId, '1');
    });
  });

  group('EvaluateExpressionResponse', () {
    test('can be serialized and deserialized', () {
      final response = EvaluateExpressionResponse(result: '42', isError: false);

      final json = response.toJson();
      final deserialized = EvaluateExpressionResponse.fromJson(json);

      expect(deserialized.result, response.result);
      expect(deserialized.isError, response.isError);
    });
  });
}
