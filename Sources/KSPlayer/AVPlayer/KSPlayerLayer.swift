//
//  KSPlayerLayerView.swift
//  Pods
//
//  Created by kintan on 16/4/28.
//
//
import AVFoundation
import AVKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/**
 Player status emun
 - setURL:      set url
 - readyToPlay:    player ready to play
 - buffering:      player buffering
 - bufferFinished: buffer finished
 - playedToTheEnd: played to the End
 - error:          error with playing
 */
public enum KSPlayerState: CustomStringConvertible {
    case prepareToPlay
    case readyToPlay
    case buffering
    case bufferFinished
    case paused
    case playedToTheEnd
    case error
    public var description: String {
        switch self {
        case .prepareToPlay:
            return "prepareToPlay"
        case .readyToPlay:
            return "readyToPlay"
        case .buffering:
            return "buffering"
        case .bufferFinished:
            return "bufferFinished"
        case .paused:
            return "paused"
        case .playedToTheEnd:
            return "playedToTheEnd"
        case .error:
            return "error"
        }
    }

    public var isPlaying: Bool { self == .readyToPlay || self == .buffering || self == .bufferFinished }
}

public protocol KSPlayerLayerDelegate: AnyObject {
    func player(layer: KSPlayerLayer, state: KSPlayerState)
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval)
    func player(layer: KSPlayerLayer, finish error: Error?)
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval)
}

