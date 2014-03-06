// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library barback.asset_cascade;

import 'dart:async';
import 'dart:collection';

import 'asset.dart';
import 'asset_id.dart';
import 'asset_node.dart';
import 'asset_set.dart';
import 'log.dart';
import 'cancelable_future.dart';
import 'errors.dart';
import 'package_graph.dart';
import 'phase.dart';
import 'stream_pool.dart';
import 'transformer.dart';

/// The asset cascade for an individual package.
///
/// This keeps track of which [Transformer]s are applied to which assets, and
/// re-runs those transformers when their dependencies change. The transformed
/// asset nodes are accessible via [getAssetNode].
///
/// A cascade consists of one or more [Phases], each of which has one or more
/// [Transformer]s that run in parallel, potentially on the same inputs. The
/// inputs of the first phase are the source assets for this cascade's package.
/// The inputs of each successive phase are the outputs of the previous phase,
/// as well as any assets that haven't yet been transformed.
class AssetCascade {
  /// The name of the package whose assets are managed.
  final String package;

  /// The [PackageGraph] that tracks all [AssetCascade]s for all dependencies of
  /// the current app.
  final PackageGraph graph;

  /// The controllers for the [AssetNode]s that provide information about this
  /// cascade's package's source assets.
  final _sourceControllerMap = new Map<AssetId, AssetNodeController>();

  /// Futures for source assets that are currently being loaded.
  ///
  /// These futures are cancelable so that if an asset is updated after a load
  /// has been kicked off, the previous load can be ignored in favor of a new
  /// one.
  final _loadingSources = new Map<AssetId, CancelableFuture<Asset>>();

  final _phases = <Phase>[];

  /// A stream that emits any errors from the cascade or the transformers.
  ///
  /// This emits errors as they're detected. If an error occurs in one part of
  /// the cascade, unrelated parts will continue building.
  Stream<BarbackException> get errors => _errorsController.stream;
  final _errorsController =
      new StreamController<BarbackException>.broadcast(sync: true);

  /// A stream that emits an event whenever any transforms in this cascade logs
  /// an entry.
  Stream<LogEntry> get onLog => _onLogPool.stream;
  final _onLogPool = new StreamPool<LogEntry>.broadcast();

  /// Whether [this] is dirty and still has more processing to do.
  bool get isDirty => _phases.any((phase) => phase.isDirty);

  /// A stream that emits an event whenever [this] is no longer dirty.
  ///
  /// This is synchronous in order to guarantee that it will emit an event as
  /// soon as [isDirty] flips from `true` to `false`.
  Stream get onDone => _onDoneController.stream;
  final _onDoneController = new StreamController.broadcast(sync: true);

  /// Returns all currently-available output assets from this cascade.
  AssetSet get availableOutputs =>
    new AssetSet.from(_phases.last.availableOutputs.map((node) => node.asset));

  /// A map of asset ids to completers for [getAssetNode] requests.
  ///
  /// If an asset node is requested before it's available, we put a completer in
  /// this map to wait for the asset to be generated. If it's not generated, the
  /// completer should complete to `null`.
  final _pendingAssetRequests = new Map<AssetId, Completer<AssetNode>>();

  /// Creates a new [AssetCascade].
  ///
  /// It loads source assets within [package] using [provider].
  AssetCascade(this.graph, this.package) {
    _addPhase(new Phase(this, package));
  }

  /// Gets the asset identified by [id].
  ///
  /// If [id] is for a generated or transformed asset, this will wait until it
  /// has been created and return it. This means that the returned asset will
  /// always be [AssetState.AVAILABLE].
  ///
  /// If the asset cannot be found, returns null.
  Future<AssetNode> getAssetNode(AssetId id) {
    assert(id.package == package);

    // TODO(rnystrom): Waiting for the entire build to complete is unnecessary
    // in some cases. Should optimize:
    // * [id] may be generated before the compilation is finished. We should
    //   be able to quickly check whether there are any more in-place
    //   transformations that can be run on it. If not, we can return it early.
    // * If [id] has never been generated and all active transformers provide
    //   metadata about the file names of assets it can emit, we can prove that
    //   none of them can emit [id] and fail early.
    return _phases.last.getOutput(id).then((node) {
      if (node != null) {
        // If the requested asset is available, we can just return it.
        if (node.state.isAvailable) return node;

        // If the requested asset exists but isn't yet available, wait to see if
        // it becomes available. If it's removed before becoming available, try
        // again, since it could be generated again.
        node.force();
        return node.whenAvailable((_) => node).catchError((error) {
          if (error is! AssetNotFoundException) throw error;
          return getAssetNode(id);
        });
      }

      // If the cascade isn't dirty, the phase won't generate the requested
      // asset in the future.
      if (!isDirty) return null;

      // If the cascade is dirty, store a completer for the asset node. If it's
      // generated in the future, we'll complete this completer.
      var completer = _pendingAssetRequests.putIfAbsent(id,
          () => new Completer.sync());
      return completer.future;
    });
  }

