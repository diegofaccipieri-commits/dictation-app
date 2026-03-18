import Foundation
import AppKit

class UpdateChecker {
    static let repoOwner = "diegofaccipieri-commits"
    static let repoName  = "dictation-app"
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    private static let lastUpdateAttemptKey = "lastUpdateAttemptVersion"

    // Call on launch (silent) and from menu (userInitiated shows "already up to date" alert).
    static func checkForUpdates(userInitiated: Bool = false) {
        // Anti-loop: if we just updated TO this version, skip the automatic check.
        // Manual checks (userInitiated) always proceed.
        if !userInitiated {
            let lastAttempt = UserDefaults.standard.string(forKey: lastUpdateAttemptKey) ?? ""
            if lastAttempt == currentVersion {
                NSLog("DictationApp: skipping auto-update check — already attempted update to %@", currentVersion)
                UserDefaults.standard.removeObject(forKey: lastUpdateAttemptKey)
                return
            }
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if userInitiated {
                    DispatchQueue.main.async { showAlert(title: "Check Failed", message: "Could not connect to the update server.") }
                }
                return
            }

            let latest  = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = currentVersion

            if isNewer(latest, than: current) {
                let assets     = json["assets"] as? [[String: Any]] ?? []
                let zipAsset   = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                let downloadURL = zipAsset?["browser_download_url"] as? String

                DispatchQueue.main.async { promptUpdate(from: current, to: latest, downloadURL: downloadURL) }
            } else if userInitiated {
                DispatchQueue.main.async {
                    showAlert(title: "Up to Date", message: "You're running the latest version (\(current)).")
                }
            }
        }.resume()
    }

    // MARK: - Private

    private static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    private static func promptUpdate(from current: String, to latest: String, downloadURL: String?) {
        let alert = NSAlert()
        alert.messageText      = "Update Available — v\(latest)"
        alert.informativeText  = "You have v\(current). Download and install v\(latest) now?"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let urlString = downloadURL, let url = URL(string: urlString) {
            // Mark target version so the relaunched app skips one auto-check (anti-loop).
            UserDefaults.standard.set(latest, forKey: lastUpdateAttemptKey)
            downloadAndInstall(from: url, targetVersion: latest)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!)
        }
    }

    private static func downloadAndInstall(from url: URL, targetVersion: String) {
        // Determine where the running app lives — replace in-place, not hardcoded /Applications.
        let currentAppPath = Bundle.main.bundlePath
        let destination = URL(fileURLWithPath: currentAppPath)

        NSLog("DictationApp: downloading update from %@", url.absoluteString)
        NSLog("DictationApp: will replace app at %@ (current: %@, target: %@)", currentAppPath, currentVersion, targetVersion)

        URLSession.shared.downloadTask(with: url) { location, _, error in
            guard let location, error == nil else {
                NSLog("DictationApp: download failed — %@", error?.localizedDescription ?? "unknown")
                UserDefaults.standard.removeObject(forKey: lastUpdateAttemptKey)
                DispatchQueue.main.async { showAlert(title: "Download Failed", message: "Please try again later.") }
                return
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let zipPath = tempDir.appendingPathComponent("DictationApp.zip")
            try? FileManager.default.moveItem(at: location, to: zipPath)

            // Unzip
            let unzip = Process()
            unzip.launchPath = "/usr/bin/unzip"
            unzip.arguments  = ["-o", "-q", zipPath.path, "-d", tempDir.path]
            unzip.launch(); unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                NSLog("DictationApp: unzip failed with status %d", unzip.terminationStatus)
                UserDefaults.standard.removeObject(forKey: lastUpdateAttemptKey)
                DispatchQueue.main.async { showAlert(title: "Install Failed", message: "Could not extract the update archive.") }
                return
            }

            // Locate the extracted .app
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                NSLog("DictationApp: no .app found in extracted archive — contents: %@", contents.description)
                UserDefaults.standard.removeObject(forKey: lastUpdateAttemptKey)
                DispatchQueue.main.async { showAlert(title: "Install Failed", message: "Could not find app in the downloaded archive.") }
                return
            }

            let newApp = tempDir.appendingPathComponent(appName)

            // Verify the downloaded app actually has the expected version
            let newPlist = newApp.appendingPathComponent("Contents/Info.plist")
            if let plistData = try? Data(contentsOf: newPlist),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let newVersion = plist["CFBundleShortVersionString"] as? String {
                NSLog("DictationApp: downloaded app reports version %@", newVersion)
                if newVersion == currentVersion {
                    NSLog("DictationApp: downloaded version (%@) same as current — aborting update to prevent loop", newVersion)
                    UserDefaults.standard.removeObject(forKey: lastUpdateAttemptKey)
                    DispatchQueue.main.async { showAlert(title: "Update Problem", message: "Downloaded version (\(newVersion)) is the same as the running version. No update needed.") }
                    return
                }
            } else {
                NSLog("DictationApp: WARNING — could not read version from downloaded app plist")
            }

            // Shell script: wait for app to quit, replace, flush LS cache, relaunch.
            let logFile = tempDir.appendingPathComponent("update.log")
            let script = """
            #!/bin/bash
            exec > "\(logFile.path)" 2>&1
            echo "Update script started at $(date)"

            # Wait for old process to fully exit (up to 10s)
            OLD_PID=\(ProcessInfo.processInfo.processIdentifier)
            for i in $(seq 1 20); do
                if ! kill -0 $OLD_PID 2>/dev/null; then break; fi
                sleep 0.5
            done

            echo "Removing old app at \(destination.path)"
            rm -rf "\(destination.path)"
            if [ $? -ne 0 ]; then echo "ERROR: rm failed"; exit 1; fi

            echo "Copying new app from \(newApp.path)"
            cp -R "\(newApp.path)" "\(destination.path)"
            if [ $? -ne 0 ]; then echo "ERROR: cp failed"; exit 1; fi

            # Clear Launch Services cache so macOS picks up new version
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(destination.path)" 2>/dev/null

            echo "Relaunching app"
            open "\(destination.path)"
            echo "Update script done at $(date)"
            """
            let scriptPath = tempDir.appendingPathComponent("update.sh")
            try? script.write(to: scriptPath, atomically: true, encoding: .utf8)

            let chmod = Process()
            chmod.launchPath = "/bin/chmod"
            chmod.arguments  = ["+x", scriptPath.path]
            chmod.launch(); chmod.waitUntilExit()

            DispatchQueue.main.async {
                let launcher = Process()
                launcher.launchPath = "/bin/bash"
                launcher.arguments  = [scriptPath.path]
                launcher.launch()
                NSApp.terminate(nil)
            }
        }.resume()
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.runModal()
    }
}
