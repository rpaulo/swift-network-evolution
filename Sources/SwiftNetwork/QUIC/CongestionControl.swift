//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

/// The state share by all algorithms Cubic, Ledbats, and Prague
///
/// This is the single, authoritative copy of this state that is used throughout each algorithm
@available(Network 0.1.0, *)
struct CongestionControlState {
    var congestionWindow = UInt64(0)
    var bytesInFlight = UInt64(0)
    var packetsAcked = UInt64(0)
    var packetsMarked = UInt64(0)
    var ecnCECounter = 0
    var largestSentPN = Int64(0)
    var slowStartThreshold = UInt64.max
    var prevSlowStartThreshold = UInt64.max
    var recoveryStartTime = NetworkClock.Instant.zero
    var bytesAcked = UInt64(0)
    var pipeAckSamples = [UInt64(0)]
    var pipeAckValue = UInt64(0)
    var pipeAckSampleEnd = NetworkClock.Instant.zero
    var pipeAckAcked = UInt64(0)
    var pipeAckIndex = 0

    var congestionWindowValidationSamples: Int {
        3
    }

    var availableCongestionWindow: UInt64 {
        if congestionWindow > bytesInFlight {
            return congestionWindow - bytesInFlight
        } else {
            return 0
        }
    }

    func congestionWindowValidated(log: LogPrefixer) -> Bool {
        if pipeAckValue == 0 {
            return true
        }
        // In slow-start, congestionWindow increases aggressively and pipeack
        // might be lagging behind. Thus, give it 4x the space.
        if congestionWindow < slowStartThreshold {
            let congestionWindowLimit = congestionWindow >> 2
            if pipeAckValue < congestionWindowLimit {
                log.datapath(
                    "Congestion window not validated in slow-start, pipeack: \(pipeAckValue), congestionWindow \(congestionWindow)"
                )
                return false
            }
        } else {
            let congestionWindowLimit = congestionWindow >> 1
            if pipeAckValue < congestionWindowLimit {
                log.datapath(
                    "Congestion window not validated in congestion-avoidance, pipeack: \(pipeAckValue), congestionWindow: \(congestionWindow) "
                )
                return false
            }
        }

        return true
    }

    func lossFlightSize(log: LogPrefixer) -> UInt64 {
        if !congestionWindowValidated(log: log) {
            return max(pipeAckValue, bytesInFlight)
        } else {
            return congestionWindow
        }
    }