  /// Adds [sources] to the graph's known set of source assets.
  ///
  /// Begins applying any transforms that can consume any of the sources. If a
  /// given source is already known, it is considered modified and all
  /// transforms that use it will be re-applied.
  void updateSources(Iterable<AssetId> sources) {
    for (var id in sources) {
      var controller = _sourceControllerMap[id];
      if (controller != null) {
        controller.setDirty();
      } else {
        _sourceControllerMap[id] = new AssetNodeController(id);
        _phases.first.addInput(_sourceControllerMap[id].node);
      }

      // If this source was already loading, cancel the old load, since it may
      // return out-of-date contents for the asset.
      if (_loadingSources.containsKey(id)) _loadingSources[id].cancel();

      _loadingSources[id] =
          new CancelableFuture<Asset>(graph.provider.getAsset(id));
      _loadingSources[id].whenComplete(() {
        _loadingSources.remove(id);
      }).then((asset) {
        var controller = _sourceControllerMap[id].setAvailable(asset);
      }).catchError((error, stack) {
        reportError(new AssetLoadException(id, error, stack));

        // TODO(nweiz): propagate error information through asset nodes.
        _sourceControllerMap.remove(id).setRemoved();
      });
    }
  }

  /// Removes [removed] from the graph's known set of source assets.
  void removeSources(Iterable<AssetId> removed) {
    removed.forEach((id) {
      // If the source was being loaded, cancel that load.
      if (_loadingSources.containsKey(id)) _loadingSources.remove(id).cancel();

      var controller = _sourceControllerMap.remove(id);
      // Don't choke if an id is double-removed for some reason.
      if (controller != null) controller.setRemoved();
    });
  }

  /// Sets this cascade's transformer phases to [transformers].
  ///
  /// Elements of the inner iterable of [transformers] must be either
  /// [Transformer]s or [TransformerGroup]s.
  void updateTransformers(Iterable<Iterable> transformersIterable) {
    var transformers = transformersIterable.toList();

    for (var i = 0; i < transformers.length; i++) {
      if (_phases.length > i) {
        _phases[i].updateTransformers(transformers[i]);
        continue;
      }

      var phase = _phases.last.addPhase();
      _addPhase(phase);
      phase.updateTransformers(transformers[i]);
    }

    if (transformers.length == 0) {
      _phases.last.updateTransformers([]);
    } else if (transformers.length < _phases.length) {
      _phases[transformers.length - 1].removeFollowing();
      _phases.removeRange(transformers.length, _phases.length);
    }
  }

  /// Force all [LazyTransformer]s' transforms in this cascade to begin
  /// producing concrete assets.
  void forceAllTransforms() {
    for (var phase in _phases) {
      phase.forceAllTransforms();
    }
  }

  void reportError(BarbackException error) {
    _errorsController.add(error);
  }

  /// Add [phase] to the end of [_phases] and watch its streams.
  void _addPhase(Phase phase) {
    _onLogPool.add(phase.onLog);
    phase.onAsset.listen(_providePendingAsset);

    phase.onDone.listen((_) {
      if (isDirty) return;

      // This cascade has finished building. If anyone's still waiting for
      // assets, cut off the wait; we won't be generating them, at least until a
      // source asset changes.
      for (var completer in _pendingAssetRequests.values) {
        completer.complete(null);
      }
      _pendingAssetRequests.clear();
      _onDoneController.add(null);
    });

    _phases.add(phase);
  }

  /// Provide an asset to a pending [getAssetNode] call.
  void _providePendingAsset(AssetNode asset) {
    // If anyone's waiting for this asset, provide it to them.
    var request = _pendingAssetRequests.remove(asset.id);
    if (request == null) return;

    if (asset.state.isAvailable) {
      request.complete(asset);
      return;
    }

    // A lazy asset may be emitted while still dirty. If so, we wait until
    // it's either available or removed before trying again to access it. We
    // retry the entire [getAsset] process because the state of the graph may
    // have changed dramatically by the time it's available.
    assert(asset.state.isDirty);
    asset.force();
    asset.whenStateChanges()
        .then((_) => getAssetNode(asset.id))
        .then(request.complete)
        .catchError(request.completeError);
  }

  String toString() => "cascade for $package";
}
