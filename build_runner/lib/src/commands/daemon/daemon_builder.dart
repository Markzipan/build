// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_daemon/change_provider.dart';
import 'package:build_daemon/constants.dart';
import 'package:build_daemon/daemon_builder.dart';
import 'package:build_daemon/data/build_status.dart';
import 'package:build_daemon/data/build_target.dart' hide OutputLocation;
import 'package:build_daemon/data/evaluate_expression_request.dart';
import 'package:build_daemon/data/evaluate_expression_response.dart';
import 'package:build_daemon/data/server_log.dart';
import 'package:build_modules/build_modules.dart';
import 'package:built_collection/built_collection.dart';
import 'package:path/path.dart' as p;
import 'package:stream_transform/stream_transform.dart';
import 'package:watcher/watcher.dart';

import '../../build/build_result.dart' as core;
import '../../build/build_series.dart';
import '../../build_plan/build_directory.dart';
import '../../build_plan/build_filter.dart';
import '../../build_plan/build_plan.dart';
import '../../logging/build_log.dart';
import '../daemon_options.dart';
import '../watch/build_package_watcher.dart';
import '../watch/build_packages_watcher.dart';
import 'change_providers.dart';

/// A Daemon Builder that builds with `build_runner`.
class BuildRunnerDaemonBuilder implements DaemonBuilder {
  final _buildResults = StreamController<BuildResults>();

  final BuildPlan _buildPlan;
  final BuildSeries buildSeries;
  final StreamController<ServerLog> _outputStreamController;
  final ChangeProvider changeProvider;
  Completer<void>? _buildingCompleter;

  @override
  final Stream<ServerLog> logs;

  BuildRunnerDaemonBuilder._(
    this._buildPlan,
    this.buildSeries,
    this._outputStreamController,
    this.changeProvider,
  ) : logs = _outputStreamController.stream.asBroadcastStream();

  /// Returns a future that completes when the current build is complete, or
  /// `null` if there is no active build.
  Future<void>? get building => _buildingCompleter?.future;

  @override
  Stream<BuildResults> get builds => _buildResults.stream;

  final _buildScriptUpdateCompleter = Completer<void>();
  Future<void> get buildScriptUpdated => _buildScriptUpdateCompleter.future;

  String get _currentPackageName => _buildPlan.buildPackages.currentPackage;

  @override
  Future<void> build(
    Set<BuildTarget> targets,
    Iterable<WatchEvent> fileChanges,
  ) async {
    final defaultTargets = targets.cast<DefaultBuildTarget>();
    final updates =
        fileChanges.map((change) => AssetId.parse(change.path)).toSet();

    final targetNames = targets.map((t) => t.target).toSet();
    _logMessage(Level.INFO, 'About to build ${targetNames.toList()}...');
    _signalStart(targetNames);
    final results = <BuildResult>[];
    final buildDirs = <BuildDirectory>{};
    final buildFilters = <BuildFilter>{};
    for (final target in defaultTargets) {
      OutputLocation? outputLocation;
      if (target.outputLocation != null) {
        final targetOutputLocation = target.outputLocation!;
        outputLocation = OutputLocation(
          targetOutputLocation.output,
          useSymlinks: targetOutputLocation.useSymlinks,
          hoist: targetOutputLocation.hoist,
        );
      }
      buildDirs.add(
        BuildDirectory(target.target, outputLocation: outputLocation),
      );
      if (target.buildFilters != null && target.buildFilters!.isNotEmpty) {
        buildFilters.addAll([
          for (final pattern in target.buildFilters!)
            BuildFilter.fromArg(
              arg: pattern,
              currentPackage: _currentPackageName,
            ),
        ]);
      } else {
        buildFilters
          ..add(
            BuildFilter.fromArg(
              arg: 'package:*/**',
              currentPackage: _currentPackageName,
            ),
          )
          ..add(
            BuildFilter.fromArg(
              arg: '${target.target}/**',
              currentPackage: _currentPackageName,
            ),
          );
      }
    }
    Iterable<AssetId>? outputs;

    try {
      final result = await buildSeries.run(
        updates,
        recentlyBootstrapped: false,
        buildDirs: buildDirs.build(),
        buildFilters: buildFilters.build(),
      );
      if (result.failureType == core.FailureType.buildScriptChanged) {
        if (!_buildScriptUpdateCompleter.isCompleted) {
          _buildScriptUpdateCompleter.complete();
        }
        return;
      }
      final interestedInOutputs = targets.any(
        (e) => e is DefaultBuildTarget && e.reportChangedAssets,
      );

      if (interestedInOutputs) {
        outputs = {for (final id in updates) id, ...result.outputs};
      }

      for (final target in targets) {
        if (result.status == core.BuildStatus.success) {
          // TODO(grouma) - Can we notify if a target was cached?
          results.add(
            DefaultBuildResult((b) {
              b.status = BuildStatus.succeeded;
              b.target = target.target;
            }),
          );
        } else {
          results.add(
            DefaultBuildResult((b) {
              b.status = BuildStatus.failed;
              // TODO(grouma) - We should forward the error messages
              // instead.
              // We can use the AssetGraph and FailureReporter to provide
              // a better error message.;
              b.error = 'FailureType: ${result.failureType?.exitCode}';
              b.target = target.target;
            }),
          );
        }
      }
    } catch (e) {
      for (final target in targets) {
        results.add(
          DefaultBuildResult((b) {
            b.status = BuildStatus.failed;
            b.error = '$e';
            b.target = target.target;
          }),
        );
      }
      _logMessage(Level.SEVERE, 'Build Failed:\n${e.toString()}');
    }
    _signalEnd(results, outputs?.map((e) => e.uri));
  }

