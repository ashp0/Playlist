// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

/// Minimal local re-implementation of the `Then` micro-library
/// (github.com/devxoul/Then, MIT), which Brave depends on via SPM.
///
/// Brave's Playlist sources use `.then { ... }` pervasively for inline
/// configuration. Re-declaring the two lines here keeps the adapted code
/// byte-for-byte closer to the original while leaving this project free of
/// third-party package dependencies — which matters for sideloading, where
/// an unresolvable SPM checkout is a hard build failure.
public protocol Then {}

extension Then where Self: AnyObject {
  /// Configures the receiver in place and returns it.
  @inlinable
  public func then(_ block: (Self) throws -> Void) rethrows -> Self {
    try block(self)
    return self
  }
}

extension Then where Self: Any {
  /// Returns a configured copy of the receiver.
  @inlinable
  public func then(_ block: (inout Self) throws -> Void) rethrows -> Self {
    var copy = self
    try block(&copy)
    return copy
  }
}

extension NSObject: Then {}
extension URLRequest: Then {}
extension CGRect: Then {}
extension CGPoint: Then {}
extension CGSize: Then {}
