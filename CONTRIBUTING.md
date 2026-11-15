# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Before you start

For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Building and testing

```sh
swift build
swift test
```

The Mac app is built and packaged by `scripts/release.sh`; the iPhone app is an XcodeGen project in `ios/` (`xcodegen generate`, then open `TerminessPhone.xcodeproj`).

## Sign off your commits

Every commit needs a `Signed-off-by` line, which certifies that you wrote the change or have the right to submit it under the project's licence (the [Developer Certificate of Origin](https://developercertificate.org)). Add it with:

```sh
git commit -s
```

## Licence

By contributing, you agree that your contribution is licensed under the Apache License 2.0, the same as the rest of the project.
