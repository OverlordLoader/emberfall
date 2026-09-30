import Foundation
import Combine
import UIKit
import GoogleMobileAds

/// Owns all ad behavior for Emberfall Kingdom:
/// - Rewarded: "Watch an ad for a free 15-min speedup", offered from any
///   build/train queue. Explicit opt-in, never forced.
/// - Interstitial: ONLY on the non-gameplay transition of leaving Settings
///   back to the city, at most once per session, never in the first two
///   sessions, never within 60s of launch. Never mid-build/march/battle.
///
/// Every ad path checks StoreManager.shared.removeAds first. Ads fail
/// gracefully offline: nothing blocks gameplay, loads retry in background.
///
/// Written against the Google Mobile Ads 11.x API surface (GAD-prefixed
/// names, present(fromRootViewController:)). The Xcode project pins the SPM
/// package to upToNextMajorVersion from 11.0.0 — do not bump major without
/// rewriting this file.
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    #if DEBUG
    // Google's official sample IDs — test ads in debug builds.
    static let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"
    static let interstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
    #else
    // TODO(Henry): replace with real AdMob IDs from apps.admob.com before release.
    // Create one "Rewarded" and one "Interstitial" ad unit for the Emberfall app.
    static let rewardedAdUnitID = "ca-app-pub-XXXXXXXXXXXXXXXX/RRRRRRRRRR"
    static let interstitialAdUnitID = "ca-app-pub-XXXXXXXXXXXXXXXX/IIIIIIIIII"
    #endif

    @Published private(set) var rewardedReady = false

    private var rewardedAd: GADRewardedAd?
    private var interstitialAd: GADInterstitialAd?
    private var pendingRewardCompletion: ((Bool) -> Void)?
    private var rewardEarned = false
    private var interstitialShownThisSession = false
    private let launchDate = Date()

    private enum Keys {
        static let sessions = "emberfall.ads.sessions"
    }

    private override init() { super.init() }

    /// Call once at app launch.
    func configure() {
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        let d = UserDefaults.standard
        d.set(d.integer(forKey: Keys.sessions) + 1, forKey: Keys.sessions)
        loadRewarded()
        loadInterstitial()
    }

    // MARK: - Rewarded (free speedup)

    private func loadRewarded() {
        guard !StoreManager.shared.removeAds else { return }
        GADRewardedAd.load(withAdUnitID: Self.rewardedAdUnitID, request: GADRequest()) { [weak self] ad, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let ad {
                    ad.fullScreenContentDelegate = self
                    self.rewardedAd = ad
                    self.rewardedReady = true
                } else {
                    self.rewardedReady = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        self?.loadRewarded()
                    }
                }
            }
        }
    }

    /// completion(true) only if the reward was earned. completion(false) on
    /// any failure — the caller simply skips the speedup.
    func showRewardedForSpeedup(completion: @escaping (Bool) -> Void) {
        guard !StoreManager.shared.removeAds,
              let ad = rewardedAd,
              let vc = topViewController() else {
            completion(false)
            loadRewarded()
            return
        }
        rewardEarned = false
        pendingRewardCompletion = completion
        rewardedReady = false
        ad.present(fromRootViewController: vc, userDidEarnRewardHandler: { [weak self] in
            self?.rewardEarned = true
        })
    }

    // MARK: - Interstitial (Settings → city transition only)

    private func loadInterstitial() {
        guard !StoreManager.shared.removeAds else { return }
        GADInterstitialAd.load(withAdUnitID: Self.interstitialAdUnitID, request: GADRequest()) { [weak self] ad, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let ad {
                    ad.fullScreenContentDelegate = self
                    self.interstitialAd = ad
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        self?.loadInterstitial()
                    }
                }
            }
        }
    }

    /// Call when leaving Settings for the city. Shows at most once per
    /// session, never in the first 2 sessions, never within 60s of launch.
    func showInterstitialIfDue() {
        let sessions = UserDefaults.standard.integer(forKey: Keys.sessions)
        guard !StoreManager.shared.removeAds,
              !interstitialShownThisSession,
              sessions > 2,
              Date().timeIntervalSince(launchDate) > 60,
              let ad = interstitialAd,
              let vc = topViewController() else { return }
        interstitialShownThisSession = true
        ad.present(fromRootViewController: vc)
    }

    // MARK: - Helpers

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController {
                var top = root
                while let presented = top.presentedViewController { top = presented }
                return top
            }
        }
        return nil
    }
}

extension AdsManager: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        if ad as? GADRewardedAd != nil {
            rewardedAd = nil
            let completion = pendingRewardCompletion
            pendingRewardCompletion = nil
            let earned = rewardEarned
            rewardEarned = false
            completion?(earned)
            loadRewarded()
        } else if ad as? GADInterstitialAd != nil {
            interstitialAd = nil
            loadInterstitial()
        }
    }

    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        if ad as? GADRewardedAd != nil {
            rewardedAd = nil
            pendingRewardCompletion?(false)
            pendingRewardCompletion = nil
            rewardEarned = false
            loadRewarded()
        } else if ad as? GADInterstitialAd != nil {
            interstitialAd = nil
            loadInterstitial()
        }
    }
}