    mutating func incrementBytesInFlight(_ bytesSent: Int, log: LogPrefixer) {
        bytesInFlight += UInt64(bytesSent)
        log.datapath("Bytes in flight updated to \(bytesInFlight)")

        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func decrementBytesInFlight(_ bytes: UInt64, log: LogPrefixer) {
        let result = bytesInFlight.subtractingReportingOverflow(bytes)
        if result.overflow {
            log.fault("Undeflow, \(bytes) decremented from \(bytesInFlight)")
            bytesInFlight = 0
        } else {
            bytesInFlight = result.partialValue
        }
        log.datapath("Bytes in flight updated to \(bytesInFlight)")
        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    func packetInRecovery(sentTime: NetworkClock.Instant) -> Bool {
        sentTime <= recoveryStartTime
    }

    mutating func ackBegin() {
        bytesAcked = 0
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant, log: LogPrefixer) {
        let bytesAcked = UInt64(bytesAcked)
        decrementBytesInFlight(bytesAcked, log: log)
        if packetInRecovery(sentTime: sentTime) {
            // Dont update the congestion window
            log.datapath("Packet was sent before recovery, ignore")
            return
        }
        // Congestion window is updated later in ackEnd
        self.bytesAcked += bytesAcked
    }

    mutating func packetSent(bytesSent: Int, log: LogPrefixer, qlog: QLog? = nil) {
        incrementBytesInFlight(bytesSent, log: log)
        logUpdate(log: log, qlog: qlog)
    }

    mutating func packetDiscarded(bytesSent: Int, log: LogPrefixer, qlog: QLog? = nil) {
        decrementBytesInFlight(UInt64(bytesSent), log: log)
        logUpdate(log: log, qlog: qlog)
    }

    mutating func mssChanged(mss: Int, log: LogPrefixer, qlog: QLog? = nil) {
        congestionWindow = max(congestionWindow, UInt64(mss))
        logUpdate(log: log, qlog: qlog)
    }

    // Compute if 1RTT or 1 round has elapsed by measuring if the
    // packet sent after this instant has been acknowledged.
    // largest_sent_pn is set at the start of a round
    func rttElapsed(largestSentPN: Int64, largestAckedPN: Int64) -> Bool {
        // A packet with pn higher than largest sent pn at
        // the start of the round has been acknowledged
        (largestSentPN == 0) || (largestAckedPN > largestSentPN)
    }

    mutating func initPipeAckSamples() {
        pipeAckSamples = Array(repeating: 0, count: congestionWindowValidationSamples)
        pipeAckIndex = 0
        pipeAckValue = 0
    }

    mutating func setPipeAckSample(sample: UInt64) {
        pipeAckSamples[pipeAckIndex] = sample
        pipeAckIndex &+= 1
        pipeAckIndex = pipeAckIndex % congestionWindowValidationSamples
    }

    mutating func pipeAckNewRound(target: NetworkClock.Instant) {
        pipeAckSampleEnd = target == .zero ? .init(microseconds: 1) : target
        pipeAckAcked = 0
    }

    mutating func updatePipeAckSamples() {
        setPipeAckSample(sample: pipeAckAcked)
        pipeAckValue = pipeAckAcked
        for index in 0..<congestionWindowValidationSamples {
            if pipeAckSamples[index] > pipeAckValue {
                pipeAckValue = pipeAckSamples[index]
            }
        }
    }

    mutating func revalidateCongestionWindow(
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        log: LogPrefixer
    ) -> Bool {
        if pipeAckSampleEnd == .zero {
            pipeAckNewRound(target: now.advanced(by: smoothedRTT))
        }
        pipeAckAcked += bytesAcked
        // A full period passed? Update our pipeack samples
        if now > pipeAckSampleEnd {
            let period = pipeAckSampleEnd.duration(to: now)
            if period > smoothedRTT {
                // More than 1 RTT of inactivity, we need to set samples to 0
                setPipeAckSample(sample: 0)
                if period > smoothedRTT * 2 {
                    // Reset the next sample as well
                    setPipeAckSample(sample: 0)
                }
            }
            updatePipeAckSamples()
            pipeAckNewRound(target: now + smoothedRTT)
        }
        return congestionWindowValidated(log: log)
    }

    func canSend(packetLength: Int, log: LogPrefixer) -> Bool {
        if availableCongestionWindow >= packetLength {
            log.datapath(
                "Can send packet because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) <= congestionWindow \(congestionWindow)"
            )
            return true
        } else {
            log.datapath(
                "Congestion limited because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) > congestionWindow \(congestionWindow)"
            )
            QUICSignpost.congestionWindowLimited(
                bytesInFlight: Int(bytesInFlight),
                congestionWindow: Int(congestionWindow)
            )
            return false
        }
    }

    func logUpdate(log: LogPrefixer, qlog: QLog?) {
        if congestionWindow != UInt64.max {
            log.datapath("Congestion window set to \(congestionWindow) bytes, bytes in flight \(bytesInFlight)")
            QUICSignpost.congestionWindow(congestionWindow: Int(congestionWindow))
        }
        #if QlogOutput
        if let qlog {
            qlog.congestionControlUpdated(
                congestionWindow: congestionWindow,
                bytesInFlight: bytesInFlight,
                slowStartThresh: slowStartThreshold
            )
        }
        #endif
    }
}

// An operation on whichever congestion controller is active, with the shared state.
@available(Network 0.1.0, *)
protocol CongestionControlOperation: ~Copyable {
    associatedtype Result
    func callAsFunction<Controller: CongestionControlProtocol>(
        _ controller: inout Controller,
        state: inout CongestionControlState
    ) -> Result
}

/// Owns the shared congestion control state plus the active algorithm.
///
/// Every controller is stored in place so algorithm-specific calls mutate it directly
/// instead of copying it out of an enum and back. Operations that only touch the shared
/// state go straight to `state` without dispatching on the algorithm.
@available(Network 0.1.0, *)
struct CongestionControl: ~Copyable {
    enum Algorithm: UInt8 {
        case cubic
        #if !NETWORK_EMBEDDED
        case ledbat
        case prague
        #endif

        var name: String {
            switch self {
            case .cubic: return "CUBIC"
            #if !NETWORK_EMBEDDED
            case .ledbat: return "LEDBAT"
            case .prague: return "PRAGUE"
            #endif
            }
        }
    }

    private(set) var state = CongestionControlState()
    let log: LogPrefixer
    private(set) var algorithm: Algorithm
    private var cubic: Cubic
    #if !NETWORK_EMBEDDED
    private var ledbat: Ledbat
    private var prague: Prague
    #endif

    init(
        algorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog? = nil,
        logPrefixer: LogPrefixer
    ) {
        self.log = logPrefixer
        self.algorithm = algorithm
        // Only the active controller is set up; the others hold no state until switched to.
        self.cubic = Cubic(placeholder: logPrefixer)
        #if !NETWORK_EMBEDDED
        self.ledbat = Ledbat(placeholder: logPrefixer)
        self.prague = Prague(placeholder: logPrefixer)
        #endif
        reset(pacer: &pacer, mss: mss, qlog: qlog)
    }

    // Re-creates the active controller and the shared state from scratch.
    mutating func reset(pacer: inout Pacer, mss: Int, qlog: QLog?) {
        state = CongestionControlState()
        switch algorithm {
        case .cubic:
            cubic = Cubic(state: &state, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: log)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat = Ledbat(state: &state, mss: mss, qlog: qlog, logPrefixer: log)
        case .prague:
            prague = Prague(state: &state, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: log)
        #endif
        }
    }

    #if !NETWORK_EMBEDDED
    // Switches to another algorithm, handing it the outgoing shared state.
    mutating func switchTo(_ newAlgorithm: Algorithm, pacer: inout Pacer, mss: Int, qlog: QLog?) {
        guard newAlgorithm != algorithm else { return }
        let oldState = state
        state = CongestionControlState()
        switch newAlgorithm {
        case .cubic:
            cubic = Cubic(state: &state, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: log)
            cubic.inherit(from: oldState, state: &state, mss: mss, qlog: qlog)
        case .ledbat:
            ledbat = Ledbat(state: &state, mss: mss, qlog: qlog, logPrefixer: log)
            ledbat.inherit(from: oldState, state: &state, mss: mss, qlog: qlog)
        case .prague:
            prague = Prague(state: &state, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: log)
            prague.inherit(from: oldState, state: &state, mss: mss, qlog: qlog)
        }
        algorithm = newAlgorithm
    }
    #endif

    // Dispatches an algorithm-specific operation on the active controller.
    @inline(always)
    private mutating func perform<Operation: CongestionControlOperation & ~Copyable>(
        _ operation: borrowing Operation
    ) -> Operation.Result {
        switch algorithm {
        case .cubic: return operation(&cubic, state: &state)
        #if !NETWORK_EMBEDDED
        case .ledbat: return operation(&ledbat, state: &state)
        case .prague: return operation(&prague, state: &state)
        #endif
        }
    }

    var name: String { algorithm.name }

    // MARK: Shared state; no dispatch.

    var congestionWindow: UInt64 { state.congestionWindow }
    var availableCongestionWindow: UInt64 { state.availableCongestionWindow }
    var bytesInFlight: UInt64 { state.bytesInFlight }

    func canSend(packetLength: Int) -> Bool {
        state.canSend(packetLength: packetLength, log: log)
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        state.packetSent(bytesSent: bytesSent, log: log, qlog: qlog)
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        state.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime, log: log)
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        state.packetDiscarded(bytesSent: bytesSent, log: log, qlog: qlog)
    }

    mutating func ackBegin() {
        state.ackBegin()
    }

    mutating func mssChanged(mss: Int) {
        state.mssChanged(mss: mss, log: log, qlog: nil)
    }

    // MARK: Algorithm-specific; dispatched to the active controller.

    // `inout` arguments can't be stored in an operation, so this one dispatches by hand.
    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        switch algorithm {
        case .cubic:
            cubic.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        case .prague:
            prague.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        #endif
        }
    }

