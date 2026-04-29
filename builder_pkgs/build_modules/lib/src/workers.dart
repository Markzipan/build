// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:bazel_worker/driver.dart';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;

import 'common.dart';
import 'frontend_server_driver.dart';
import 'scratch_space.dart';

// If no terminal is attached, prevent a new one from launching.
final _processMode =
    stdin.hasTerminal
        ? ProcessStartMode.normal
        : ProcessStartMode.detachedWithStdio;

/// Completes once the dartdevk workers have been shut down.
Future<void> get dartdevkWorkersAreDone =>
    _dartdevkWorkersAreDoneCompleter?.future ?? Future.value();
Completer<void>? _dartdevkWorkersAreDoneCompleter;

/// Completes once the common frontend workers have been shut down.
Future<void> get frontendWorkersAreDone =>
    _frontendWorkersAreDoneCompleter?.future ?? Future.value();
Completer<void>? _frontendWorkersAreDoneCompleter;

final int _defaultMaxWorkers = min((Platform.numberOfProcessors / 2).ceil(), 4);

const _maxWorkersEnvVar = 'BUILD_MAX_WORKERS_PER_TASK';

final int maxWorkersPerTask = () {
  final toParse =
      Platform.environment[_maxWorkersEnvVar] ?? '$_defaultMaxWorkers';
  final parsed = int.tryParse(toParse);
  if (parsed == null) {
    log.warning(
      'Invalid value for $_maxWorkersEnvVar environment variable, '
      'expected an int but got `$toParse`. Falling back to default value '
      'of $_defaultMaxWorkers.',
    );
    return _defaultMaxWorkers;
  }
  return parsed;
}();

/// Manages a shared set of persistent dartdevk workers.
BazelWorkerDriver get _dartdevkDriver {
  _dartdevkWorkersAreDoneCompleter ??= Completer<void>();
  return __dartdevkDriver ??= BazelWorkerDriver(
    () => Process.start(
      p.join(sdkDir, 'bin', 'dart'),
      [
        p.join(sdkDir, 'bin', 'snapshots', 'dartdevc.dart.snapshot'),
        '--persistent_worker',
      ],
      mode: _processMode,
      workingDirectory: scratchSpace.tempDir.path,
    ),
    maxWorkers: maxWorkersPerTask,
  );
}

BazelWorkerDriver? __dartdevkDriver;

/// Resource for fetching the current [BazelWorkerDriver] for dartdevk.
final dartdevkDriverResource = Resource<BazelWorkerDriver>(
  () => _dartdevkDriver,
  beforeExit: () async {
    await __dartdevkDriver?.terminateWorkers();
    _dartdevkWorkersAreDoneCompleter?.complete();
    _dartdevkWorkersAreDoneCompleter = null;
    __dartdevkDriver = null;
  },
);

/// Manages a shared set of persistent common frontend workers.
BazelWorkerDriver get _frontendDriver {
  _frontendWorkersAreDoneCompleter ??= Completer<void>();
  return __frontendDriver ??= BazelWorkerDriver(
    () => Process.start(
      p.join(sdkDir, 'bin', 'dartaotruntime'),
      [
        p.join(sdkDir, 'bin', 'snapshots', 'kernel_worker_aot.dart.snapshot'),
        '--persistent_worker',
      ],
      mode: _processMode,
      workingDirectory: scratchSpace.tempDir.path,
    ),
    maxWorkers: maxWorkersPerTask,
  );
}

BazelWorkerDriver? __frontendDriver;

/// Resource for fetching the current [BazelWorkerDriver] for common frontend.
final frontendDriverResource = Resource<BazelWorkerDriver>(
  () => _frontendDriver,
  beforeExit: () async {
    await __frontendDriver?.terminateWorkers();
    _frontendWorkersAreDoneCompleter?.complete();
    _frontendWorkersAreDoneCompleter = null;
    __frontendDriver = null;
  },
);

/// Completes once the Frontend Service proxy workers have been shut down.
Future<void> get frontendServerProxyWorkersAreDone =>
    _frontendServerProxyWorkersAreDoneCompleter?.future ?? Future.value();
Completer<void>? _frontendServerProxyWorkersAreDoneCompleter;

FrontendServerProxyDriver get _frontendServerProxyDriver {
  _frontendServerProxyWorkersAreDoneCompleter ??= Completer<void>();
  return __frontendServerProxyDriver ??= FrontendServerProxyDriver();
}

FrontendServerProxyDriver? __frontendServerProxyDriver;