open class KSPlayerLayer: UIView {
    public weak var delegate: KSPlayerLayerDelegate?
    @Published public var bufferingProgress: Int = 0
    @Published public var loopCount: Int = 0
    @Published public var isPipActive = false {
        didSet {
            if #available(tvOS 14.0, *) {
                guard let pipController = player.pipController else {
                    return
                }

                if isPipActive {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        pipController.start(view: self)
                    }
                } else {
                    pipController.stop(restoreUserInterface: true)
                }
            }
        }
    }

    public private(set) var options: KSOptions
    public var player: MediaPlayerProtocol {
        didSet {
            oldValue.view?.removeFromSuperview()
            KSLog("player is \(player)")
            player.playbackRate = oldValue.playbackRate
            player.playbackVolume = oldValue.playbackVolume
            player.delegate = self
            player.contentMode = .scaleAspectFit
            prepareToPlay()
        }
    }

    public private(set) var url: URL {
        didSet {
            let firstPlayerType: MediaPlayerProtocol.Type
            if isWirelessRouteActive {
                // airplay的话，默认使用KSAVPlayer
                firstPlayerType = KSAVPlayer.self
            } else if options.display != .plane {
                // AR模式只能用KSMEPlayer
                // swiftlint:disable force_cast
                firstPlayerType = NSClassFromString("KSPlayer.KSMEPlayer") as! MediaPlayerProtocol.Type
                // swiftlint:enable force_cast
            } else {
                firstPlayerType = KSOptions.firstPlayerType
            }
            if type(of: player) == firstPlayerType {
                resetPlayer()
                player.replace(url: url, options: options)
                prepareToPlay()
            } else {
                resetPlayer()
                player = firstPlayerType.init(url: url, options: options)
            }
        }
    }

    /// 播发器的几种状态
    public private(set) var state = KSPlayerState.prepareToPlay {
        didSet {
            if state != oldValue {
                runInMainqueue { [weak self] in
                    guard let self else {
                        return
                    }
                    KSLog("playerStateDidChange - \(self.state)")
                    self.delegate?.player(layer: self, state: self.state)
                }
            }
        }
    }

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self, self.player.isReadyToPlay else {
            return
        }
        self.delegate?.player(layer: self, currentTime: self.player.currentPlaybackTime, totalTime: self.player.duration)
        if self.player.playbackState == .playing, self.player.loadState == .playable, self.state == .buffering {
            // 一个兜底保护，正常不能走到这里
            self.state = .bufferFinished
        }
        if self.player.isPlaying {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.player.currentPlaybackTime
        }
    }

    private var urls = [URL]()
    private var isAutoPlay: Bool
    private var isWirelessRouteActive = false
    private var bufferedCount = 0
    private var shouldSeekTo: TimeInterval = 0
    private var startTime: TimeInterval = 0
    public init(url: URL, options: KSOptions, delegate: KSPlayerLayerDelegate? = nil) {
        self.url = url
        self.options = options
        self.delegate = delegate
        let firstPlayerType: MediaPlayerProtocol.Type
        if options.display != .plane {
            // AR模式只能用KSMEPlayer
            // swiftlint:disable force_cast
            firstPlayerType = NSClassFromString("KSPlayer.KSMEPlayer") as! MediaPlayerProtocol.Type
            // swiftlint:enable force_cast
        } else {
            firstPlayerType = KSOptions.firstPlayerType
        }
        player = firstPlayerType.init(url: url, options: options)
        player.playbackRate = options.startPlayRate
        isAutoPlay = options.isAutoPlay
        super.init(frame: .zero)
        if options.registerRemoteControll {
            registerRemoteControllEvent()
        }
        player.delegate = self
        player.contentMode = .scaleAspectFit
        prepareToPlay()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(wirelessRouteActiveDidChange(notification:)), name: .MPVolumeViewWirelessRouteActiveDidChange, object: nil)
        #endif
        #if !os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
        #endif
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) {
            player.pipController?.contentSource = nil
        }
        NotificationCenter.default.removeObserver(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(tvOS)
        UIApplication.shared.windows.first?.avDisplayManager.preferredDisplayCriteria = nil
        #endif
    }

    public func set(url: URL, options: KSOptions) {
        self.options = options
        runInMainqueue {
            self.isAutoPlay = options.isAutoPlay
            self.url = url
        }
    }

    public func set(urls: [URL], options: KSOptions) {
        self.options = options
        self.urls.removeAll()
        self.urls.append(contentsOf: urls)
        if let first = urls.first {
            runInMainqueue {
                self.isAutoPlay = options.isAutoPlay
                self.url = first
            }
        }
    }

    open func play() {
        UIApplication.shared.isIdleTimerDisabled = true
        isAutoPlay = true
        if player.isReadyToPlay {
            if state == .playedToTheEnd {
                Task {
                    player.seek(time: 0) { [weak self] finished in
                        guard let self else { return }
                        if finished {
                            self.player.play()
                        }
                    }
                }
            } else {
                player.play()
            }
            timer.fireDate = Date.distantPast
        } else {
            if state == .error {
                player.prepareToPlay()
            }
        }
        state = player.loadState == .playable ? .bufferFinished : .buffering
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if #available(tvOS 14.0, *) {
            KSPictureInPictureController.mute()
        }
    }

    open func pause() {
        isAutoPlay = false
        player.pause()
        timer.fireDate = Date.distantFuture
        state = .paused
        UIApplication.shared.isIdleTimerDisabled = false
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    public func resetPlayer() {
        KSLog("resetPlayer")
        state = .prepareToPlay
        bufferedCount = 0
        shouldSeekTo = 0
        player.playbackRate = 1
        player.playbackVolume = 1
        UIApplication.shared.isIdleTimerDisabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(tvOS)
        UIApplication.shared.windows.first?.avDisplayManager.preferredDisplayCriteria = nil
        #endif
    }

    open func seek(time: TimeInterval, autoPlay: Bool, completion: @escaping ((Bool) -> Void)) {
        if time.isInfinite || time.isNaN {
            completion(false)
        }
        if player.isReadyToPlay {
            player.seek(time: time) { [weak self] finished in
                guard let self else { return }
                if finished, autoPlay {
                    self.play()
                }
                completion(finished)
            }
        } else {
            isAutoPlay = autoPlay
            shouldSeekTo = time
            completion(false)
        }
    }

    override open func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if subview == player.view {
            subview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                subview.leftAnchor.constraint(equalTo: leftAnchor),
                subview.topAnchor.constraint(equalTo: topAnchor),
                subview.bottomAnchor.constraint(equalTo: bottomAnchor),
                subview.rightAnchor.constraint(equalTo: rightAnchor),
            ])
        }
    }
}

// MARK: - MediaPlayerDelegate

