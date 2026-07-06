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
    @Published var finished: Bool = false
    @Published var isConfigLoaded: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }
    @Published var sleepTimerRemaining: TimeInterval? = nil
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
    private let kolkataTimeZone = TimeZone(identifier: "Asia/Kolkata") ?? TimeZone(secondsFromGMT: 19800)! // Fallback to IST offset

    init() {
        // Load stored time if available, otherwise default to a distant future to avoid "Completed" state
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
            // Enable background audio and bluetooth support
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)

            // Handle audio interruptions (calls, etc.)
            NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: session)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .began {
            // Interruption began (e.g., incoming call), pause audio
            audioPlayer?.pause()
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && isPlaybackStartedByUser {
                    audioPlayer?.play()
                }
            }
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

    func setPlayer(_ player: AVPlayer) {
        self.audioPlayer = player
        player.volume = self.volume

        // Observe duration
        player.currentItem?.publisher(for: \.duration)
            .sink { [weak self] duration in
                if duration.isValid && !duration.isIndefinite {
                    DispatchQueue.main.async {
                        self?.duration = duration.seconds
                        self?.updateNowPlayingInfo()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func startConfigPolling() {
        fetchRemoteConfig()
        configTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.fetchRemoteConfig()
            }
    }

    func fetchRemoteConfig() {
        guard let url = URL(string: "\(apiUrl)?t=\(Date().timeIntervalSince1970)") else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("Network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isLive = false
                    if !self.isConfigLoaded {
                        self.statusText = "Sync required (Check Internet)"
                    }
                }
                return
            }

            // Sync clock using Date header
            if let httpResponse = response as? HTTPURLResponse,
               let dateStr = httpResponse.allHeaderFields["Date"] as? String {
                let headerFormatter = DateFormatter()
                headerFormatter.locale = Locale(identifier: "en_US_POSIX")
                headerFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let serverDate = headerFormatter.date(from: dateStr) {
                    let offset = serverDate.timeIntervalSinceNow
                    DispatchQueue.main.async {
                        self.serverClockOffset = offset
                    }
                }
            }

            guard let data = data else { return }

            DispatchQueue.main.async {
                do {
                    let config = try JSONDecoder().decode(AppConfig.self, from: data)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    formatter.timeZone = self.kolkataTimeZone

                    if let newDate = formatter.date(from: config.startTime) {
                        self.isLive = true
                        self.isConfigLoaded = true

                        if !self.isPlaybackStartedByUser && self.statusText == "Syncing journey details…" {
                            self.statusText = "Ready for Journey"
                        }

                        let drift = abs(self.currentStartTime.timeIntervalSince(newDate))
                        let timeChanged = config.startTime != self.lastFetchedTimeStr

                        if self.lastFetchedTimeStr.isEmpty || timeChanged || drift > 1 {
                            self.lastFetchedTimeStr = config.startTime
                            self.currentStartTime = newDate
                            UserDefaults.standard.set(newDate.timeIntervalSince1970, forKey: "start_time_interval")

                            if self.isPlaybackStartedByUser {
                                self.schedulePlayback()
                            }
                        }
                    }
                } catch {
                    print("JSON parse error: \(error)")
                    self.isLive = false
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

        // Use duration from player if available, otherwise fallback
        let audioDuration = duration > 0 ? duration : 1200 // Default 20 mins
        let endDelay = currentStartTime.addingTimeInterval(audioDuration).timeIntervalSince(now)

        if startDelay > 0 {
            startCountdown(from: startDelay)
        } else if endDelay > 0 {
            let offset = abs(startDelay)
            startAudio(at: offset)
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

        let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
        audioPlayer?.seek(to: seekTime)
        audioPlayer?.play()
        updateNowPlayingInfo()

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

        // Absolute Time Completion Check
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

    func handleCompletion() {
        isPlaybackStartedByUser = false
        timer?.cancel()
        sleepTimerCancellable?.cancel()
        sleepTimerRemaining = nil
        finished = true
        statusText = "Journey Completed"
        audioPlayer?.pause()
        updateNowPlayingInfo()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimerCancellable?.cancel()
        guard let minutes = minutes else {
            sleepTimerRemaining = nil
            return
        }

        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let remaining = self.sleepTimerRemaining else { return }
                if remaining > 1 {
                    self.sleepTimerRemaining = remaining - 1
                } else {
                    self.stopPlayback()
                    self.sleepTimerRemaining = nil
                    self.sleepTimerCancellable?.cancel()
                }
            }
    }

    func formatSleepTimer() -> String {
        guard let remaining = sleepTimerRemaining else { return "" }
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatCountdown(_ totalSecs: Int) -> String {
        let days = totalSecs / 86400
        let hours = (totalSecs % 86400) / 3600
        let minutes = (totalSecs % 3600) / 60
        let seconds = totalSecs % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
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

    @State private var player = AVPlayer(url: Bundle.main.url(forResource: "audio", withExtension: "mp3") ?? URL(fileURLWithPath: ""))

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
        .onAppear {
            vm.setPlayer(player)
        }
    }

    // MARK: - Welcome Screen
    var welcomeView: some View {
        VStack(spacing: 34) {
            Image("dadi")
                .resizable()
                .scaledToFit()
                .frame(width: 144, height: 144)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "D4AF37"), lineWidth: 2))
                .shadow(color: Color(hex: "D4AF37").opacity(0.3), radius: 13)
                .padding(.bottom, 8)

            Text("Jai Dadi Ki")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color(hex: "D4AF37"))

            Text("We are honored to have you on board for this unique spiritual experience. Join us as we commence the Rani Sati Dadi Mangal Path, beautifully orchestrated for our journey through the skies.")
                .font(.system(size: 16))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            VStack(spacing: 8) {
                Text("Organized by")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Marwari Samaj")
                    .font(.system(size: 21, weight: .semibold))
            }

            Button(action: {
                withAnimation { vm.currentScreen = .main }
            }) {
                Text("Enter Cabin")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "D4AF37"))
                    .cornerRadius(13)
            }
            .padding(.horizontal, 55)
        }
    }

    // MARK: - Main Content
    var mainContentView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rani Sati Dadi Mangal Path")
                        .font(.system(size: 21, weight: .bold))
                    Text("Organised by Marwari Samaj")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    HStack(spacing: 13) {
                        Text("Device: \(vm.systemTimeStr)")
                        Text("Target: \(vm.startTimeStr)")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "D4AF37").opacity(0.7))
                    .padding(.top, 5)
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(network.isConnected ? Color(hex: "D4AF37") : .red)
                            .frame(width: 8, height: 8)
                        Text(network.isConnected ? (vm.isLive ? "LIVE" : "SYNCING") : "OFFLINE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(network.isConnected ? Color(hex: "D4AF37") : .red)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(21)
                }
            }
            .padding(.horizontal, 21)
            .padding(.top, 21)
            .padding(.bottom, 13)

            Divider().background(Color.white.opacity(0.1))

            Spacer()

            // Central Image / Audio Area
            VStack(spacing: 21) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "D4AF37").opacity(0.12))
                        .frame(width: 233, height: 233)
                        .blur(radius: 55)

                    Image("dadi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 144, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 34))
                        .overlay(
                            RoundedRectangle(cornerRadius: 34)
                                .stroke(Color(hex: "D4AF37").opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 21, x: 0, y: 13)
                }

                VStack(spacing: 13) {
                    Text(vm.statusText)
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundColor(vm.finished ? Color(hex: "D4AF37") : .white)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut, value: vm.statusText)

                    if vm.finished {
                        Text("We thank you for joining us in this spiritual journey. May Dadi Maa bless you. Jai Dadi Ki.")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "D4AF37").opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 55)
                            .transition(.opacity)
                    }
                }

                // Volume and Sleep Timer Controls
                if vm.isPlaybackStartedByUser && !vm.finished {
                    VStack(spacing: 15) {
                        // Volume Slider
                        HStack(spacing: 15) {
                            Image(systemName: "speaker.fill")
                                .foregroundColor(.secondary)
                            Slider(value: $vm.volume, in: 0...1)
                                .accentColor(Color(hex: "D4AF37"))
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 40)

                        // Sleep Timer
                        HStack {
                            Menu {
                                Button("Off") { vm.setSleepTimer(minutes: nil) }
                                Button("15 Minutes") { vm.setSleepTimer(minutes: 15) }
                                Button("30 Minutes") { vm.setSleepTimer(minutes: 30) }
                                Button("60 Minutes") { vm.setSleepTimer(minutes: 60) }
                            } label: {
                                HStack {
                                    Image(systemName: "timer")
                                    Text(vm.sleepTimerRemaining == nil ? "Sleep Timer" : "Ends in \(vm.formatSleepTimer())")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(vm.sleepTimerRemaining == nil ? .secondary : Color(hex: "D4AF37"))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(20)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            Spacer()

            // Controls Area
            VStack(spacing: 34) {
                if !vm.earphonesConfirmed && !vm.finished {
                    VStack(spacing: 21) {
                        Text("Headset Experience")
                            .font(.system(size: 21, weight: .bold))
                        Text("Please connect your headset to begin the journey")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button(action: {
                            withAnimation { vm.earphonesConfirmed = true }
                        }) {
                            Text("Confirm Headset")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(hex: "D4AF37"))
                                .cornerRadius(13)
                        }
                        .padding(.horizontal, 55)
                    }
                    .padding(34)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(21)
                    .padding(.horizontal, 21)

                } else if !vm.finished {
                    VStack(spacing: 34) {
                        if vm.isPlaybackStartedByUser {
                            progressView
                        }

                        HStack(spacing: 55) {
                            Button(action: {
                                withAnimation {
                                    vm.isPlaybackStartedByUser = true
                                    vm.schedulePlayback()
                                }
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "airplane.departure")
                                        .font(.system(size: 34))
                                    Text("Commence")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(vm.isPlaybackStartedByUser || !vm.isConfigLoaded ? .gray : Color(hex: "D4AF37"))
                                .frame(width: 89, height: 89)
                                .background(Circle().fill(Color.white.opacity(0.05)))
                            }
                            .disabled(vm.isPlaybackStartedByUser || !vm.isConfigLoaded)

                            Button(action: {
                                withAnimation { vm.stopPlayback() }
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "airplane.arrival")
                                        .font(.system(size: 34))
                                    Text("End Session")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(!vm.isPlaybackStartedByUser ? .gray : .red)
                                .frame(width: 89, height: 89)
                                .background(Circle().fill(Color.white.opacity(0.05)))
                            }
                            .disabled(!vm.isPlaybackStartedByUser)
                        }
                    }
                    .padding(.bottom, 55)
                }
            }
            .padding(.bottom, 21)
        }
    }

    var progressView: some View {
        VStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .frame(height: 6)
                    Rectangle().fill(Color(hex: "D4AF37"))
                        .frame(width: geo.size.width * CGFloat(vm.progress), height: 6)
                }
                .cornerRadius(3)
            }
            .frame(height: 6)
            .padding(.horizontal)

            HStack {
                Text(vm.currentTimeStr).font(.caption2).monospacedDigit()
                Spacer()
                Text(vm.remainingTime).font(.caption2).monospacedDigit()
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Helpers
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    ContentView()
}
