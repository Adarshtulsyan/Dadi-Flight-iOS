import SwiftUI
import AVFoundation
import Combine
import Network

// MARK: - Models
struct GitHubContent: Codable {
    let sha: String
    let content: String
}

struct AppConfig: Codable {
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
    @Published var statusText: String = "Detecting audio devices…"
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

    private var systemTimer: AnyCancellable?

    enum AppScreen {
        case welcome, main
    }

    private var audioPlayer: AVPlayer?
    private var timer: AnyCancellable?
    private var configTimer: AnyCancellable?
    private var currentStartTime: Date {
        didSet {
            updateStartTimeStr()
        }
    }
    private var currentFileSha: String = ""
    private let apiUrl = "https://api.github.com/repos/Adarshtulsyan/Inflight-audio-app/contents/config.json"

    init() {
        // Default start time: 2026-04-22 12:19:00 IST
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 22
        components.hour = 12
        components.minute = 19
        components.second = 0
        components.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let defaultDate = Calendar.current.date(from: components) ?? Date()
        self.currentStartTime = defaultDate

        // Load stored time if available
        if let storedTimeInterval = UserDefaults.standard.object(forKey: "start_time_interval") as? TimeInterval {
            self.currentStartTime = Date(timeIntervalSince1970: storedTimeInterval)
        }

        setupAudioSession()
        startConfigPolling()
        startSystemTimeUpdates()
        updateStartTimeStr()
    }

    private func startSystemTimeUpdates() {
        systemTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                self?.systemTimeStr = formatter.string(from: now)
            }
    }

    private func updateStartTimeStr() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        DispatchQueue.main.async {
            self.startTimeStr = formatter.string(from: self.currentStartTime)
        }
    }

    private func setupAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category.")
        }
        #endif
    }

    func setPlayer(_ player: AVPlayer) {
        self.audioPlayer = player

        // Observe duration
        player.currentItem?.publisher(for: \.duration)
            .sink { [weak self] duration in
                if duration.isValid && !duration.isIndefinite {
                    DispatchQueue.main.async {
                        self?.duration = duration.seconds
                    }
                }
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func startConfigPolling() {
        fetchRemoteConfig()
        configTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.fetchRemoteConfig()
            }
    }

    func fetchRemoteConfig() {
        guard let url = URL(string: apiUrl) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { self?.isLive = false }
                return
            }

            do {
                let github = try JSONDecoder().decode(GitHubContent.self, from: data)
                let cleanedContent = github.content.replacingOccurrences(of: "\n", with: "")

                if let decodedData = Data(base64Encoded: cleanedContent) {
                    let config = try JSONDecoder().decode(AppConfig.self, from: decodedData)

                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")

                    if let newDate = formatter.date(from: config.startTime) {
                        DispatchQueue.main.async {
                            self?.isLive = true
                            let drift = abs(self?.currentStartTime.timeIntervalSince(newDate) ?? 0)

                            if self?.currentFileSha.isEmpty == true || github.sha != self?.currentFileSha || drift > 2 {
                                self?.currentFileSha = github.sha
                                self?.currentStartTime = newDate
                                UserDefaults.standard.set(newDate.timeIntervalSince1970, forKey: "start_time_interval")

                                if self?.isPlaybackStartedByUser == true {
                                    self?.schedulePlayback()
                                }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.isLive = false }
            }
        }.resume()
    }

    func schedulePlayback() {
        timer?.cancel()
        audioPlayer?.pause()
        audioPlayer?.seek(to: .zero)

        let now = Date()
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
        var remaining = seconds
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                if remaining > 0 {
                    self?.statusText = "Starts in \(self?.formatCountdown(Int(remaining)) ?? "")"
                    remaining -= 1
                } else {
                    self?.statusText = "Starting shortly..."
                    self?.startAudio(at: 0)
                }
            }
    }

    private func startAudio(at seconds: Double) {
        timer?.cancel()
        statusText = "Enjoying Cabin Journey"

        let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
        audioPlayer?.seek(to: seekTime)
        audioPlayer?.play()

        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateProgress()
            }
    }

    private func updateProgress() {
        guard let player = audioPlayer, let item = player.currentItem else { return }

        let current = player.currentTime().seconds
        let total = item.duration.seconds

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
    }

    func handleCompletion() {
        isPlaybackStartedByUser = false
        timer?.cancel()
        finished = true
        statusText = "Journey Completed"
        audioPlayer?.pause()
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

    // Replace "audio" with your actual audio filename (e.g., audio.mp3)
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
        VStack(spacing: 34) { // Fibonacci 34
            Image("dadi")
                .resizable()
                .scaledToFit()
                .frame(width: 144, height: 144) // Fibonacci 144
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "D4AF37"), lineWidth: 2))
                .shadow(color: Color(hex: "D4AF37").opacity(0.3), radius: 13)
                .padding(.bottom, 8)

            Text("Jai Dadi Ki")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color(hex: "D4AF37")) // Gold

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

                    // Diagnostic Times for Testing
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
                            .fill(network.isConnected ? Color(hex: "D4AF37") : .gray)
                            .frame(width: 8, height: 8)
                        Text(network.isConnected ? "LIVE" : "OFFLINE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(network.isConnected ? Color(hex: "D4AF37") : .gray)
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
            VStack(spacing: 34) {
                ZStack {
                    // Glow Effect
                    Circle()
                        .fill(Color(hex: "D4AF37").opacity(0.12))
                        .frame(width: 233, height: 233) // Fibonacci 233
                        .blur(radius: 55)

                    Image("dadi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 144, height: 144) // Fibonacci 144 (Golden Ratio balanced)
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
            }

            Spacer()

            // Controls Area
            VStack(spacing: 34) {
                if !vm.earphonesConfirmed && !vm.finished {
                    // Headset Step
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
                    // Playback Controls
                    VStack(spacing: 34) {
                        if vm.isPlaybackStartedByUser {
                            progressView
                        }

                        HStack(spacing: 55) {
                            // Start Button
                            Button(action: {
                                withAnimation {
                                    vm.isPlaybackStartedByUser = true
                                    vm.schedulePlayback()
                                }
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "airplane.takeoff")
                                        .font(.system(size: 34))
                                    Text("Commence")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(vm.isPlaybackStartedByUser ? .gray : Color(hex: "D4AF37"))
                                .frame(width: 89, height: 89) // Fibonacci 89
                                .background(Circle().fill(Color.white.opacity(0.05)))
                            }
                            .disabled(vm.isPlaybackStartedByUser)

                            // Stop Button
                            Button(action: {
                                withAnimation { vm.stopPlayback() }
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: "airplane.landing")
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
