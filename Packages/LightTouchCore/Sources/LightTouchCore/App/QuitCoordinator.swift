import Foundation

/// Quit's ladder (the app delegate's applicationShouldTerminate): an erase or a recording holds it, a preparation
/// or unfinished device changes ask first, then every running device halts at once and quit waits for the last of
/// them, or for the budget. The questions and the halts are the caller's; `reply` answers AppKit's terminateLater.
public final class QuitCoordinator {
    public enum Answer: Equatable { case now, cancel, later }

    /// A terminateLater is outstanding: a second quit waits for it.
    public private(set) var awaitingTermination = false
    private var backstop: Task<Void, Never>?
    private let budget: TimeInterval
    private let reply: () -> Void

    public init(budget: TimeInterval, reply: @escaping () -> Void) {
        self.budget = budget
        self.reply = reply
    }

    /// One quit request. `finishRecording` is true when a recording holds the quit (it asks the user itself);
    /// `confirmPreparation` and `confirmChanges` ask; `cancelChanges` drops queued installs and transfers;
    /// `running` are the halts of the devices still running, each calling back once.
    public func shouldTerminate(erasing: Bool,
                                finishRecording: () -> Bool,
                                preparing: Int, confirmPreparation: (Int) -> Bool,
                                hasDevices: Bool,
                                changesInProgress: Bool, confirmChanges: () -> Bool, cancelChanges: () -> Void,
                                running: [(@escaping () -> Void) -> Void]) -> Answer {
        if erasing { return .cancel }
        if awaitingTermination { return .later }
        if finishRecording() { return .cancel }
        // A preparation doesn't survive a quit (a download does: it resumes).
        if preparing > 0, !confirmPreparation(preparing) { return .cancel }
        guard hasDevices else { return .now }
        // Queued installs count too, not just the one executing. Confirmed changes fall through to the SAME halt as
        // any other quit: skipping the flush threw away every app installed earlier in the session.
        if changesInProgress {
            guard confirmChanges() else { return .cancel }
            cancelChanges()
        }
        guard !running.isEmpty else { return .now }

        awaitingTermination = true
        let budget = budget
        backstop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(budget)) } catch { return }
            logEvent("quit: shutdown did not finish in time — quitting anyway")
            self?.finish()
        }
        // Every device halts at once; quit waits for the last of them.
        var remaining = running.count
        for halt in running {
            halt { [weak self] in
                remaining -= 1
                if remaining == 0 { self?.finish() }
            }
        }
        return .later
    }

    /// The process is going: no late reply.
    public func willTerminate() { backstop?.cancel() }

    /// A halt can complete synchronously: reply only after this request has returned terminateLater, and once.
    private func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.awaitingTermination else { return }
            self.awaitingTermination = false
            self.backstop?.cancel()
            self.backstop = nil
            self.reply()
        }
    }
}
