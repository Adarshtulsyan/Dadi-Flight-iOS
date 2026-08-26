import SwiftUI
import AVFoundation
import Combine
import Network
import MediaPlayer

// MARK: - Models
struct AppConfig: Codable, Sendable {
    let startTime: String
}

// MARK: - Network Monitor
class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    @Published var isConnected = true

    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - View Model
class FlightViewModel: ObservableObject {
    @Published var currentScreen: AppScreen = .welcome
    @Published var statusText: String = "Syncing journey details…"
    @Published var isLive: Bool = false
    @Published var earphonesConfirmed: Bool = false
    @Published var isPlaybackStartedByUser: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    @Published var remainingTime: String = "0:00"
    @Published var currentTimeStr: String = "0:00"
    @Published var systemTimeStr: String = ""
    @Published var startTimeStr: String = ""
    @Published var lastSyncStr: String = "Never"
    @Published var finished: Bool = false
    @Published var isConfigLoaded: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }
    @Published var sleepTimerRemaining: TimeInterval? = nil

    // Diagnostic Info
    @Published var debugInfo: String = ""

    private var sleepTimerCancellable: AnyCancellable?
    private var systemTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    enum AppScreen {
        case welcome, main
    }

    private var audioPlayer: AVPlayer?
    private var timer: AnyCancellable?
    private var configTimer: AnyCancellable?

    @Published var serverClockOffset: TimeInterval = 0
    private var currentStartTime: Date {
        didSet {
            updateStartTimeStr()
        }
    }

    private var lastFetchedTimeStr: String = ""
    private let apiUrl = "https://raw.githubusercontent.com/Adarshtulsyan/Inflight-audio-app/main/config.json"
    private let kolkataTimeZone = TimeZone(identifier: "Asia/Kolkata") ?? TimeZone(secondsFromGMT: 19800)!

    init() {
        if let storedTimeInterval = UserDefaults.standard.object(forKey: "start_time_interval") as? TimeInterval {
            self.currentStartTime = Date(timeIntervalSince1970: storedTimeInterval)
            self.isConfigLoaded = true
            self.statusText = "Ready for Journey"
        } else {
            self.currentStartTime = Date.distantFuture
            self.isConfigLoaded = false
        }

        setupAudioSession()
        setupRemoteCommandCenter()
        startConfigPolling()
        startSystemTimeUpdates()
        updateStartTimeStr()

        initializePlayer()
    }

    private func initializePlayer() {
        let bundleUrl = Bundle.main.url(forResource: "audio", withExtension: "mp3")
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath + "/audio.mp3"
        let exists = fileManager.fileExists(atPath: bundleUrl?.path ?? bundlePath)

        self.debugInfo += "File on Disk: \(exists ? "Yes" : "No")\n"

        if let url = bundleUrl {
            print("InflightSync: Audio file confirmed in bundle at: \(url.lastPathComponent)")

            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = false
            self.audioPlayer = player
            player.volume = self.volume

            player.currentItem?.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    switch status {
                    case .readyToPlay:
                        self?.debugInfo += "Player: Ready\n"
                    case .failed:
                        let err = player.currentItem?.error?.localizedDescription ?? "Unknown"
                        self?.debugInfo += "Player: Failed (\(err))\n"
                    default: break
                    }
                }
                .store(in: &cancellables)

            player.currentItem?.publisher(for: \.duration)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] duration in
                    if duration.isValid && !duration.isIndefinite {
                        self?.duration = duration.seconds
                        self?.updateNowPlayingInfo()
                    }
                }
                .store(in: &cancellables)
        } else {
            self.debugInfo += "Audio: MISSING from Bundle\n"
            self.statusText = "Audio Resource Missing"
        }
    }

    private func getSyncedDate() -> Date {
        return Date().addingTimeInterval(serverClockOffset)
    }

    private func startSystemTimeUpdates() {
        systemTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let now = self.getSyncedDate()
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                self.systemTimeStr = formatter.string(from: now)
            }
    }

    private func updateStartTimeStr() {
        guard currentStartTime != .distantFuture else {
            self.startTimeStr = "Waiting for Sync"
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        formatter.timeZone = kolkataTimeZone
        DispatchQueue.main.async {
            self.startTimeStr = formatter.string(from: self.currentStartTime)
        }
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.audioPlayer?.play()
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.audioPlayer?.pause()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "Rani Sati Dadi Mangal Path"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Marwari Samaj"

        if let player = audioPlayer, let item = player.currentItem {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        }

        if let image = UIImage(named: "dadi") {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func startConfigPolling() {
        fetchRemoteConfig()
        configTimer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.fetchRemoteConfig()
            }
    }

    func fetchRemoteConfig() {
        let timestamp = Date().timeIntervalSince1970
        guard let url = URL(string: "\(apiUrl)?cb=\(timestamp)") else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isLive = false
                    self.lastSyncStr = "Net Error"
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if let dateStr = httpResponse.value(forHTTPHeaderField: "Date") {
                    let headerFormatter = DateFormatter()
                    headerFormatter.locale = Locale(identifier: "en_US_POSIX")
                    headerFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    headerFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                    if let serverDate = headerFormatter.date(from: dateStr) {
                        let offset = serverDate.timeIntervalSinceNow
                        DispatchQueue.main.async {
                            self.serverClockOffset = offset
                            // Update debug info without overwriting file check
                            let time = dateStr.components(separatedBy: " ").indices.contains(4) ? dateStr.components(separatedBy: " ")[4] : ""
                            print("InflightSync: Offset \(Int(offset))s")
                        }
                    }
                }
            }

            guard let data = data else { return }

            DispatchQueue.main.async {
                let now = Date()
                let syncFormatter = DateFormatter()
                syncFormatter.dateFormat = "HH:mm:ss"
                self.lastSyncStr = syncFormatter.string(from: now)

                do {
                    let config = try JSONDecoder().decode(AppConfig.self, from: data)

                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.timeZone = self.kolkataTimeZone
                    isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

                    var parsedDate = isoFormatter.date(from: config.startTime)
                    if parsedDate == nil {
                        let altFormatter = DateFormatter()
                        altFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                        altFormatter.timeZone = self.kolkataTimeZone
                        parsedDate = altFormatter.date(from: config.startTime)
                    }

                    if let newDate = parsedDate {
                        self.isLive = true
                        self.isConfigLoaded = true

                        if config.startTime != self.lastFetchedTimeStr {
                            self.lastFetchedTimeStr = config.startTime
                            self.currentStartTime = newDate
                            UserDefaults.standard.set(newDate.timeIntervalSince1970, forKey: "start_time_interval")

                            if self.finished {
                                self.finished = false
                                self.statusText = "Ready for Journey"
                            }

                            if self.isPlaybackStartedByUser {
                                self.schedulePlayback()
                            }
                        }
                    } else {
                        self.lastSyncStr += " (Parse Error)"
                    }
                } catch {
                    self.isLive = false
                    self.lastSyncStr += " (JSON Error)"
                }
            }
        }.resume()
    }

    func schedulePlayback() {
        guard isConfigLoaded else {
            statusText = "Waiting for Sync..."
            return
        }

        timer?.cancel()
        audioPlayer?.pause()
        audioPlayer?.seek(to: .zero)

        let now = getSyncedDate()
        let startDelay = currentStartTime.timeIntervalSince(now)

        let audioDuration = duration > 0 ? duration : 6178
        let endDelay = currentStartTime.addingTimeInterval(audioDuration).timeIntervalSince(now)

        if startDelay > 0 {
            startCountdown(from: startDelay)
        } else if endDelay > 0 {
            startAudio(at: abs(startDelay))
        } else {
            handleCompletion()
        }
    }

    private func startCountdown(from seconds: TimeInterval) {
        timer?.cancel()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let now = self.getSyncedDate()
                let remaining = self.currentStartTime.timeIntervalSince(now)

                if remaining > 0 {
                    self.statusText = "Starts in \(self.formatCountdown(Int(ceil(remaining))))"
                } else {
                    self.statusText = "Starting shortly..."
                    self.startAudio(at: abs(remaining))
                }
            }
    }

    private func startAudio(at seconds: Double) {
        timer?.cancel()
        statusText = "Enjoying Cabin Journey"

        guard let player = audioPlayer else {
            statusText = "Audio Error"
            return
        }

        // If starting from beginning, play immediately
        if seconds < 1.0 {
            player.seek(to: .zero)
            player.play()
            self.updateNowPlayingInfo()
        } else {
            let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
            // Use default tolerances for faster seeking on large files
            player.seek(to: seekTime) { [weak self] _ in
                player.play()
                self?.updateNowPlayingInfo()
            }
        }

        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateProgress()
                self?.updateNowPlayingInfo()
            }
    }

    private func updateProgress() {
        guard let player = audioPlayer, let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let total = item.duration.seconds
        let now = getSyncedDate()
        let expectedEnd = currentStartTime.addingTimeInterval(total)

        if now >= expectedEnd && total > 0 {
            handleCompletion()
            return
        }

        guard total > 0 && !total.isNaN else { return }
        self.currentTime = current
        self.duration = total
        self.progress = current / total
        let remaining = max(0, total - current)
        self.currentTimeStr = formatTime(current)
        self.remainingTime = "-\(formatTime(remaining))"

        if current >= total - 1 {
            handleCompletion()
        }
    }

    func stopPlayback() {
        isPlaybackStartedByUser = false
        timer?.cancel()
        audioPlayer?.pause()
        audioPlayer?.seek(to: .zero)
        statusText = "Journey Paused"
        updateNowPlayingInfo()
    }

    func replayJourney() {
        finished = false
        earphonesConfirmed = true
        isPlaybackStartedByUser = true
        currentStartTime = getSyncedDate()
        audioPlayer?.seek(to: .zero)
        startAudio(at: 0)
    }

    func handleCompletion() {
        isPlaybackStartedByUser = false
        timer?.cancel()
        finished = true
        statusText = "Journey Completed"
        audioPlayer?.pause()
        updateNowPlayingInfo()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerCancellable?.cancel()
        guard let minutes = minutes else { return }
        sleepTimerCancellable = Timer.publish(every: Double(minutes * 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.stopPlayback()
                self?.sleepTimerCancellable?.cancel()
            }
    }

    func formatSleepTimer() -> String { "" }

    private func formatCountdown(_ totalSecs: Int) -> String {
        let h = totalSecs / 3600
        let m = (totalSecs % 3600) / 60
        let s = totalSecs % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func formatTime(_ secs: Double) -> String {
        let s = Int(max(0, secs))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Main View
struct ContentView: View {
    @StateObject private var vm = FlightViewModel()
    @StateObject private var network = NetworkMonitor()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if vm.currentScreen == .welcome {
                    welcomeView
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    mainContentView
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.currentScreen)
        .preferredColorScheme(.dark)
    }

    var welcomeView: some View {
        VStack(spacing: 34) {
            Image("dadi")
                .resizable()
                .scaledToFit()
                .frame(width: 144, height: 144)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "D4AF37"), lineWidth: 2))
                .shadow(color: Color(hex: "D4AF37").opacity(0.3), radius: 13)

            Text("Jai Dadi Ki")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color(hex: "D4AF37"))

            Text("We are honored to have you on board for this unique spiritual experience.")
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            Button(action: { withAnimation { vm.currentScreen = .main } }) {
                Text("Enter Cabin")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(hex: "D4AF37"))
                    .cornerRadius(13)
            }
            .padding(.horizontal, 55)
        }
    }

    var mainContentView: some View {
        VStack(spacing: 0) {
            headerView
            Divider().background(Color.white.opacity(0.1))
            Spacer()
            centralImageView
            Spacer()
            controlsView

            // Diagnostic Section (Discrete)
            if !vm.debugInfo.isEmpty {
                VStack(spacing: 2) {
                    Text("--- DIAGNOSTICS ---").bold()
                    Text(vm.debugInfo)
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.bottom, 5)
            }
        }
    }

    var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rani Sati Dadi Mangal Path").font(.system(size: 21, weight: .bold))
                HStack(spacing: 13) {
                    Text("Device: \(vm.systemTimeStr)")
                    Text("Target: \(vm.startTimeStr)")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "D4AF37").opacity(0.7))
            }
            Spacer()
            statusBadge
        }
        .padding(21)
    }

    var statusBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(network.isConnected ? Color(hex: "D4AF37") : .red).frame(width: 8, height: 8)
            Text(network.isConnected ? (vm.isLive ? "LIVE" : "SYNCING") : "OFFLINE")
                .font(.system(size: 10, weight: .black))
                .foregroundColor(network.isConnected ? Color(hex: "D4AF37") : .red)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Color.white.opacity(0.05)).cornerRadius(21)
    }

    var centralImageView: some View {
        VStack(spacing: 21) {
            Image("dadi")
                .resizable().scaledToFit().frame(width: 144, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 34))
                .shadow(color: .black.opacity(0.4), radius: 21, x: 0, y: 13)

            Text(vm.statusText)
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundColor(vm.finished ? Color(hex: "D4AF37") : .white)
                .multilineTextAlignment(.center)
        }
    }

    var controlsView: some View {
        VStack(spacing: 34) {
            if !vm.earphonesConfirmed && !vm.finished {
                Button(action: { withAnimation { vm.earphonesConfirmed = true } }) {
                    Text("Confirm Headset").font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(hex: "D4AF37")).cornerRadius(13)
                }
                .padding(.horizontal, 55)
            } else if !vm.finished {
                HStack(spacing: 55) {
                    controlButton(icon: "airplane.departure", label: "Commence", color: Color(hex: "D4AF37"), disabled: vm.isPlaybackStartedByUser || !vm.isConfigLoaded) {
                        vm.isPlaybackStartedByUser = true
                        vm.schedulePlayback()
                    }
                    controlButton(icon: "airplane.arrival", label: "End Session", color: .red, disabled: !vm.isPlaybackStartedByUser) {
                        vm.stopPlayback()
                    }
                }
                if vm.isPlaybackStartedByUser { progressView }
            } else {
                Button(action: { withAnimation { vm.replayJourney() } }) {
                    Text("Replay Journey").font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(hex: "D4AF37")).cornerRadius(13)
                }
                .padding(.horizontal, 55)
            }
        }
        .padding(.bottom, 21)
    }

    func controlButton(icon: String, label: String, color: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation { action() } }) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 34))
                Text(label).font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(disabled ? .gray : color)
            .frame(width: 89, height: 89)
            .background(Circle().fill(Color.white.opacity(0.05)))
        }
        .disabled(disabled)
    }

    var progressView: some View {
        VStack {
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 6)
                GeometryReader { geo in
                    Rectangle().fill(Color(hex: "D4AF37")).frame(width: geo.size.width * CGFloat(vm.progress), height: 6)
                }
            }
            .frame(height: 6).cornerRadius(3).padding(.horizontal)
            HStack {
                Text(vm.currentTimeStr); Spacer(); Text(vm.remainingTime)
            }
            .font(.caption2).monospacedDigit().padding(.horizontal)
        }
    }
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        self.init(red: Double((rgbValue & 0xFF0000) >> 16) / 255.0, green: Double((rgbValue & 0x00FF00) >> 8) / 255.0, blue: Double(rgbValue & 0x0000FF) / 255.0)
    }
}