  @override
  Future<void> stop() async {
    await buildSeries.close();
  }

  @override
  Future<EvaluateExpressionResponse> evaluateExpression(
    EvaluateExpressionRequest request,
  ) async {
    final port = await _getFrontendServerPort();
    if (port == null) {
      return EvaluateExpressionResponse(
        result: 'InternalError: No running Frontend Server worker found.',
        isError: true,
      );
    }

    return _sendExpressionToWorker(port, request);
  }

  /// Returns the port of the running Frontend Server worker via the port file
  /// or `null` if it wasn't found.
  Future<int?> _getFrontendServerPort() async {
    final fesWorkerPortFile = File(
      p.join(Directory.current.path, fesWorkerPortPath),
    );

    if (!fesWorkerPortFile.existsSync()) return null;
    return int.parse(fesWorkerPortFile.readAsStringSync());
  }

  /// Sends a 'COMPILE_EXPRESSION_JS' request to the Frontend Server worker
  /// and reads its compiled JS result (or compilation error).
  ///
  /// See: `pkg/frontend_server/lib/frontend_server.dart` in the Dart SDK.
  Future<EvaluateExpressionResponse> _sendExpressionToWorker(
    int port,
    EvaluateExpressionRequest request,
  ) async {
    // Open a socket to the persistent Frontend Server to evaluate [request].
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.writeln(json.encode(request.toJson()));

    final responseLine =
        await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
    await socket.close();

    // Write to a log file to bypass logging layers
    File('/Users/markzipan/Projects/build/worker.log').writeAsStringSync(
      'DAEMON RECEIVED FROM WORKER: $responseLine\n',
      mode: FileMode.append,
    );

    final compileResult = json.decode(responseLine);

    if (compileResult is Map && compileResult.containsKey('error')) {
      return EvaluateExpressionResponse(
        result: compileResult['error'] as String,
        isError: true,
      );
    }

    if (compileResult case {
      'errorCount': final int errorCount,
      'expressionData': final String? expressionData,
    }) {
      if (errorCount > 0) {
        return EvaluateExpressionResponse(
          result: compileResult['errorMessage'] as String? ?? 'Unknown error',
          isError: true,
        );
      }

      if (expressionData != null) {
        final decodedResult = utf8.decode(base64.decode(expressionData));
        return EvaluateExpressionResponse(
          result: decodedResult,
          isError: false,
        );
      }
    }

    return EvaluateExpressionResponse(
      result: 'Failed to read evaluation result',
      isError: true,
    );
  }

  void _logMessage(Level level, String message) => _outputStreamController.add(
    ServerLog((b) {
      b.message = message;
      b.level = level;
    }),
  );

  void _signalEnd(
    Iterable<BuildResult> results, [
    Iterable<Uri>? changedAssets,
  ]) {
    _buildingCompleter!.complete();
    _buildResults.add(
      BuildResults((b) {
        b.results.addAll(results);

        if (changedAssets != null) {
          b.changedAssets.addAll(changedAssets);
        }
      }),
    );
  }

  void _signalStart(Iterable<String> targets) {
    _buildingCompleter = Completer();
    final results = <BuildResult>[];
    for (final target in targets) {
      results.add(
        DefaultBuildResult((b) {
          b.status = BuildStatus.started;
          b.target = target;
        }),
      );
    }
    _buildResults.add(BuildResults((b) => b..results.addAll(results)));
  }

  static Future<BuildRunnerDaemonBuilder> create({
    required BuildPlan buildPlan,
    required DaemonOptions daemonOptions,
  }) async {
    // Start a persistent Frontend Server worker on creation for expression
    // evaluation and hot reload.
    if (daemonOptions.webHotReload) {
      await startFrontendServerWorker();
    }
    final expectedDeletes = <AssetId>{};
    final outputStreamController = StreamController<ServerLog>(sync: true);

    buildLog.configuration = buildLog.configuration.rebuild((b) {
      b.onLog = (record) {
        outputStreamController.add(ServerLog.fromLogRecord(record));
      };
    });
    buildPlan = buildPlan.copyWith(
      readerWriter: buildPlan.readerWriter.copyWith(
        onDelete: expectedDeletes.add,
      ),
    );

    final buildSeries = BuildSeries(buildPlan);

    // Only actually used for the AutoChangeProvider.
    Stream<List<WatchEvent>> graphEvents() => BuildPackagesWatcher(
          buildPlan.buildPackages,
          watch: BuildPackageWatcher.new,
        )
        .watch()
        .debounceBuffer(
          buildPlan.testingOverrides.debounceDelay ??
              const Duration(milliseconds: 250),
        )
        .asyncMap(
          (changes) => buildSeries.filterChanges(changes, expectedDeletes),
        )
        .where((changes) => changes.isNotEmpty)
        .map(
          (changes) =>
              changes
                  .map((change) => WatchEvent(change.type, '${change.id}'))
                  .toList(),
        );

    final changeProvider =
        daemonOptions.buildMode == BuildMode.Auto
            ? AutoChangeProviderImpl(graphEvents())
            : ManualChangeProviderImpl(buildSeries.checkForChanges);

    return BuildRunnerDaemonBuilder._(
      buildPlan,
      buildSeries,
      outputStreamController,
      changeProvider,
    );
  }
}
