import SwiftUI
@preconcurrency import UserNotifications
import AudioToolbox
import UIKit

// MARK: - Model

/// An in-app cooking timer. The countdown is derived from `endsAt` (a server
/// timestamp), so it's exact and identical across the text and voice screens.
struct CookTimer: Identifiable, Equatable {
    let id: String
    let label: String
    let durationSeconds: Int
    let endsAt: Date
    let createdBy: String     // user | text_chef | voice_chef

    func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
    func isDone(at now: Date) -> Bool { endsAt.timeIntervalSince(now) <= 0 }
    func progress(at now: Date) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / Double(durationSeconds)))
    }
}

/// Backend wire shape (from cook-timers + chef responses).
struct BackendTimer: Decodable {
    let id: String
    let label: String
    let duration_seconds: Int
    let ends_at: String
    let created_by: String

    func toCookTimer() -> CookTimer? {
        guard let ends = ISO8601.parse(ends_at) else { return nil }
        return CookTimer(id: id, label: label, durationSeconds: duration_seconds,
                         endsAt: ends, createdBy: created_by)
    }
}

enum ISO8601 {
    // Supabase returns timestamps like "2026-05-30T05:10:00.123+00:00".
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}

// MARK: - Service

struct CookTimersService {
    static let shared = CookTimersService()
    private var endpoint: URL { BackendConfig.timersEndpoint }

    private struct ListBody: Encodable { let action = "list"; let cook_session_id: String }
    private struct CreateBody: Encodable { let action = "create"; let cook_session_id: String; let label: String; let seconds: Int; let created_by = "user" }
    private struct CancelBody: Encodable { let action = "cancel"; let cook_session_id: String; let timer_id: String }
    private struct TimersResponse: Decodable { let timers: [BackendTimer] }

    func list(cookSessionID: String) async throws -> [BackendTimer] {
        let r: TimersResponse = try await BackendHTTP.request(url: endpoint, body: ListBody(cook_session_id: cookSessionID), timeout: 15)
        return r.timers
    }
    func create(cookSessionID: String, label: String, seconds: Int) async throws -> [BackendTimer] {
        let r: TimersResponse = try await BackendHTTP.request(url: endpoint, body: CreateBody(cook_session_id: cookSessionID, label: label, seconds: seconds), timeout: 20)
        return r.timers
    }
    func cancel(cookSessionID: String, timerID: String) async throws -> [BackendTimer] {
        let r: TimersResponse = try await BackendHTTP.request(url: endpoint, body: CancelBody(cook_session_id: cookSessionID, timer_id: timerID), timeout: 15)
        return r.timers
    }
}

// MARK: - TimerCenter

/// Owns the live timer list for a cook session: ticks once a second to drive
/// the cards, schedules a lock-screen notification per timer (so it rings even
/// if the app is backgrounded), and fires sound + haptic + a chef announcement
/// when one finishes. Shared by the text and voice screens via CookingSession.
@MainActor
final class TimerCenter: ObservableObject {
    @Published private(set) var timers: [CookTimer] = []
    @Published private(set) var now = Date()

    /// Set by the active screen so a finished timer can be announced by the chef
    /// (voice speaks it; text drops a chat note).
    var onTimerFired: ((CookTimer) -> Void)?

    /// Fires whenever the timer list changes (created/cancelled) — the voice
    /// screen uses it to push a live snapshot to the chef so it always knows
    /// what's running and how long is left.
    var onTimersChanged: (([CookTimer]) -> Void)?

    private var cookSessionID: String?
    private var ticker: Timer?
    private var firedIDs: Set<String> = []
    private var notifiedIDs: Set<String> = []

    func bind(cookSessionID: String) { self.cookSessionID = cookSessionID }

    // Merge a fresh list from the backend / chef responses (authoritative set of
    // running timers). Schedules notifications for any new ones.
    func apply(_ backend: [BackendTimer]) {
        let fresh = backend.compactMap { $0.toCookTimer() }
        let freshIDs = Set(fresh.map(\.id))
        // Cancel notifications for timers that vanished (cancelled elsewhere).
        for gone in notifiedIDs.subtracting(freshIDs) { cancelNotification(id: gone) }
        timers = fresh.sorted { $0.endsAt < $1.endsAt }
        for t in fresh where !notifiedIDs.contains(t.id) { scheduleNotification(for: t) }
        startTickerIfNeeded()
        onTimersChanged?(timers)
    }

    func refresh() async {
        guard let id = cookSessionID else { return }
        if let backend = try? await CookTimersService.shared.list(cookSessionID: id) { apply(backend) }
    }

    func createManual(label: String, seconds: Int) async {
        guard let id = cookSessionID else { return }
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? "Timer" : label
        if let backend = try? await CookTimersService.shared.create(cookSessionID: id, label: name, seconds: seconds) {
            apply(backend)
        }
    }

    func cancel(_ timer: CookTimer) async {
        guard let id = cookSessionID else { return }
        cancelNotification(id: timer.id)
        timers.removeAll { $0.id == timer.id }          // optimistic
        if let backend = try? await CookTimersService.shared.cancel(cookSessionID: id, timerID: timer.id) { apply(backend) }
    }

    // MARK: ticking + fire

    private func startTickerIfNeeded() {
        if !timers.isEmpty && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if timers.isEmpty {
            ticker?.invalidate(); ticker = nil
        }
    }

