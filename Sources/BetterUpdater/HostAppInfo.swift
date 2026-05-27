//
//  HostAppInfo.swift
//  BetterUpdater
//
//  Reads version/build of the HOST app from `Bundle.main`. This is correct in
//  a package: the library runs in the host app's process, so `Bundle.main` is
//  the consuming app. Internal on purpose — must not collide with each app's
//  own `AppInfo`.
//

import Foundation

enum HostAppInfo {
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
}
