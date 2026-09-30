#!/usr/bin/env python3
"""Regenerate Emberfall.xcodeproj/project.pbxproj and the Emberfall.xcscheme.

Run from the repo root:  python3 tools/gen_pbxproj.py
The output is deterministic; commit the results.

Native Swift (SwiftUI + SpriteKit), iOS 17+, portrait-only, iPhone.
Theme content (Theme/Themes/*.json) and the offline tuning config
(Config/offline_config.json) ship as bundled resources — that is the
reskin contract: a new variant adds JSON + art + bundle ID, zero logic.

Sign in with Apple is wired via Emberfall.entitlements
(CODE_SIGN_ENTITLEMENTS); the App Store provisioning profile used by the
release script must include the capability.

Google Mobile Ads is pinned to the 11.x line (upToNextMajorVersion from
11.0.0) from the official swift-package-manager-google-mobile-ads package.
GMA 12.x renamed Swift API labels and 13.x removed the GAD prefix — do not
bump the major version without rewriting AdsManager.swift.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJ_DIR = ROOT / "Emberfall.xcodeproj"
SCHEME_DIR = PROJ_DIR / "xcshareddata/xcschemes"

APP_NAME = "Emberfall"
BUNDLE_ID = "app.emberfall.game"

# (relative path, group path segments)
SWIFT_SOURCES = [
    ("EmberfallApp.swift", []),
    ("Theme/ThemePack.swift", ["Theme"]),
    ("Net/Models.swift", ["Net"]),
    ("Net/KeychainHelper.swift", ["Net"]),
    ("Net/APIClient.swift", ["Net"]),
    ("Net/WSClient.swift", ["Net"]),
    ("Net/LocalSim.swift", ["Net"]),
    ("Game/GameState.swift", ["Game"]),
    ("Game/StoreManager.swift", ["Game"]),
    ("Game/AdsManager.swift", ["Game"]),
    ("Game/Haptics.swift", ["Game"]),
    ("Game/SoundManager.swift", ["Game"]),
    ("Game/CityScene.swift", ["Game"]),
    ("Views/UIHelpers.swift", ["Views"]),
    ("Views/RootView.swift", ["Views"]),
    ("Views/OnboardingView.swift", ["Views"]),
    ("Views/CityView.swift", ["Views"]),
    ("Views/MapView.swift", ["Views"]),
    ("Views/SummonView.swift", ["Views"]),
    ("Views/QuestsView.swift", ["Views"]),
    ("Views/SettingsView.swift", ["Views"]),
]
# (relative path, lastKnownFileType, group segments)
RESOURCE_FILES = [
    ("Assets.xcassets", "wrapper.assetcatalog", []),
    ("PrivacyInfo.xcprivacy", "text.plist.xml", []),
    ("Theme/Themes/emberfall.json", "text.json", ["Theme", "Themes"]),
    ("Config/offline_config.json", "text.json", ["Config"]),
]
ENTITLEMENTS = "Emberfall.entitlements"
FRAMEWORKS = ["SpriteKit.framework", "AVFoundation.framework", "StoreKit.framework",
              "AuthenticationServices.framework"]

SPM_PACKAGES = [
    {
        "name": "swift-package-manager-google-mobile-ads",
        "url": "https://github.com/googleads/swift-package-manager-google-mobile-ads",
        "kind": "upToNextMajorVersion",
        "minimumVersion": "11.0.0",
        "products": ["GoogleMobileAds"],
    },
]

_ids = {}
_counter = [0]

def nid(name):
    if name not in _ids:
        _counter[0] += 1
        _ids[name] = "%024X" % _counter[0]
    return _ids[name]

def main():
    missing = [s for s, _ in SWIFT_SOURCES if not (ROOT / APP_NAME / s).exists()]
    missing += [r for r, _, _ in RESOURCE_FILES if not (ROOT / APP_NAME / r).exists()]
    for extra in ["Info.plist", ENTITLEMENTS]:
        if not (ROOT / APP_NAME / extra).exists():
            missing.append(extra)
    if missing:
        raise SystemExit(f"gen_pbxproj: missing files: {missing}")

    L = []
    a = L.append
    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")

    # ---- file references ----
    for src, _ in SWIFT_SOURCES:
        fid = nid("file:" + src)
        a(f"\t\t{fid} /* {src} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {src}; sourceTree = \"<group>\"; }};")
    for res, ftype, _ in RESOURCE_FILES:
        fid = nid("file:" + res)
        a(f"\t\t{fid} /* {res} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {res}; sourceTree = \"<group>\"; }};")
    plist_id = nid("file:Info.plist")
    a(f"\t\t{plist_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    ent_id = nid("file:" + ENTITLEMENTS)
    a(f"\t\t{ent_id} /* {ENTITLEMENTS} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {ENTITLEMENTS}; sourceTree = \"<group>\"; }};")
    for fw in FRAMEWORKS:
        fid = nid("file:" + fw)
        a(f"\t\t{fid} /* {fw} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw}; path = System/Library/Frameworks/{fw}; sourceTree = SDKROOT; }};")
    app_product_id = nid("product:App.app")
    a(f"\t\t{app_product_id} /* {APP_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    # ---- build files ----
    for src, _ in SWIFT_SOURCES:
        bid = nid("build:" + src)
        a(f"\t\t{bid} /* {src} in Sources */ = {{isa = PBXBuildFile; fileRef = {nid('file:' + src)} /* {src} */; }};")
    for res, _, _ in RESOURCE_FILES:
        bid = nid("buildres:" + res)
        a(f"\t\t{bid} /* {res} in Resources */ = {{isa = PBXBuildFile; fileRef = {nid('file:' + res)} /* {res} */; }};")
    for fw in FRAMEWORKS:
        bid = nid("buildfw:" + fw)
        a(f"\t\t{bid} /* {fw} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {nid('file:' + fw)} /* {fw} */; }};")

    # ---- Swift packages ----
    spm_pkg_ids = []
    spm_dep_ids = []
    for pkg in SPM_PACKAGES:
        pkg_id = nid("spmpkg:" + pkg["name"])
        spm_pkg_ids.append(pkg_id)
        a(f"\t\t{pkg_id} /* XCRemoteSwiftPackageReference \"{pkg['name']}\" */ = {{isa = XCRemoteSwiftPackageReference; repositoryURL = \"{pkg['url']}\"; requirement = {{kind = {pkg['kind']}; minimumVersion = {pkg['minimumVersion']}; }}; }};")
        for product in pkg["products"]:
            dep_id = nid("spmdep:" + pkg["name"] + ":" + product)
            spm_dep_ids.append(dep_id)
            a(f"\t\t{dep_id} /* {product} */ = {{isa = XCSwiftPackageProductDependency; package = {pkg_id} /* XCRemoteSwiftPackageReference \"{pkg['name']}\" */; productName = {product}; }};")

    # ---- phases ----
    sources_id = nid("phase:sources")
    a(f"\t\t{sources_id} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (")
    for src, _ in SWIFT_SOURCES:
        a(f"\t\t\t{nid('build:' + src)} /* {src} in Sources */,")
    a("\t\t); runOnlyForDeploymentPostprocessing = 0; };")
    fw_id = nid("phase:frameworks")
    a(f"\t\t{fw_id} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (")
    for fw in FRAMEWORKS:
        a(f"\t\t\t{nid('buildfw:' + fw)} /* {fw} in Frameworks */,")
    a("\t\t); runOnlyForDeploymentPostprocessing = 0; };")
    res_id = nid("phase:resources")
    a(f"\t\t{res_id} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (")
    for res, _, _ in RESOURCE_FILES:
        a(f"\t\t\t{nid('buildres:' + res)} /* {res} in Resources */,")
    a("\t\t); runOnlyForDeploymentPostprocessing = 0; };")

    # ---- groups ----
    def group(gid_name, children, path=None, comment=""):
        gid = nid(gid_name)
        a(f"\t\t{gid} /* {comment} */ = {{isa = PBXGroup; children = (")
        for c in children:
            a(f"\t\t\t{c},")
        a("\t\t); " + (f"path = {path}; " if path else "") + 'sourceTree = "<group>"; };')
        return gid

    def children_in(*segs):
        out = []
        for src, g in SWIFT_SOURCES:
            if list(g) == list(segs):
                out.append(nid("file:" + src))
        for res, _, g in RESOURCE_FILES:
            if list(g) == list(segs):
                out.append(nid("file:" + res))
        return out

    group("group:Theme:Themes", children_in("Theme", "Themes"), comment="Themes")
    group("group:Theme", children_in("Theme") + [nid("group:Theme:Themes")], comment="Theme")
    group("group:Config", children_in("Config"), comment="Config")
    group("group:Net", children_in("Net"), comment="Net")
    group("group:Game", children_in("Game"), comment="Game")
    group("group:Views", children_in("Views"), comment="Views")
    root_children = ([nid("file:EmberfallApp.swift")] + [plist_id, ent_id]
                     + [nid("file:Assets.xcassets"), nid("file:PrivacyInfo.xcprivacy")]
                     + [nid("group:Theme"), nid("group:Config"), nid("group:Net"),
                        nid("group:Game"), nid("group:Views")])
    group("group:App", root_children, path=APP_NAME, comment=APP_NAME)
    group("group:Products", [app_product_id], comment="Products")
    main_gid = nid("group:main")
    a(f"\t\t{main_gid} = {{isa = PBXGroup; children = (")
    for c in [nid("group:App"), nid("group:Products")]:
        a(f"\t\t\t{c},")
    a('\t\t); sourceTree = "<group>"; };')

    # ---- target ----
    target_id = nid("target:" + APP_NAME)
    target_cfg_list = nid("cfglist:target")
    a(f"\t\t{target_id} /* {APP_NAME} */ = {{isa = PBXNativeTarget; buildConfigurationList = {target_cfg_list} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */; buildPhases = (")
    a(f"\t\t\t{sources_id} /* Sources */,")
    a(f"\t\t\t{fw_id} /* Frameworks */,")
    a(f"\t\t\t{res_id} /* Resources */,")
    a("\t\t); buildRules = (")
    a("\t\t); dependencies = (")
    a(f"\t\t); name = {APP_NAME};")
    if spm_dep_ids:
        a("\t\t\tpackageProductDependencies = (")
        for dep_id in spm_dep_ids:
            a(f"\t\t\t\t{dep_id} /* GoogleMobileAds */,")
        a("\t\t\t);")
    a(f"\t\tproductName = {APP_NAME}; productReference = " + app_product_id + f" /* {APP_NAME}.app */; productType = \"com.apple.product-type.application\"; }};")

    # ---- project ----
    project_id = nid("project")
    project_cfg_list = nid("cfglist:project")
    a(f"\t\t{project_id} /* Project object */ = {{")
    a("\t\t\tisa = PBXProject;")
    a(f"\t\t\tbuildConfigurationList = {project_cfg_list} /* Build configuration list for PBXProject */;")
    a("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    a("\t\t\tdevelopmentRegion = en;")
    a("\t\t\thasScannedForEncodings = 0;")
    if spm_pkg_ids:
        a("\t\t\tpackageReferences = (")
        for pkg_id in spm_pkg_ids:
            a(f"\t\t\t\t{pkg_id} /* XCRemoteSwiftPackageReference \"swift-package-manager-google-mobile-ads\" */,")
        a("\t\t\t);")
    a(f"\t\t\tmainGroup = {main_gid};")
    a("\t\t\tproductRefGroup = " + nid("group:Products") + " /* Products */;")
    a("\t\t\tprojectDirPath = \"\";")
    a("\t\t\tprojectRoot = \"\";")
    a("\t\t\ttargets = (")
    a(f"\t\t\t\t{target_id} /* {APP_NAME} */,")
    a("\t\t\t);")
    a("\t\t};")

    # ---- configurations ----
    def xcconfig(name, settings):
        cid = nid("config:" + name)
        a(f"\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = {{")
        for k, v in settings.items():
            a(f"\t\t\t\t{k} = {v};")
        a("\t\t\t};")
        a(f"\t\t\tname = {name.split(':')[1]};")
        a("\t\t\t};")
        return cid
    proj_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "CODE_SIGN_IDENTITY": '"iPhone Developer"',
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJ_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "MTL_FAST_MATH": "YES",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    proj_debug = dict(proj_common); proj_debug["MTL_ENABLE_DEBUG_INFO"] = "INCLUDE_SOURCE"
    proj_release = dict(proj_common); proj_release.update({"COPY_PHASE_STRIP": "NO", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "ENABLE_NS_ASSERTIONS": "NO", "MTL_ENABLE_DEBUG_INFO": "NO"})
    d1 = xcconfig("project:Debug", proj_debug)
    r1 = xcconfig("project:Release", proj_release)
    a(f"\t\t{project_cfg_list} /* Build configuration list for PBXProject */ = {{isa = XCConfigurationList; buildConfigurations = ({d1} /* Debug */, {r1} /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

    tgt_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": f"{APP_NAME}/{ENTITLEMENTS}",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": '""',
        "INFOPLIST_FILE": f"{APP_NAME}/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    tgt_debug = dict(tgt_common)
    tgt_release = dict(tgt_common); tgt_release["SWIFT_OPTIMIZATION_LEVEL"] = '"-O"'
    d2 = xcconfig("target:Debug", tgt_debug)
    r2 = xcconfig("target:Release", tgt_release)
    a(f"\t\t{target_cfg_list} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */ = {{isa = XCConfigurationList; buildConfigurations = ({d2} /* Debug */, {r2} /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

    a("\t};")
    a("\trootObject = " + project_id + " /* Project object */;")
    a("}")

    PROJ_DIR.mkdir(parents=True, exist_ok=True)
    (PROJ_DIR / "project.pbxproj").write_text("\n".join(L) + "\n")

    # ---- scheme ----
    SCHEME_DIR.mkdir(parents=True, exist_ok=True)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES" runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{APP_NAME}.app" BlueprintName = "{APP_NAME}" ReferencedContainer = "container:{APP_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES" shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{APP_NAME}.app" BlueprintName = "{APP_NAME}" ReferencedContainer = "container:{APP_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{APP_NAME}.app" BlueprintName = "{APP_NAME}" ReferencedContainer = "container:{APP_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (SCHEME_DIR / f"{APP_NAME}.xcscheme").write_text(scheme)
    print("wrote project.pbxproj and", f"{APP_NAME}.xcscheme")

if __name__ == "__main__":
    main()
