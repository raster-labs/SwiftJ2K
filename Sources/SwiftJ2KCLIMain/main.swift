// SPDX-License-Identifier: Apache-2.0
//
// swiftj2k-cli executable entry point. Library code returns exit statuses;
// this executable target alone terminates the process.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SwiftJ2KCLI

exit(drive())