extension KSPlayerLayer: MediaPlayerDelegate {
    public func readyToPlay(player: some MediaPlayerProtocol) {
        #if os(macOS)
        if let window {
            window.isMovableByWindowBackground = true
            let naturalSize = player.naturalSize
            if naturalSize.width > 0, naturalSize.height > 0 {
                window.aspectRatio = naturalSize
                var frame = window.frame
                frame.size.height = frame.width * naturalSize.height / naturalSize.width
                window.setFrame(frame, display: true)
            }
        }
        #endif
        updateNowPlayingInfo()
        state = .readyToPlay
        #if os(iOS)
        if #available(iOS 14.2, *) {
            if options.canStartPictureInPictureAutomaticallyFromInline {
                player.pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            }
        }
        #endif
        for track in player.tracks(mediaType: .video) where track.isEnabled {
            #if os(tvOS)
            setDisplayCriteria(track: track)
            #endif
        }
        if isAutoPlay {
            if shouldSeekTo > 0 {
                seek(time: shouldSeekTo, autoPlay: true) { [weak self] _ in
                    guard let self else { return }
                    self.shouldSeekTo = 0
                }

            } else {
                play()
            }
        }
    }

    public func changeLoadState(player: some MediaPlayerProtocol) {
        guard player.playbackState != .seeking else { return }
        if player.loadState == .playable, startTime > 0 {
            let diff = CACurrentMediaTime() - startTime
            delegate?.player(layer: self, bufferedCount: bufferedCount, consumeTime: diff)
            if bufferedCount == 0 {
                var dic = ["firstTime": diff]
                if options.tcpConnectedTime > 0 {
                    dic["initTime"] = options.dnsStartTime - startTime
                    dic["dnsTime"] = options.tcpStartTime - options.dnsStartTime
                    dic["tcpTime"] = options.tcpConnectedTime - options.tcpStartTime
                    dic["openTime"] = options.openTime - options.tcpConnectedTime
                    dic["findTime"] = options.findTime - options.openTime
                } else {
                    dic["openTime"] = options.openTime - startTime
                }
                dic["findTime"] = options.findTime - options.openTime
                dic["readyTime"] = options.readyTime - options.findTime
                dic["readVideoTime"] = options.readVideoTime - options.readyTime
                dic["readAudioTime"] = options.readAudioTime - options.readyTime
                dic["decodeVideoTime"] = options.decodeVideoTime - options.readVideoTime
                dic["decodeAudioTime"] = options.decodeAudioTime - options.readAudioTime
                KSLog(dic)
            }
            bufferedCount += 1
            startTime = 0
        }
        guard state.isPlaying else { return }
        if player.loadState == .playable {
            state = .bufferFinished
        } else {
            if state == .bufferFinished {
                startTime = CACurrentMediaTime()
            }
            state = .buffering
        }
    }

    public func changeBuffering(player _: some MediaPlayerProtocol, progress: Int) {
        bufferingProgress = progress
    }

    public func playBack(player _: some MediaPlayerProtocol, loopCount: Int) {
        self.loopCount = loopCount
    }

    public func finish(player: some MediaPlayerProtocol, error: Error?) {
        if let error {
            if type(of: player) != KSOptions.secondPlayerType, let secondPlayerType = KSOptions.secondPlayerType {
                self.player = secondPlayerType.init(url: url, options: options)
                return
            }
            state = .error
            KSLog(error as CustomStringConvertible)
        } else {
            let duration = player.duration
            delegate?.player(layer: self, currentTime: duration, totalTime: duration)
            state = .playedToTheEnd
        }
        timer.fireDate = Date.distantFuture
        bufferedCount = 1
        delegate?.player(layer: self, finish: error)
        if error == nil {
            nextPlayer()
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(tvOS 14.0, *)
extension KSPlayerLayer: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        player.pipController?.stop(restoreUserInterface: false)
    }

    public func pictureInPictureController(_: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler _: @escaping (Bool) -> Void) {
        isPipActive = false
    }
}

// MARK: - private functions

extension KSPlayerLayer {
    #if os(tvOS)
    private func setDisplayCriteria(track: some MediaPlayerTrack) {
        guard let displayManager = UIApplication.shared.windows.first?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled,
              !displayManager.isDisplayModeSwitchInProgress
        else {
            return
        }
        if let criteria = options.preferredDisplayCriteria(refreshRate: track.nominalFrameRate,
                                                           videoDynamicRange: track.dynamicRange(options).rawValue)
        {
            displayManager.preferredDisplayCriteria = criteria
        }
    }
    #endif

    private func prepareToPlay() {
        startTime = CACurrentMediaTime()
        bufferedCount = 0
        player.prepareToPlay()
        if isAutoPlay {
            DispatchQueue.main.async {
                self.state = .buffering
            }
        } else {
            state = .prepareToPlay
        }
        if let view = player.view {
            addSubview(view)
        }
    }