    // `rtt` is borrowed, and an operation can't hold a borrow without `Ref` (Swift 6.4,
    // OS 27); this one dispatches by hand.
    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        switch algorithm {
        case .cubic:
            cubic.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        case .prague:
            prague.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        #endif
        }
    }

    @inline(always)
    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        perform(Op.PersistentCongestion(mss: mss, qlog: qlog))
    }

    @inline(always)
    @discardableResult
    mutating func packetsLost(
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> Bool {
        perform(
            Op.PacketsLost(
                path: path,
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
        )
    }

    @inline(always)
    mutating func processECN(
        path: QUICPath?,
        ceCount: Int,
        packetsAcked: Int,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        perform(
            Op.ProcessECN(
                path: path,
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now,
                qlog: qlog
            )
        )
    }

    @inline(always)
    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        perform(Op.SpuriousRetransmit(qlog: qlog))
    }

    @inline(always)
    mutating func idleTimeout(mss: Int) {
        perform(Op.IdleTimeout(mss: mss))
    }
}

// MARK: - Operations

@available(Network 0.1.0, *)
extension CongestionControl {
    fileprivate enum Op {
        struct PersistentCongestion: CongestionControlOperation, ~Copyable {
            let mss: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(
                _ controller: inout Controller,
                state: inout CongestionControlState
            ) {
                controller.persistentCongestion(state: &state, mss: mss, qlog: qlog)
            }
        }

        struct PacketsLost: CongestionControlOperation, ~Copyable {
            let path: QUICPath?
            let bytesLost: Int
            let largestLostSentTime: NetworkClock.Instant
            let mss: Int
            let smoothedRTT: NetworkDuration
            let now: NetworkClock.Instant

            func callAsFunction<Controller: CongestionControlProtocol>(
                _ controller: inout Controller,
                state: inout CongestionControlState
            ) -> Bool {
                controller.packetLost(
                    state: &state,
                    path: path,
                    bytesLost: bytesLost,
                    largestLostSentTime: largestLostSentTime,
                    mss: mss,
                    smoothedRTT: smoothedRTT,
                    now: now,
                    qlog: nil
                )
            }
        }

        struct ProcessECN: CongestionControlOperation, ~Copyable {
            let path: QUICPath?
            let ceCount: Int
            let packetsAcked: Int
            let largestSentPN: Int64
            let largestAckedPN: Int64
            let largestAckedSentTime: NetworkClock.Instant
            let mss: Int
            let smoothedRTT: NetworkDuration
            let now: NetworkClock.Instant
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(
                _ controller: inout Controller,
                state: inout CongestionControlState
            ) {
                controller.processECN(
                    state: &state,
                    path: path,
                    ceCount: ceCount,
                    packetsAcked: packetsAcked,
                    largestSentPN: largestSentPN,
                    largestAckedPN: largestAckedPN,
                    largestAckedSentTime: largestAckedSentTime,
                    mss: mss,
                    smoothedRTT: smoothedRTT,
                    now: now,
                    qlog: qlog
                )
            }
        }

        struct SpuriousRetransmit: CongestionControlOperation, ~Copyable {
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(
                _ controller: inout Controller,
                state: inout CongestionControlState
            ) {
                controller.spuriousRetransmit(state: &state, qlog: qlog)
            }
        }

        struct IdleTimeout: CongestionControlOperation, ~Copyable {
            let mss: Int

            func callAsFunction<Controller: CongestionControlProtocol>(
                _ controller: inout Controller,
                state: inout CongestionControlState
            ) {
                controller.idleTimeout(state: &state, mss: mss, qlog: nil)
            }
        }
    }
}

