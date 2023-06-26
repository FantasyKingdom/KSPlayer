//
//  KSVideoPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2023/2/11.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
public typealias UIViewRepresentable = NSViewRepresentable
#endif

public struct KSVideoPlayer {
    public let coordinator: Coordinator
    public let url: URL
    public let options: KSOptions
    public init(coordinator: Coordinator, url: URL, options: KSOptions) {
        self.coordinator = coordinator
        self.url = url
        self.options = options
    }
}

extension KSVideoPlayer: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        coordinator
    }

    #if canImport(UIKit)
    public typealias UIViewType = KSPlayerLayer
    public func makeUIView(context: Context) -> UIViewType {
        let view = context.coordinator.makeView(url: url, options: options)
        let swipeDown = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeGestureAction(_:)))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeGestureAction(_:)))
        swipeLeft.direction = .left
        view.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeGestureAction(_:)))
        swipeRight.direction = .right
        view.addGestureRecognizer(swipeRight)
        let swipeUp = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeGestureAction(_:)))
        swipeUp.direction = .up
        view.addGestureRecognizer(swipeUp)
        return view
    }

    public func updateUIView(_ view: UIViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleUIView(_: UIViewType, coordinator: Coordinator) {
        #if os(tvOS)
        coordinator.playerLayer?.delegate = nil
        coordinator.playerLayer?.pause()
        coordinator.playerLayer = nil
        #endif
    }
    #else
    public typealias NSViewType = KSPlayerLayer
    public func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeView(url: url, options: options)
    }

    public func updateNSView(_ view: NSViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleNSView(_ view: NSViewType, coordinator _: Coordinator) {
        view.window?.contentAspectRatio = CGSize(width: 16, height: 9)
    }
    #endif

    private func updateView(_ view: KSPlayerLayer, context: Context) {
        if view.url != url {
            _ = context.coordinator.makeView(url: url, options: options)
        }
    }

    public final class Coordinator: ObservableObject {
        @Published public var isPlay: Bool = false {
            didSet {
                if isPlay != oldValue {
                    isPlay ? playerLayer?.play() : playerLayer?.pause()
                }
            }
        }

        @Published public var isMuted: Bool = false {
            didSet {
                playerLayer?.player.isMuted = isMuted
            }
        }

        @Published public var isScaleAspectFill = false {
            didSet {
                playerLayer?.player.contentMode = isScaleAspectFill ? .scaleAspectFill : .scaleAspectFit
            }
        }

        @Published public var state = KSPlayerState.prepareToPlay
        public var subtitleModel = SubtitleModel()
        @Published
        public var timemodel = ControllerTimeModel()
        public var selectedAudioTrack: MediaPlayerTrack? {
            didSet {
                if oldValue?.trackID != selectedAudioTrack?.trackID {
                    if let track = selectedAudioTrack {
                        playerLayer?.player.select(track: track)
                        playerLayer?.player.isMuted = false
                    } else {
                        playerLayer?.player.isMuted = true
                    }
                }
            }
        }

        public var selectedVideoTrack: MediaPlayerTrack? {
            didSet {
                if oldValue?.trackID != selectedVideoTrack?.trackID {
                    if let track = selectedVideoTrack {
                        playerLayer?.player.select(track: track)
                        playerLayer?.options.videoDisable = false
                    } else {
                        oldValue?.isEnabled = false
                        playerLayer?.options.videoDisable = true
                    }
                }
            }
        }

        // 在SplitView模式下，第二次进入会先调用makeUIView。然后在调用之前的dismantleUIView.所以如果进入的是同一个View的话，就会导致playerLayer被清空了。最准确的方式是在onDisappear清空playerLayer
        public var playerLayer: KSPlayerLayer?
        public var audioTracks = [MediaPlayerTrack]()
        public var videoTracks = [MediaPlayerTrack]()
        fileprivate var onPlay: ((TimeInterval, TimeInterval) -> Void)?
        fileprivate var onFinish: ((KSPlayerLayer, Error?) -> Void)?
        fileprivate var onStateChanged: ((KSPlayerLayer, KSPlayerState) -> Void)?
        fileprivate var onBufferChanged: ((Int, TimeInterval) -> Void)?
        #if canImport(UIKit)
        fileprivate var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)?
        @objc fileprivate func swipeGestureAction(_ recognizer: UISwipeGestureRecognizer) {
            onSwipe?(recognizer.direction)
        }
        #endif

        public init() {}

        public func makeView(url: URL, options: KSOptions) -> KSPlayerLayer {
            if let playerLayer {
                playerLayer.delegate = nil
                playerLayer.set(url: url, options: options)
                subtitleModel.url = url
                playerLayer.delegate = self
                return playerLayer
            } else {
                let playerLayer = KSPlayerLayer(url: url, options: options)
                subtitleModel.url = url
                playerLayer.delegate = self
                self.playerLayer = playerLayer
                return playerLayer
            }
        }

        public func skip(interval: Int) {
            if let playerLayer {
                seek(time: playerLayer.player.currentPlaybackTime + TimeInterval(interval))
            }
        }

        public func seek(time: TimeInterval) {
            playerLayer?.seek(time: TimeInterval(time))
        }
    }
}

