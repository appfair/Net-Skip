// SPDX-License-Identifier: GPL-2.0-or-later
//
// Default-browser helpers — Android and iOS. On Android the AOSP
// BROWSER role contract is fulfilled by (1) declaring a host-less
// ACTION_VIEW intent-filter for http/https in AndroidManifest.xml
// and (2) being granted the role via `RoleManager`. On iOS there is
// no in-app API to set the default; the user has to flip "Default
// Browser App" in the system Settings entry for our app, so the
// affordance is a deep-link via `UIApplication.openSettingsURLString`.

import Foundation
import SwiftUI

#if SKIP
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
#elseif canImport(UIKit)
import UIKit
#endif

/// Status of Net-Skip's default-browser role on the current device.
public enum DefaultBrowserStatus: Equatable, Sendable {
    /// Android API < 29 (no `RoleManager`) — the user has to use the
    /// system "Default apps" picker. We surface that path instead of
    /// the in-app prompt.
    case roleUnavailable
    /// The device supports the concept of a default browser but
    /// Net-Skip isn't (necessarily) holding it. On Android this is
    /// known from `RoleManager.isRoleHeld`; on iOS we can't query
    /// it, so we always return this state and let the user decide
    /// whether to bother visiting Settings.
    case eligibleButNotDefault
    /// Net-Skip currently holds the BROWSER role. Android only —
    /// iOS doesn't expose a way to check.
    case held
}

@MainActor
public enum DefaultBrowser {
    /// Snapshot the current status. Cheap — just two boolean calls
    /// into `RoleManager`. Re-read it every time the Settings view
    /// renders so coming back from the system picker reflects the
    /// new state immediately.
    public static func currentStatus() -> DefaultBrowserStatus {
        #if SKIP
        guard Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q else {
            return .roleUnavailable
        }
        let ctx: Context = ProcessInfo.processInfo.androidContext
        let rm = ctx.getSystemService(Context.ROLE_SERVICE) as? RoleManager
        guard let rm = rm else { return .roleUnavailable }
        if !rm.isRoleAvailable(RoleManager.ROLE_BROWSER) {
            return .roleUnavailable
        }
        return rm.isRoleHeld(RoleManager.ROLE_BROWSER) ? .held : .eligibleButNotDefault
        #else
        // iOS has no API to check whether we're the default browser
        // (the picker lives in Settings → Net Skip → Default Browser
        // App and the system never reports back). Assume not-default
        // so the affordance stays visible; it's a cheap deep-link if
        // the user wants to confirm or change the setting.
        return .eligibleButNotDefault
        #endif
    }

    /// Take the user to wherever the system handles "default browser"
    /// on this platform.
    ///
    /// - Android API 29+: the focused single-app confirmation dialog
    ///   from `RoleManager.createRequestRoleIntent(ROLE_BROWSER)`.
    /// - Android API 28-: the multi-app "Default apps" Settings
    ///   screen — RoleManager doesn't exist yet, so that's the only
    ///   path the platform offers.
    /// - iOS: deep-link into Settings → Net Skip via
    ///   `UIApplication.openSettingsURLString`. iOS 14+ shows the
    ///   "Default Browser App" row inside that screen for any app
    ///   that has been granted the entitlement; if Apple has not yet
    ///   approved Net-Skip's entitlement request the user will land
    ///   on the app's Settings entry with general toggles but no
    ///   default-browser row — at which point this affordance can't
    ///   do better than the OS itself.
    public static func requestRole() {
        #if SKIP
        let ctx: Context = ProcessInfo.processInfo.androidContext
        if Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
           let rm = ctx.getSystemService(Context.ROLE_SERVICE) as? RoleManager,
           rm.isRoleAvailable(RoleManager.ROLE_BROWSER) {
            // RoleManager docs require launching from an Activity so
            // the result can come back, but since we don't need the
            // result — the next `currentStatus()` read tells us what
            // happened — launching from the app context with
            // FLAG_ACTIVITY_NEW_TASK works for the dialog itself.
            // Prefer the live activity when we have one; that's the
            // path the AOSP docs describe.
            let intent = rm.createRequestRoleIntent(RoleManager.ROLE_BROWSER)
            // RequestRoleActivity reads `getCallingPackage()` to know
            // which app to grant the role to — that field is ONLY
            // populated when the intent is launched via
            // `startActivityForResult`. Plain `startActivity` from an
            // Activity context (let alone the Application context)
            // hands the role UI a null package and it bails out
            // logging "Package name cannot be null or empty". We
            // don't actually consume the result — the next
            // `currentStatus()` read tells us what happened — but
            // the call shape matters for the identity plumbing.
            if let activity = UIApplication.shared.androidActivity {
                activity.startActivityForResult(intent, /*requestCode*/ 4276)
            } else {
                // No live Activity (shouldn't happen from the Settings
                // sheet) — fall back to the system Default Apps screen.
                let fallback = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(fallback)
            }
            return
        }
        // Pre-Q fallback: open the system "Default apps" screen and
        // let the user navigate to "Browser app" themselves.
        let fallback = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
        fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        do {
            ctx.startActivity(fallback)
        } catch {
            logger.log("Could not open default-apps settings: \(error)")
        }
        #elseif canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }
}
