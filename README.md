**DEPRECATED**

The [pub][] transformer system will be removed in Dart 2.
See the [Dart 2 Migration Guide](https://webdev.dartlang.org/dart-2) for
guidance.

---

Barback is an asset build system. It is the library underlying
[pub][]'s asset transformers in
`pub build` and `pub serve`.

Given a set of input files and a set of transformations (think compilers,
preprocessors and the like), it will automatically apply the appropriate
transforms and generate output files. When inputs are modified, it automatically
runs the transforms that are affected.

To learn more, see [here][].

[pub]: https://www.dartlang.org/tools/pub/get-started
[here]: https://www.dartlang.org/tools/pub/assets-and-transformers
