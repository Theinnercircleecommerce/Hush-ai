//
//  CaptureWatchdog.swift
//  Hush
//
//  Pure liveness verdict for the system-audio leg. SCStream delivers audio
//  buffers continuously even in a silent room, so "no buffers" means the
//  STREAM is broken (permission pulled, display change, SCStream error) —
//  never that nobody happens to be talking. That distinction is what makes
//  a buffer count a safe liveness signal and loudness an unsafe one.
//
//  Pure so it is testable with plain dates; the timer that feeds it lives
//  in MeetingSession.
//

import Foundation

struct CaptureHealth: Equatable {
    var buffersDelivered: Int64
    var lastBufferAt: Date?
    var streamDied: Bool
}

enum CaptureVerdict: Equatable {
    case waitingForFirstBuffer
    case alive
    case dead(String)
}

enum CaptureWatchdog {
    /// - firstBufferGrace: SCStream normally lands its first audio buffer
    ///   well under a second after startCapture; 5s of nothing is broken.
    /// - stallLimit: buffers arrive tens of times per second; 10s of
    ///   silence after audio HAS flowed means the stream died quietly.
    static func verdict(health: CaptureHealth,
                        startedAt: Date,
                        now: Date,
                        firstBufferGrace: TimeInterval = 5,
                        stallLimit: TimeInterval = 10) -> CaptureVerdict {
        if health.streamDied {
            return .dead("system audio stopped mid-call")
        }
        guard health.buffersDelivered > 0 else {
            return now.timeIntervalSince(startedAt) < firstBufferGrace
                ? .waitingForFirstBuffer
                : .dead("no system audio arriving — check screen recording permission")
        }
        if let last = health.lastBufferAt, now.timeIntervalSince(last) > stallLimit {
            return .dead("system audio stopped mid-call")
        }
        return .alive
    }
}