    private func tick() {
        now = Date()
        for t in timers where t.isDone(at: now) && !firedIDs.contains(t.id) {
            firedIDs.insert(t.id)
            fire(t)
        }
    }

    private func fire(_ timer: CookTimer) {
        // In-app alert (the lock-screen one was scheduled at creation).
        AudioServicesPlaySystemSound(1005)                       // gentle alert tone
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onTimerFired?(timer)
    }

    // MARK: local notifications

    private func scheduleNotification(for timer: CookTimer) {
        notifiedIDs.insert(timer.id)
        let secs = timer.remaining(at: Date())
        guard secs > 0.5 else { return }
        // Capture only Sendable primitives; rebuild the (non-Sendable) request
        // and grab the center inside the completion so nothing crosses the
        // @Sendable boundary.
        let id = timer.id
        let label = timer.label
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PantryHub"
            content.body = "⏰ \(label) is done!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func cancelNotification(id: String) {
        notifiedIDs.remove(id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

// MARK: - Views

/// The tray of timer cards, pinned at the top of a chat.
///   • `.horizontal` (text chef): hidden at 0, full-width at 1, a horizontal
///     snap-scroll of compact cards at 2+ (keeps the chat space below).
///   • `.vertical` (voice chef, which has room): a vertical stack, scrollable
///     and height-capped if there are many.
struct TimerTray: View {
    @ObservedObject var center: TimerCenter
    var axis: Axis = .horizontal

    var body: some View {
        if !center.timers.isEmpty {
            Group {
                if axis == .vertical {
                    // Size to the actual cards. A ScrollView always claims its
                    // full maxHeight even for ONE small timer — that reserved
                    // empty space was pushing the steps far down the screen. So
                    // only wrap in a (capped, scrollable) box when there are
                    // enough timers to actually need it.
                    if center.timers.count > 2 {
                        ScrollView(.vertical, showsIndicators: false) {
                            verticalCards
                        }
                        .frame(maxHeight: 270)
                        // Soft gradient fade at the bottom edge so the tray melts
                        // into the chat below instead of ending on a hard line.
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.85),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    } else {
                        verticalCards
                    }
                } else if center.timers.count == 1, let t = center.timers.first {
                    card(t).padding(.horizontal, Theme.gap)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(center.timers) { t in card(t).frame(width: 210) }
                        }
                        .padding(.horizontal, Theme.gap)
                    }
                }
            }
            .padding(.vertical, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.smooth(duration: 0.3), value: center.timers.count)
        }
    }

    /// The timer cards stacked vertically, sized to their content.
    private var verticalCards: some View {
        VStack(spacing: 10) {
            ForEach(center.timers) { t in card(t) }
        }
        .padding(.horizontal, Theme.gap)
    }

    private func card(_ t: CookTimer) -> some View {
        TimerCard(timer: t, now: center.now) { Task { await center.cancel(t) } }
    }
}

/// A dark, glassy timer chip that sits on the black stage — amber ring while
/// running, red in the final 10s, green when done.
struct TimerCard: View {
    let timer: CookTimer
    let now: Date
    let onCancel: () -> Void

    private var remaining: TimeInterval { timer.remaining(at: now) }
    private var done: Bool { timer.isDone(at: now) }
    private var accent: Color {
        if done { return Theme.matchGreen }
        return remaining <= 10 ? Theme.alertRed : Theme.warmAmber
    }
    private var timeText: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    private var subtitle: String {
        if done { return "Done" }
        let m = timer.durationSeconds / 60, s = timer.durationSeconds % 60
        return s == 0 ? "\(m) min timer" : (m == 0 ? "\(s) sec timer" : "\(m)m \(s)s timer")
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: done ? 1 : timer.progress(at: now))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: remaining)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(accent)
                } else {
                    Text(timeText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.paper)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(done ? Theme.matchGreen : Color.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(done ? Theme.matchGreen.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Bottom sheet for the user to set their own timer (topic + duration).
struct TimerSetupSheet: View {
    var onStart: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var minutes = 5
    @State private var seconds = 0

    private let presets: [(String, Int)] = [("1 min", 60), ("3 min", 180), ("5 min", 300), ("10 min", 600)]

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("New timer").font(.serif(22)).foregroundStyle(Theme.paper)
                    Spacer()
                    DismissButton(style: .close) { dismiss() }
                }

                TextField("What's it for? (e.g. Simmering beef)", text: $topic)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.paper).tint(Theme.warmAmber)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))

                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { p in
                        Button {
                            minutes = p.1 / 60; seconds = p.1 % 60
                        } label: {
                            Text(p.0).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(Theme.paper))
                        }.buttonStyle(.plain)
                    }
                }

                HStack(spacing: 0) {
                    Picker("min", selection: $minutes) {
                        ForEach(0..<60) { Text("\($0) min").tag($0) }
                    }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                    Picker("sec", selection: $seconds) {
                        ForEach(0..<60) { Text("\($0) sec").tag($0) }
                    }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                }
                .colorScheme(.dark)
                .frame(height: 130)

                Button {
                    let total = minutes * 60 + seconds
                    if total > 0 { onStart(topic, total); dismiss() }
                } label: {
                    Text("Start timer")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Theme.paper, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
                .disabled(minutes * 60 + seconds == 0)
                .opacity(minutes * 60 + seconds == 0 ? 0.5 : 1)

                Spacer()
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(440)])
    }
}
