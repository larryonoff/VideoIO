//
//  File.swift
//  
//
//  Created by Yu Ao on 2019/12/18.
//

import Foundation
import AVFoundation

public class AssetExportSession {
    
    public struct Configuration {
        
        public var fileType: AVFileType
        
        public var shouldOptimizeForNetworkUse: Bool = true
        
        public var videoSettings: [String: Any]
        
        public var audioSettings: [String: Any]
        
        public var timeRange: CMTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
        
        public var metadata: [AVMetadataItem] = []
        
        public var videoComposition: AVVideoComposition?
        
        public var audioMix: AVAudioMix?
        
        public init(fileType: AVFileType, rawVideoSettings: [String: Any], rawAudioSettings: [String: Any]) {
            self.fileType = fileType
            self.videoSettings = rawVideoSettings
            self.audioSettings = rawAudioSettings
        }
        
        public init(fileType: AVFileType, videoSettings: VideoSettings, audioSettings: AudioSettings) {
            self.fileType = fileType
            self.videoSettings = videoSettings.toDictionary()
            self.audioSettings = audioSettings.toDictionary()
        }
    }
    
    public enum Status {
        case idle
        case exporting
        case paused
        case completed
    }
    
    public enum Error: Swift.Error {
        case noTracks
        case cannotAddVideoOutput
        case cannotAddVideoInput
        case cannotAddAudioOutput
        case cannotAddAudioInput
        case cannotStartWriting
        case cannotStartReading
        case invalidStatus
        case cancelled
    }
    
    public private(set) var status: Status = .idle
    
    private let asset: AVAsset
    private let configuration: Configuration
    private let outputURL: URL
    
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    
    private let videoOutput: AVAssetReaderOutput?
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    
    private let queue: DispatchQueue = DispatchQueue(label: "com.MetalPetal.VideoIO.AssetExportSession")
    private let duration: CMTime
    
    private let pauseDispatchGroup = DispatchGroup()
    private var cancelled: Bool = false
    
    public init(asset: AVAsset, outputURL: URL, configuration: Configuration) throws {
        self.asset = asset.copy() as! AVAsset
        self.configuration = configuration
        self.outputURL = outputURL
        
        self.reader = try AVAssetReader(asset: asset)
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: configuration.fileType)
        self.reader.timeRange = configuration.timeRange
        self.writer.shouldOptimizeForNetworkUse = configuration.shouldOptimizeForNetworkUse
        self.writer.metadata = configuration.metadata
        
        if configuration.timeRange.duration.isValid && !configuration.timeRange.duration.isPositiveInfinity {
            self.duration = configuration.timeRange.duration
        } else {
            self.duration = asset.duration
        }
        
