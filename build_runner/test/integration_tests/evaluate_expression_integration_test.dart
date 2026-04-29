// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@Tags(['integration2'])
library;

import 'package:async/async.dart';
import 'package:build_daemon/client.dart';
import 'package:build_daemon/constants.dart';
import 'package:build_daemon/data/build_status.dart';
import 'package:build_daemon/data/build_target.dart';
import 'package:build_daemon/data/evaluate_expression_request.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../common/common.dart';

const defaultTimeout = Timeout(Duration(seconds: 180));

void main() async {
  final webTarget = DefaultBuildTarget((b) {
    b.target = 'web';
    b.reportChangedAssets = true;
  });

  test('evaluate expression via daemon', () async {
    final pubspecs = await Pubspecs.load();
    final tester = BuildRunnerTester(pubspecs);

    tester.writeFixturePackage(FixturePackages.copyBuilder());

    tester.writePackage(
      name: 'root_pkg',
      dependencies: [
        'build',
        'build_config',
        'build_daemon',
        'build_modules',
        'build_runner',
        'build_web_compilers',
        'build_test',
        'scratch_space',
      ],
      pathDependencies: ['builder_pkg'],
      files: {
        'lib/message.dart': "const message = 'hello world';",
        'web/main.dart': '''
import 'package:root_pkg/message.dart';

void main() {
  print(message);
}
''',
        'build.yaml': '''
global_options:
  build_web_compilers:ddc:
    options:
      web-hot-reload: true
  build_web_compilers|sdk_js:
    options:
      web-hot-reload: true
  build_web_compilers|entrypoint:
    options:
      web-hot-reload: true
  build_web_compilers|entrypoint_marker:
    options:
      web-hot-reload: true
  build_web_compilers|ddc_modules:
    options:
      web-hot-reload: true
''',
      },
    );

    // Start daemon
    final daemon = await tester.start(
      'root_pkg',
      'dart run build_runner daemon --force-jit --web-hot-reload',
    );
    await daemon.expect(readyToConnectLog);

    // Start client
    final client = await BuildDaemonClient.connectUnchecked(
      p.join(tester.tempDirectory.path, 'root_pkg'),
      logHandler: (event) => printOnFailure('(0) ${event.message}'),
    );
    addTearDown(client.close);

    // Perform builds
    client.registerBuildTarget(webTarget);
    client.startBuild();
    final results = StreamQueue(client.buildResults);
    expect((await results.next).results.single.status, BuildStatus.started);
    expect((await results.next).results.single.status, BuildStatus.succeeded);

    // Send EvaluateExpressionRequest and get EvaluateExpressionResponse
    final response = await client.sendRequest(
      EvaluateExpressionRequest(
        isolateId: '1',
        libraryUri: 'package:root_pkg/message.dart',
        scriptUri: 'org-dartlang-app:///lib/message.dart',
        line: 1,
        column: 1,
        jsModules: <String, String>{},
        jsFrameValues: <String, String>{},
        moduleName: 'packages/root_pkg/message',
        expression: 'message',
      ).toJson(),
    );

    expect(response['isError'], false);
    expect(response['result'], contains('hello world'));

    // Send invalid EvaluateExpressionRequest
    final errorResponse = await client.sendRequest(
      EvaluateExpressionRequest(
        isolateId: '1',
        libraryUri: 'package:root_pkg/message.dart',
        scriptUri: 'org-dartlang-app:///lib/message.dart',
        line: 1,
        column: 1,
        jsModules: <String, String>{},
        jsFrameValues: <String, String>{},
        moduleName: 'packages/root_pkg/message',
        expression: 'invalid',
      ).toJson(),
    );

    expect(errorResponse['isError'], true);
    expect(errorResponse['result'], contains('Undefined name'));

    // Send a valid EvaluateExpressionRequest to verify recovery
    final recoveryResponse = await client.sendRequest(
      EvaluateExpressionRequest(
        isolateId: '1',
        libraryUri: 'package:root_pkg/message.dart',
        scriptUri: 'org-dartlang-app:///lib/message.dart',
        line: 1,
        column: 1,
        jsModules: <String, String>{},
        jsFrameValues: <String, String>{},
        moduleName: 'packages/root_pkg/message',
        expression: 'message',
      ).toJson(),
    );

    expect(recoveryResponse['isError'], false);
    expect(recoveryResponse['result'], contains('hello world'));

    // Send concurrent expression evaluations
    final concurrentFutures = [
      client.sendRequest(
        EvaluateExpressionRequest(
          isolateId: '1',
          libraryUri: 'package:root_pkg/message.dart',
          scriptUri: 'org-dartlang-app:///lib/message.dart',
          line: 1,
          column: 1,
          jsModules: <String, String>{},
          jsFrameValues: <String, String>{},
          moduleName: 'packages/root_pkg/message',
          expression: 'message',
        ).toJson(),
      ),
      client.sendRequest(
        EvaluateExpressionRequest(
          isolateId: '1',
          libraryUri: 'package:root_pkg/message.dart',
          scriptUri: 'org-dartlang-app:///lib/message.dart',
          line: 1,
          column: 1,
          jsModules: <String, String>{},
          jsFrameValues: <String, String>{},
          moduleName: 'packages/root_pkg/message',
          expression: 'message',
        ).toJson(),
      ),
    ];

    final concurrentResults = await Future.wait(concurrentFutures);
    for (final response in concurrentResults) {
      expect(response['isError'], false);
      expect(response['result'], contains('hello world'));
    }

    // Kick off a build and eval during the build
    tester.write(
      'root_pkg/lib/message.dart',
      "const message = 'updated world';",
    );
    // Ensure the write is picked up
    await Future<void>.delayed(const Duration(seconds: 1));
    client.startBuild();

    final evalDuringBuildFuture = client.sendRequest(
      EvaluateExpressionRequest(
        isolateId: '1',
        libraryUri: 'package:root_pkg/message.dart',
        scriptUri: 'org-dartlang-app:///lib/message.dart',
        line: 1,
        column: 1,
        jsModules: <String, String>{},
        jsFrameValues: <String, String>{},
        moduleName: 'packages/root_pkg/message',
        expression: 'message',
      ).toJson(),
    );

    // Ensure the rebuild has started
    expect((await results.next).results.single.status, BuildStatus.started);
    expect((await results.next).results.single.status, BuildStatus.succeeded);

    final evalDuringBuildResponse = await evalDuringBuildFuture;
    expect(evalDuringBuildResponse['isError'], false);
    expect(evalDuringBuildResponse['result'], contains('updated world'));
  }, timeout: defaultTimeout);
}