    private func updateNowPlayingInfo() {
        if MPNowPlayingInfoCenter.default().nowPlayingInfo == nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyPlaybackDuration: player.duration]
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        var current: [MPNowPlayingInfoLanguageOption] = []
        var langs: [MPNowPlayingInfoLanguageOptionGroup] = []
        for track in player.tracks(mediaType: .audio) {
            if let lang = track.language {
                let audioLang = MPNowPlayingInfoLanguageOption(type: .audible, languageTag: lang, characteristics: nil, displayName: track.name, identifier: track.name)
                let audioGroup = MPNowPlayingInfoLanguageOptionGroup(languageOptions: [audioLang], defaultLanguageOption: nil, allowEmptySelection: false)
                langs.append(audioGroup)
                if track.isEnabled {
                    current.append(audioLang)
                }
            }
        }
        if !langs.isEmpty {
            MPRemoteCommandCenter.shared().enableLanguageOptionCommand.isEnabled = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyAvailableLanguageOptions] = langs
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyCurrentLanguageOptions] = current
    }

    private func nextPlayer() {
        if urls.count > 1, let index = urls.firstIndex(of: url), index < urls.count - 1 {
            isAutoPlay = true
            url = urls[index + 1]
        }
    }

    private func previousPlayer() {
        if urls.count > 1, let index = urls.firstIndex(of: url), index > 0 {
            isAutoPlay = true
            url = urls[index - 1]
        }
    }

    func seek(time: TimeInterval) {
        seek(time: time, autoPlay: options.isSeekedAutoPlay) { _ in
        }
    }

    private func registerRemoteControllEvent() {
        let remoteCommand = MPRemoteCommandCenter.shared()
        remoteCommand.playCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.play()
            return .success
        }
        remoteCommand.pauseCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.pause()
            return .success
        }
        remoteCommand.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            if self.state.isPlaying {
                self.pause()
            } else {
                self.play()
            }
            return .success
        }
        remoteCommand.stopCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.player.shutdown()
            return .success
        }
        remoteCommand.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.nextPlayer()
            return .success
        }
        remoteCommand.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else {
                return .commandFailed
            }
            self.previousPlayer()
            return .success
        }
        remoteCommand.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            self.options.isLoopPlay = event.repeatType != .off
            return .success
        }
        remoteCommand.changeShuffleModeCommand.isEnabled = false
        // remoteCommand.changeShuffleModeCommand.addTarget {})
        remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
        remoteCommand.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            self.player.playbackRate = event.playbackRate
            return .success
        }
        remoteCommand.skipForwardCommand.preferredIntervals = [15]
        remoteCommand.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self.seek(time: self.player.currentPlaybackTime + event.interval)
            return .success
        }
        remoteCommand.skipBackwardCommand.preferredIntervals = [15]
        remoteCommand.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self.seek(time: self.player.currentPlaybackTime - event.interval)
            return .success
        }
        remoteCommand.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(time: event.positionTime)
            return .success
        }
        remoteCommand.enableLanguageOptionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeLanguageOptionCommandEvent else {
                return .commandFailed
            }
            let selectLang = event.languageOption
            if selectLang.languageOptionType == .audible,
               let trackToSelect = self.player.tracks(mediaType: .audio).first(where: { $0.name == selectLang.displayName })
            {
                self.player.select(track: trackToSelect)
            }
            return .success
        }
    }

    @objc private func enterBackground() {
        guard state.isPlaying, !player.isExternalPlaybackActive else {
            return
        }
        if #available(tvOS 14.0, *), player.pipController?.isPictureInPictureActive == true {
            return
        }

        if KSOptions.canBackgroundPlay {
            player.enterBackground()
            return
        }
        pause()
    }

    @objc private func enterForeground() {
        if KSOptions.canBackgroundPlay {
            player.enterForeground()
        }
    }

    #if canImport(UIKit)
    @objc private func wirelessRouteActiveDidChange(notification: Notification) {
        guard let volumeView = notification.object as? MPVolumeView, isWirelessRouteActive != volumeView.isWirelessRouteActive else { return }
        if volumeView.isWirelessRouteActive {
            if !player.allowsExternalPlayback {
                isWirelessRouteActive = true
            }
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
        }
        isWirelessRouteActive = volumeView.isWirelessRouteActive
    }
    #endif
    #if !os(macOS)
    @objc private func audioInterrupted(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }
        switch type {
        case .began:
            pause()
        case .ended:
            // An interruption ended. Resume playback, if appropriate.

            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }

        default:
            break
        }
    }
    #endif
}
