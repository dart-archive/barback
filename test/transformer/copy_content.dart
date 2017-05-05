// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:barback/barback.dart';

/// A transformer that copies the contents of `inputId` into `outputId`.
class CopyContentTransformer extends Transformer {
  final AssetId inputId;
  final AssetId outputId;

  CopyContentTransformer(String input, String output)
      : inputId = new AssetId.parse(input),
        outputId = new AssetId.parse(output);

  @override
  apply(Transform transform) async {
    transform.addOutput(new Asset.fromString(
        outputId, await transform.readInputAsString(inputId)));
  }
}
