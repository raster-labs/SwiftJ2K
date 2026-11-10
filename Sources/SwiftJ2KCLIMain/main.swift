// SPDX-License-Identifier: MIT
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