extension KSVideoPlayer.Coordinator: KSPlayerLayerDelegate {
    public func player(layer: KSPlayerLayer, state: KSPlayerState) {
        if state == .readyToPlay {
            #if os(macOS)
            let naturalSize = layer.player.naturalSize
            layer.player.view?.window?.contentAspectRatio = naturalSize
            #endif
            videoTracks = layer.player.tracks(mediaType: .video)
            audioTracks = layer.player.tracks(mediaType: .audio)
            subtitleModel.selectedSubtitleInfo = subtitleModel.subtitleInfos.first
            selectedAudioTrack = audioTracks.first { $0.isEnabled }
            selectedVideoTrack = videoTracks.first { $0.isEnabled }
            if let subtitleDataSouce = layer.player.subtitleDataSouce {
                // 要延后增加内嵌字幕。因为有些内嵌字幕是放在视频流的。所以会比readyToPlay回调晚。
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) { [weak self] in
                    guard let self else { return }
                    self.subtitleModel.addSubtitle(dataSouce: subtitleDataSouce)
                    if self.subtitleModel.selectedSubtitleInfo == nil, layer.options.autoSelectEmbedSubtitle {
                        self.subtitleModel.selectedSubtitleInfo = self.subtitleModel.subtitleInfos.first
                    }
                }
            }
        }
        isPlay = state.isPlaying
        self.state = state
        onStateChanged?(layer, state)
    }

    public func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        onPlay?(currentTime, totalTime)
        timemodel.currentTime = Int(currentTime)
        timemodel.totalTime = Int(max(0, totalTime))
        subtitleModel.subtitle(currentTime: currentTime + layer.options.subtitleDelay)
    }

    public func player(layer: KSPlayerLayer, finish error: Error?) {
        onFinish?(layer, error)
    }

    public func player(layer _: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        onBufferChanged?(bufferedCount, consumeTime)
    }
}

extension KSVideoPlayer: Equatable {
    public static func == (lhs: KSVideoPlayer, rhs: KSVideoPlayer) -> Bool {
        lhs.url == rhs.url
    }
}

public extension KSVideoPlayer {
    func onBufferChanged(_ handler: @escaping (Int, TimeInterval) -> Void) -> Self {
        coordinator.onBufferChanged = handler
        return self
    }

    /// Playing to the end.
    func onFinish(_ handler: @escaping (KSPlayerLayer, Error?) -> Void) -> Self {
        coordinator.onFinish = handler
        return self
    }

    func onPlay(_ handler: @escaping (TimeInterval, TimeInterval) -> Void) -> Self {
        coordinator.onPlay = handler
        return self
    }

    /// Playback status changes, such as from play to pause.
    func onStateChanged(_ handler: @escaping (KSPlayerLayer, KSPlayerState) -> Void) -> Self {
        coordinator.onStateChanged = handler
        return self
    }

    #if canImport(UIKit)
    func onSwipe(_ handler: @escaping (UISwipeGestureRecognizer.Direction) -> Void) -> Self {
        coordinator.onSwipe = handler
        return self
    }
    #endif
}

/// 这是一个频繁变化的model。View要少用这个
public class ControllerTimeModel: ObservableObject {
    // 改成int才不会频繁更新
    @Published
    public var currentTime = 0
    @Published
    public var totalTime = 1
}