# Third-party notices

This application's source is MIT licensed; see `LICENSE`.

The `vendor/gliff` Git submodule contains
[Gliff by its upstream contributors](https://github.com/omacom/gliff), distributed
under the MIT license. Its original notice, including **Copyright (c) 2026 Kevin
McConnell**, remains in `vendor/gliff/LICENSE`. Do not replace or remove it.

The initial app links upstream protocol/transport crates through Cargo path
dependencies. The application does not maintain copies of the Linux client/server.
`upstream-revision` records the vendored source used by each build.

Cargo/Swift dependencies retain their own licenses. Task 13 generates the complete
distribution notices from the resolved release dependencies and records any
downstream patch divergence before shipping an application binary.
