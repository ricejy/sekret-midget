import SwiftUI
import UIKit

@MainActor
final class HarnessAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

@main
struct GuardrailHarnessApp: App {
    @UIApplicationDelegateAdaptor(HarnessAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = HarnessStore()
    @State private var privacyShieldVisible = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(store)

                if privacyShieldVisible {
                    PrivacyShieldView()
                }
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    privacyShieldVisible = false
                case .inactive:
                    privacyShieldVisible = true
                case .background:
                    privacyShieldVisible = true
                    store.clearPrivateSession()
                @unknown default:
                    privacyShieldVisible = true
                    store.clearPrivateSession()
                }
            }
        }
    }
}

private struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                Text("Private session hidden")
                    .font(.headline)
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Private content hidden while the app is inactive")
    }
}
