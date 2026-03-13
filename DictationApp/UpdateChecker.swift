import Foundation
import AppKit

class UpdateChecker {
    static let repoOwner = "diegofaccipieri-commits"
    static let repoName  = "dictation-app"
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

    // Call on launch (silent) and from menu (userInitiated shows "already up to date" alert).
    static func checkForUpdates(userInitiated: Bool = false) {
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
            downloadAndInstall(from: url)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!)
        }
    }

    private static func downloadAndInstall(from url: URL) {
        DispatchQueue.main.async {
            showAlert(title: "Downloading…", message: "The app will restart automatically when the update is ready.")
        }

        URLSession.shared.downloadTask(with: url) { location, _, error in
            guard let location, error == nil else {
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
            unzip.arguments  = ["-q", zipPath.path, "-d", tempDir.path]
            unzip.launch(); unzip.waitUntilExit()

            // Locate the extracted .app
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                DispatchQueue.main.async { showAlert(title: "Install Failed", message: "Could not find app in the downloaded archive.") }
                return
            }

            let newApp      = tempDir.appendingPathComponent(appName)
            let destination = URL(fileURLWithPath: "/Applications/DictationApp.app")

            // Shell script runs after the app quits: replaces the old binary and relaunches.
            let script = """
            #!/bin/bash
            sleep 2
            rm -rf "\(destination.path)"
            cp -R "\(newApp.path)" "\(destination.path)"
            open "\(destination.path)"
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
