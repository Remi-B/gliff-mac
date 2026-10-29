# Native tests

Task 06 adds the session/view-model test target and shared scheme test action. The
bridge's import, callback, buffer and teardown tests live in the `GliffCore` package
(`macos/Packages/GliffCore/Tests`, run by `swift test`). This directory reserves the
app's own native test ownership.
