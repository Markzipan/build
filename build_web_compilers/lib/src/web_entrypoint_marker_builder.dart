// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:build/build.dart';
import 'package:build_modules/build_modules.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'common.dart';

final reloadSummaryFilePath = p.join('.dart_tool', 'reload_summary.json');

/// A builder that gathers information about a web target's 'main' entrypoint.
class WebEntrypointMarkerBuilder implements Builder {
  /// Records state (such as the web entrypoint) required when compiling DDC
  /// with the Library Bundle module system.
  ///
  /// A no-op if [usesWebHotReload] is not set.
  final bool usesWebHotReload;

  WebEntrypointMarkerBuilder({this.usesWebHotReload = false});

  @override
  final buildExtensions = const {
    r'$web$': ['.web.entrypoint.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!usesWebHotReload) return;

    final frontendServerState = await buildStep.fetchResource(
      frontendServerStateResource,
    );
    final webEntrypointAsset = AssetId(
      buildStep.inputId.package,
      'web/.web.entrypoint.json',
    );
    final webAssets = await buildStep.findAssets(Glob('web/**')).toList();
    final webEntrypointJson = <String, dynamic>{};

    for (final asset in webAssets) {
      if (asset.extension == '.dart') {
        final moduleLibrary = ModuleLibrary.fromSource(
          asset,
          await buildStep.readAsString(asset),
        );
        if (moduleLibrary.hasMain && moduleLibrary.isEntryPoint) {
          // We must save the main entrypoint as the recompilation target for
          // the Frontend Server before any JS files are emitted.
          frontendServerState.entrypointAssetId = asset;
          webEntrypointJson['entrypoint'] = asset.toString();
          break;
        }
      }
    }

    await buildStep.writeAsString(
      webEntrypointAsset,
      jsonEncode(webEntrypointJson),
    );
  }
}

/// A builder that generates a summary file required for webdev to perform hot
/// reloads and hot restarts.
class DdcReloadSummaryWriter implements PostProcessBuilder {
  /// Indicates that we're targeting the DDC Library Bundle module system
  /// running with the Frontend Server.
  ///
  /// This builder is a no-op if [usesWebHotReload] is not set.
  final bool usesWebHotReload;

  DdcReloadSummaryWriter({this.usesWebHotReload = false});

  @override
  final inputExtensions = const ['.dart', '.ddc.js'];

  @override
  Future<void> build(PostProcessBuildStep buildStep) async {
    if (!usesWebHotReload) return;

    final scratchSpace = await buildStep.fetchResource(scratchSpaceResource);
    final frontendServerState = await buildStep.fetchResource(
      frontendServerStateResource,
    );
    // Save the reload summary next to the entrypoint asset.
    final ddcReloadSummaryAsset = AssetId(
      frontendServerState.entrypointAssetId!.package,
      ddcReloadExtension,
    );

    if (frontendServerState.reloadedSources == null) {
      print('RECORDING ${scratchSpace.changedFilesInBuild}');
      frontendServerState.reloadedSources = [];
      for (final changedAsset in scratchSpace.changedFilesInBuild) {
        // Record the recompiled library in [reloadedSources].
        final reloadedModuleData = {
          'src': changedAsset.uri.toFilePath(),
          'module': ddcModuleName(changedAsset),
          'libraries': [ddcLibraryId(changedAsset)],
        };
        frontendServerState.reloadedSources!.add(reloadedModuleData);
      }
      // Can't write this since it might already exist from a previous build.
      // await buildStep.writeAsString(
      //   ddcReloadSummaryAsset,
      //   jsonEncode(frontendServerState.reloadedSources),
      // );
    }
  }
}

/// A builder that generates a summary file required for webdev to perform hot
/// reloads and hot restarts.
class DdcReloadSummaryDeleter implements PostProcessBuilder {
  /// Indicates that we're targeting the DDC Library Bundle module system
  /// running with the Frontend Server.
  ///
  /// This builder is a no-op if [usesWebHotReload] is not set.
  final bool usesWebHotReload;

  DdcReloadSummaryDeleter({this.usesWebHotReload = false});

  @override
  final inputExtensions = const ['ddc.reload.json'];

  @override
  Future<void> build(PostProcessBuildStep buildStep) async {
    if (!usesWebHotReload) return;
    buildStep.deletePrimaryInput();
  }
}