@available(Network 0.1.0, *)
protocol CongestionControlProtocol: PrefixedLoggable {
    mutating func inherit(
        from: CongestionControlState,
        state: inout CongestionControlState,
        mss: Int,
        qlog: QLog?
    )
    mutating func reset(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    mutating func ackEnd(
        state: inout CongestionControlState,
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func spuriousRetransmit(state: inout CongestionControlState, qlog: QLog?)
    mutating func idleTimeout(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    /// Opens a recovery period at `now`, the time the loss was detected.
    mutating func enterRecovery(state: inout CongestionControlState, mss: Int, now: NetworkClock.Instant, qlog: QLog?)
    mutating func processECN(
        state: inout CongestionControlState,
        path: QUICPath?,
        ceCount: Int,
        packetsAcked: Int,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func packetLost(
        state: inout CongestionControlState,
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog?
    ) -> Bool
    mutating func persistentCongestion(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    func filloutDataTransferSnapshot(state: CongestionControlState, dataTransferSnapshot: inout DataTransferSnapshot)
}

@available(Network 0.1.0, *)
extension CongestionControlProtocol {
    mutating func packetSent(state: inout CongestionControlState, bytesSent: Int, qlog: QLog? = nil) {
        state.packetSent(bytesSent: bytesSent, log: log, qlog: qlog)
    }

    mutating func packetDiscarded(state: inout CongestionControlState, bytesSent: Int, qlog: QLog? = nil) {
        state.packetDiscarded(bytesSent: bytesSent, log: log, qlog: qlog)
    }

    mutating func ackBegin(state: inout CongestionControlState) {
        state.ackBegin()
    }

    mutating func packetsAcked(state: inout CongestionControlState, bytesAcked: Int, sentTime: NetworkClock.Instant) {
        state.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime, log: log)
    }

    mutating func mssChanged(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.mssChanged(mss: mss, log: log, qlog: qlog)
    }

    func canSend(state: CongestionControlState, packetLength: Int) -> Bool {
        state.canSend(packetLength: packetLength, log: log)
    }

    /// `sentTime` is when the packet went out, `now` when its loss was detected.
    @discardableResult
    mutating func congestionEvent(
        state: inout CongestionControlState,
        sentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        // If the packet was sent before recovery started, do nothing
        if state.packetInRecovery(sentTime: sentTime) { return false }
        // Enter recovery if the packet was sent
        // after start of the previous recovery period
        enterRecovery(state: &state, mss: mss, now: now, qlog: qlog)
        return true
    }

    mutating func linkFlowControl(
        state: inout CongestionControlState,
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        congestionEvent(state: &state, sentTime: largestAckSentTime, mss: mss, now: now, qlog: qlog)
        log.debug(
            "Link was flow controlled, reduced congestion window is \(state.congestionWindow) bytes"
        )
    }

    func logState(
        qlog: QLog? = nil,
        state: QLogCongestionState,
        trigger: QLogCongestionTrigger?
    ) {
        #if QlogOutput
        if let qlog {
            qlog.logCongestionStateUpdated(
                oldState: nil,
                newState: state,
                trigger: trigger
            )
        }
        #endif
    }
}
#endif
