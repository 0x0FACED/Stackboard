import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instanceLockFileDescriptor: Int32 = -1

    /// Acquires a process-lifetime lock before clipboard monitoring and hotkeys start.
    static func enforceSingleInstance() {
        guard instanceLockFileDescriptor == -1 else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier
        let currentPID = getpid()
        let existingApplication = bundleIdentifier.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { $0.processIdentifier != currentPID && $0.isTerminated == false && $0.isFinishedLaunching }
        }

        // Reuse a running instance; the lock below arbitrates simultaneous launches.
        if let existingApplication {
            existingApplication.activate(options: [.activateIgnoringOtherApps])
            exit(EXIT_SUCCESS)
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport.appendingPathComponent("Stackboard", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showStartupError(error.localizedDescription)
        }

        let descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            showStartupError(String(cString: strerror(errno)))
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                exit(EXIT_SUCCESS)
            }
            showStartupError(String(cString: strerror(lockError)))
        }

        instanceLockFileDescriptor = descriptor
    }

    private static func showStartupError(_ message: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stackboard could not start."
        alert.informativeText = message
        alert.runModal()
        exit(EXIT_FAILURE)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AppController.shared
    }
}