        let videoTracks = asset.tracks(withMediaType: .video)
        if (videoTracks.count > 0) {
            let videoOutput: AVAssetReaderOutput
            let inputTransform: CGAffineTransform?
            if configuration.videoComposition != nil {
                let videoCompositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: nil)
                videoCompositionOutput.alwaysCopiesSampleData = false
                videoCompositionOutput.videoComposition = configuration.videoComposition
                videoOutput = videoCompositionOutput
                inputTransform = nil
            } else {
                if #available(iOS 13.0, macOS 10.15, *) {
                    if videoTracks.first!.hasMediaCharacteristic(.containsAlphaChannel) {
                        videoOutput = AVAssetReaderTrackOutput(track: videoTracks.first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    } else {
                        videoOutput = AVAssetReaderTrackOutput(track: videoTracks.first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]])
                    }
                } else {
                    videoOutput = AVAssetReaderTrackOutput(track: videoTracks.first!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]])
                }
                videoOutput.alwaysCopiesSampleData = false
                inputTransform = videoTracks.first!.preferredTransform
            }
            if self.reader.canAdd(videoOutput) {
                self.reader.add(videoOutput)
            } else {
                throw Error.cannotAddVideoOutput
            }
            self.videoOutput = videoOutput
            
            let videoInput: AVAssetWriterInput
            if let transform = inputTransform {
                let size = CGSize(width: configuration.videoSettings[AVVideoWidthKey] as! CGFloat, height: configuration.videoSettings[AVVideoHeightKey] as! CGFloat)
                let transformedSize = size.applying(transform.inverted())
                var videoSettings = configuration.videoSettings
                videoSettings[AVVideoWidthKey] = abs(transformedSize.width)
                videoSettings[AVVideoHeightKey] = abs(transformedSize.height)
                videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.transform = transform
            } else {
                videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: configuration.videoSettings)
            }
            videoInput.expectsMediaDataInRealTime = false
            if self.writer.canAdd(videoInput) {
                self.writer.add(videoInput)
            } else {
                throw Error.cannotAddVideoInput
            }
            self.videoInput = videoInput
        } else {
            self.videoOutput = nil
            self.videoInput = nil
        }
        
        let audioTracks = self.asset.tracks(withMediaType: .audio)
        if audioTracks.count > 0 {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            audioOutput.audioMix = configuration.audioMix
            if self.reader.canAdd(audioOutput) {
                self.reader.add(audioOutput)
            } else {
                throw Error.cannotAddAudioOutput
            }
            self.audioOutput = audioOutput
            
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: configuration.audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            if self.writer.canAdd(audioInput) {
                self.writer.add(audioInput)
            }
            self.audioInput = audioInput
        } else {
            self.audioOutput = nil
            self.audioInput = nil
        }
        
        if videoTracks.count == 0 && audioTracks.count == 0 {
            throw Error.noTracks
        }
    }
    
    private func encode(from output: AVAssetReaderOutput, to input: AVAssetWriterInput) -> Bool {
        while input.isReadyForMoreMediaData {
            if self.reader.status != .reading || self.writer.status != .writing {
                return false
            }
            self.pauseDispatchGroup.wait()
            if let buffer = output.copyNextSampleBuffer() {
                if self.videoOutput === output {
                    let units = Int64((CMSampleBufferGetPresentationTimeStamp(buffer) - self.configuration.timeRange.start).seconds * 1000)
                    DispatchQueue.main.async {
                        if let progress = self.progress {
                            progress.completedUnitCount = units
                            self.progressHandler?(progress)
                        }
                    }
                }
                
                if !input.append(buffer) {
                    return false
                }
            } else {
                input.markAsFinished()
                return false
            }
        }
        return true
    }
    
    private var progress: Progress?
    private var progressHandler: ((Progress) -> Void)?

    public func export(progress: ((Progress) -> Void)?, completion: @escaping (Swift.Error?) -> Void) {
        assert(status == .idle && cancelled == false)
        if self.status != .idle || cancelled {
            DispatchQueue.main.async {
                completion(Error.invalidStatus)
            }
            return
        }
        
        self.progress = Progress(totalUnitCount: Int64(self.duration.seconds * 1000))
        self.progressHandler = progress
        
        do {
            guard self.writer.startWriting() else {
                if let error = self.writer.error {
                    throw error
                } else {
                    throw Error.cannotStartWriting
                }
            }
            guard self.reader.startReading() else {
                if let error = self.reader.error {
                    throw error
                } else {
                    throw Error.cannotStartReading
                }
            }
        } catch {
            DispatchQueue.main.async {
                completion(error)
            }
        }
        
        self.status = .exporting
        self.writer.startSession(atSourceTime: configuration.timeRange.start)
        
        var videoCompleted = false
        var audioCompleted = false

        if let videoInput = self.videoInput, let videoOutput = self.videoOutput {
            videoInput.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                guard let strongSelf = self else { return }
                if !strongSelf.encode(from: videoOutput, to: videoInput) {
                    videoCompleted = true
                    if audioCompleted {
                        strongSelf.finish(completionHandler: completion)
                    }
                }
            }
        } else {
            videoCompleted = true
        }
        
        if let audioInput = self.audioInput, let audioOutput = self.audioOutput {
            audioInput.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                guard let strongSelf = self else { return }
                if !strongSelf.encode(from: audioOutput, to: audioInput) {
                    audioCompleted = true
                    if videoCompleted {
                        strongSelf.finish(completionHandler: completion)
                    }
                }
            }
        } else {
            audioCompleted = true
        }
    }
    
    private func dispatchCallback(with error: Swift.Error?, _ completionHandler: @escaping (Swift.Error?) -> Void) {
        DispatchQueue.main.async {
            self.status = .completed
            completionHandler(error)
        }
    }
    
    private func finish(completionHandler: @escaping (Swift.Error?) -> Void) {
        if self.reader.status == .cancelled || self.writer.status == .cancelled {
            if self.writer.status != .cancelled {
                self.writer.cancelWriting()
            } else {
                assertionFailure("Internal error. Please file a bug report.")
            }
            
            if self.reader.status != .cancelled {
                assertionFailure("Internal error. Please file a bug report.")
                self.reader.cancelReading()
            }
            
            try? FileManager().removeItem(at: self.outputURL)
            self.dispatchCallback(with: Error.cancelled, completionHandler)
            return
        }
        
        if self.writer.status == .failed {
            try? FileManager().removeItem(at: self.outputURL)
            self.dispatchCallback(with: self.writer.error, completionHandler)
        } else if self.reader.status == .failed {
            try? FileManager().removeItem(at: self.outputURL)
            self.writer.cancelWriting()
            self.dispatchCallback(with: self.reader.error, completionHandler)
        } else {
            self.writer.finishWriting { [weak self] in
                guard let strongSelf = self else { return }
                if strongSelf.writer.status == .failed {
                    try? FileManager().removeItem(at: strongSelf.outputURL)
                }
                strongSelf.dispatchCallback(with: strongSelf.writer.error, completionHandler)
            }
        }
    }
    
    public func pause() {
        guard self.status == .exporting && self.cancelled == false else {
            assertionFailure("self.status == .exporting && self.cancelled == false")
            return
        }
        self.status = .paused
        self.pauseDispatchGroup.enter()
    }
    
    public func resume() {
        guard self.status == .paused && self.cancelled == false else {
            assertionFailure("self.status == .paused && self.cancelled == false")
            return
        }
        self.status = .exporting
        self.pauseDispatchGroup.leave()
    }
    
    public func cancel() {
        guard self.status == .exporting && self.cancelled == false else {
            assertionFailure("self.status == .exporting && self.cancelled == false")
            return
        }
        self.cancelled = true
        self.queue.async {
            self.reader.cancelReading()
        }
    }
    
    deinit {
        if self.status == .paused {
            self.pauseDispatchGroup.leave()
        }
    }
}

extension AssetExportSession {
    public static func fileType(for url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mp4":
            return .mp4
        case "mp3":
            return .mp3
        case "mov":
            return .mov
        case "qt":
            return .mov
        case "m4a":
            return .m4a
        case "m4v":
            return .m4v
        case "amr":
            return .amr
        case "caf":
            return .caf
        case "wav":
            return .wav
        case "wave":
            return .wav
        default:
            return nil
        }
    }
}