/// Manages a shared set of workers that proxy requests to a single
/// [persistentFrontendServerResource].
final frontendServerProxyDriverResource = Resource<FrontendServerProxyDriver>(
  () async => _frontendServerProxyDriver,
  beforeExit: () async {
    _frontendServerProxyWorkersAreDoneCompleter?.complete();
    await __frontendServerProxyDriver?.terminate();
    _frontendServerProxyWorkersAreDoneCompleter = null;
    __frontendServerProxyDriver = null;
  },
);

PersistentFrontendServer? __persistentFrontendServer;

/// Returns the running instance of the PersistentFrontendServer, if any.
PersistentFrontendServer? get persistentFrontendServer =>
    __persistentFrontendServer;

/// Starts a single persistent instance of the Frontend Server targeting DDC.
///
/// Also starts a socket server to listen for expression evaluation requests
/// from the build daemon.
Future<PersistentFrontendServer> startFrontendServerWorker() async {
  if (__persistentFrontendServer != null) return __persistentFrontendServer!;

  final fes = await PersistentFrontendServer.start(
    sdkRoot: sdkDir,
    fileSystemRoot: scratchSpace.tempDir.uri,
    packagesFile: scratchSpace.tempDir.uri.resolve(packagesFilePath),
  );

  // Start socket server to receive expression eval requests from the build daemon.
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final fesWorkerPortFile = File(
    p.join(Directory.current.path, fesWorkerPortPath),
  );
  fesWorkerPortFile.createSync(recursive: true);
  fesWorkerPortFile.writeAsStringSync('${server.port}');

  _frontendServerProxyDriver.init(fes);
  server.listen(
    (socket) =>
        _handleWorkerConnection(socket, _frontendServerProxyDriver, fes),
  );
  return __persistentFrontendServer = fes;
}

/// Handles a socket connection from the build daemon to the Frontend Server
/// worker.
///
/// Also handles 'JSON_INPUT' protocol requests from the Frontend Server.
/// See: `pkg/frontend_server/lib/frontend_server.dart` in the Dart SDK.
void _handleWorkerConnection(
  Socket socket,
  FrontendServerProxyDriver driver,
  PersistentFrontendServer fes,
) {
  socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) async {
        try {
          final request = json.decode(line);
          if (request case {
            'type': 'EvaluateExpressionRequest',
            'libraryUri': final String libraryUri,
            'scriptUri': final String scriptUri,
            'line': final int line,
            'column': final int column,
            'jsModules': final Map jsModules,
            'jsFrameValues': final Map jsFrameValues,
            'moduleName': final String moduleName,
            'expression': final String expression,
          }) {
            final output = await driver.compileExpressionToJs(
              libraryUri: libraryUri,
              scriptUri: scriptUri,
              line: line,
              column: column,
              jsModules: Map<String, String>.from(jsModules),
              jsFrameValues: Map<String, String>.from(jsFrameValues),
              moduleName: moduleName,
              expression: expression,
            );
            socket.writeln(
              json.encode({
                'outputFilename': output?.outputFilename,
                'errorCount': output?.errorCount,
                'sources': output?.sources.map((u) => u.toString()).toList(),
                'expressionData': () {
                  // If the output contains expression data, encode it directly
                  // in the response. Otherwise, if its output is written to
                  // 'outputFilename'.
                  if (output?.expressionData != null) {
                    return base64.encode(output!.expressionData!);
                  } else if (output?.outputFilename != null) {
                    final file = File(output!.outputFilename);
                    if (file.existsSync()) {
                      return base64.encode(file.readAsBytesSync());
                    }
                  }
                  return null;
                }(),
                'errorMessage': output?.errorMessage,
              }),
            );
          } else if (request case {
            'type': 'READ_OUTPUT_FILE',
            'path': final String path,
          }) {
            final content = await fes.readOutputFile(path);
            socket.writeln(json.encode({'content': content}));
          }
        } catch (e) {
          socket.writeln(json.encode({'error': e.toString()}));
        }
      });
}

final persistentFrontendServerResource = Resource<PersistentFrontendServer>(
  () async => await startFrontendServerWorker(),
  beforeExit: () async {
    await __persistentFrontendServer?.shutdown();
    __persistentFrontendServer = null;

    final fesWorkerPortFile = File(
      p.join(Directory.current.path, fesWorkerPortPath),
    );
    if (fesWorkerPortFile.existsSync()) fesWorkerPortFile.deleteSync();
  },
);
