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

// An operation on whichever congestion controller is active.
@available(Network 0.1.0, *)
protocol CongestionControlOperation: ~Copyable {
    associatedtype Result
    // Returned when there is no controller yet.
    static var resultWhenUninitialized: Result { get }
    func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) -> Result
}

@available(Network 0.1.0, *)
extension CongestionControlOperation where Self: ~Copyable, Result == Void {
    static var resultWhenUninitialized: Void { () }
}

// A read of whichever congestion controller is active.
@available(Network 0.1.0, *)
protocol CongestionControlQuery: ~Copyable {
    associatedtype Result
    // Returned when there is no controller yet.
    static var resultWhenUninitialized: Result { get }
    func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> Result
}

@available(Network 0.1.0, *)
enum CongestionControl: ~Copyable {
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

    // No controller yet (before `QUICPath.setup()`): operations do nothing and reads return zero.
    case uninitialized
    case cubic(Cubic)
    #if !NETWORK_EMBEDDED
    case ledbat(Ledbat)
    case prague(Prague)
    #endif

    init(
        algorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog? = nil,
        logPrefixer: LogPrefixer
    ) {
        self = Self.make(algorithm, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
    }

    private static func make(
        _ algorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog?,
        logPrefixer: LogPrefixer
    ) -> CongestionControl {
        switch algorithm {
        case .cubic:
            return .cubic(Cubic(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer))
        #if !NETWORK_EMBEDDED
        case .ledbat:
            return .ledbat(Ledbat(mss: mss, qlog: qlog, logPrefixer: logPrefixer))
        case .prague:
            return .prague(Prague(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer))
        #endif
        }
    }

    // The active algorithm, or `nil` before a controller has been created.
    var algorithm: Algorithm? {
        switch self {
        case .uninitialized: return nil
        case .cubic: return .cubic
        #if !NETWORK_EMBEDDED
        case .ledbat: return .ledbat
        case .prague: return .prague
        #endif
        }
    }

    // Re-creates the active controller from scratch.
    mutating func reset(pacer: inout Pacer, mss: Int, qlog: QLog?, logPrefixer: LogPrefixer) {
        guard let algorithm else { return }
        self = Self.make(algorithm, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
    }

    #if !NETWORK_EMBEDDED
    // Switches to another algorithm, handing it the outgoing controller's state.
    mutating func switchTo(
        _ newAlgorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog?,
        logPrefixer: LogPrefixer
    ) {
        guard let algorithm, algorithm != newAlgorithm else { return }
        var next = Self.make(newAlgorithm, pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
        switch self {
        case .uninitialized: break
        case .cubic(let previous): next.perform(Op.Inherit(previous: previous, mss: mss, qlog: qlog))
        case .ledbat(let previous): next.perform(Op.Inherit(previous: previous, mss: mss, qlog: qlog))
        case .prague(let previous): next.perform(Op.Inherit(previous: previous, mss: mss, qlog: qlog))
        }
        self = next
    }
    #endif

    // Dispatches a mutating operation on the algorithm. Consuming `self` moves the controller
    // out, so it is uniquely owned while it is mutated and then moved back.
    @inline(always)
    private mutating func perform<Operation: CongestionControlOperation & ~Copyable>(
        _ operation: borrowing Operation
    ) -> Operation.Result {
        switch consume self {
        case .uninitialized:
            self = .uninitialized
            return Operation.resultWhenUninitialized
        case .cubic(var controller):
            let result = operation(&controller)
            self = .cubic(controller)
            return result
        #if !NETWORK_EMBEDDED
        case .ledbat(var controller):
            let result = operation(&controller)
            self = .ledbat(controller)
            return result
        case .prague(var controller):
            let result = operation(&controller)
            self = .prague(controller)
            return result
        #endif
        }
    }

    // Dispatches a query operation on the algorithm.
    @inline(always)
    private func inspect<Query: CongestionControlQuery & ~Copyable>(
        _ query: borrowing Query
    ) -> Query.Result {
        switch self {
        case .uninitialized: return Query.resultWhenUninitialized
        case .cubic(let controller): return query(controller)
        #if !NETWORK_EMBEDDED
        case .ledbat(let controller): return query(controller)
        case .prague(let controller): return query(controller)
        #endif
        }
    }

    var name: String { algorithm?.name ?? "none" }

    var congestionWindow: UInt64 { inspect(Read.CongestionWindow()) }
    var availableCongestionWindow: UInt64 { inspect(Read.AvailableCongestionWindow()) }
    var bytesInFlight: UInt64 { inspect(Read.BytesInFlight()) }
    func canSend(packetLength: Int) -> Bool { inspect(Read.CanSend(packetLength: packetLength)) }

    // `inout` arguments can't be stored in a query, so this one dispatches by hand.
    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        switch self {
        case .uninitialized:
            break
        case .cubic(let controller):
            controller.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #if !NETWORK_EMBEDDED
        case .ledbat(let controller):
            controller.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        case .prague(let controller):
            controller.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #endif
        }
    }

    @inline(always)
    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        perform(Op.PersistentCongestion(mss: mss, qlog: qlog))
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
        switch consume self {
        case .uninitialized:
            self = .uninitialized
        case .cubic(var controller):
            controller.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .cubic(controller)
        #if !NETWORK_EMBEDDED
        case .ledbat(var controller):
            controller.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .ledbat(controller)
        case .prague(var controller):
            controller.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .prague(controller)
        #endif
        }
    }

    @inline(always)
    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        perform(Op.PacketSent(bytesSent: bytesSent, qlog: qlog))
    }

    @inline(always)
    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        perform(Op.PacketsAcked(bytesAcked: bytesAcked, sentTime: sentTime))
    }

    @inline(always)
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
    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        perform(Op.PacketDiscarded(bytesSent: bytesSent, qlog: qlog))
    }

    @inline(always)
    mutating func ackBegin() {
        perform(Op.AckBegin())
    }

    @inline(always)
    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        perform(Op.SpuriousRetransmit(qlog: qlog))
    }

    @inline(always)
    mutating func mssChanged(mss: Int) {
        perform(Op.MSSChanged(mss: mss))
    }

    @inline(always)
    mutating func idleTimeout(mss: Int) {
        perform(Op.IdleTimeout(mss: mss))
    }
}

// MARK: - Operations and queries

@available(Network 0.1.0, *)
extension CongestionControl {
    fileprivate enum Read {
        struct CongestionWindow: CongestionControlQuery, ~Copyable {
            static var resultWhenUninitialized: UInt64 { 0 }

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.congestionWindow
            }
        }

        struct AvailableCongestionWindow: CongestionControlQuery, ~Copyable {
            static var resultWhenUninitialized: UInt64 { 0 }

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.availableCongestionWindow
            }
        }

        struct BytesInFlight: CongestionControlQuery, ~Copyable {
            static var resultWhenUninitialized: UInt64 { 0 }

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.bytesInFlight
            }
        }

        struct CanSend: CongestionControlQuery, ~Copyable {
            static var resultWhenUninitialized: Bool { false }

            let packetLength: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> Bool {
                controller.canSend(packetLength: packetLength)
            }
        }
    }

    fileprivate enum Op {
        #if !NETWORK_EMBEDDED
        struct Inherit<Previous: CongestionControlProtocol>: CongestionControlOperation, ~Copyable {
            let previous: Previous
            let mss: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.inherit(from: previous, mss: mss, qlog: qlog)
            }
        }
        #endif

        struct PersistentCongestion: CongestionControlOperation, ~Copyable {
            let mss: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.persistentCongestion(mss: mss, qlog: qlog)
            }
        }

        struct PacketSent: CongestionControlOperation, ~Copyable {
            let bytesSent: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetSent(bytesSent: bytesSent, qlog: qlog)
            }
        }

        struct PacketsAcked: CongestionControlOperation, ~Copyable {
            let bytesAcked: Int
            let sentTime: NetworkClock.Instant

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
            }
        }

        struct PacketsLost: CongestionControlOperation, ~Copyable {
            static var resultWhenUninitialized: Bool { false }

            let path: QUICPath?
            let bytesLost: Int
            let largestLostSentTime: NetworkClock.Instant
            let mss: Int
            let smoothedRTT: NetworkDuration
            let now: NetworkClock.Instant

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) -> Bool {
                controller.packetLost(
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

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.processECN(
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

        struct PacketDiscarded: CongestionControlOperation, ~Copyable {
            let bytesSent: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
            }
        }

        struct AckBegin: CongestionControlOperation, ~Copyable {
            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.ackBegin()
            }
        }

        struct SpuriousRetransmit: CongestionControlOperation, ~Copyable {
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.spuriousRetransmit(qlog: qlog)
            }
        }

        struct MSSChanged: CongestionControlOperation, ~Copyable {
            let mss: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.mssChanged(mss: mss, qlog: nil)
            }
        }

        struct IdleTimeout: CongestionControlOperation, ~Copyable {
            let mss: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.idleTimeout(mss: mss, qlog: nil)
            }
        }
    }
}

// Congestion window validation samples (RFC 7661 pipeACK), stored inline to avoid a heap
// allocation per controller.
@available(Network 0.1.0, *)
typealias PipeAckSamples = [3 of UInt64]

@available(Network 0.1.0, *)
protocol CongestionControlProtocol: PrefixedLoggable {
    var congestionWindow: UInt64 { get set }
    var bytesInFlight: UInt64 { get set }
    var packetsAcked: UInt64 { get set }
    var packetsMarked: UInt64 { get set }
    var ecnCECounter: Int { get set }
    var largestSentPN: Int64 { get set }
    var slowStartThreshold: UInt64 { get set }
    var prevSlowStartThreshold: UInt64 { get set }
    var recoveryStartTime: NetworkClock.Instant { get set }
    var bytesAcked: UInt64 { get set }
    var pipeAckSamples: PipeAckSamples { get set }
    var pipeAckValue: UInt64 { get set }
    var pipeAckSampleEnd: NetworkClock.Instant { get set }
    var pipeAckAcked: UInt64 { get set }
    var pipeAckIndex: Int { get set }

    mutating func inherit(
        from other: some CongestionControlProtocol,
        mss: Int,
        qlog: QLog?
    )
    mutating func reset(mss: Int, qlog: QLog?)
    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func spuriousRetransmit(qlog: QLog?)
    mutating func idleTimeout(mss: Int, qlog: QLog?)
    // Opens a recovery period at `now`, the time the loss was detected.
    mutating func enterRecovery(mss: Int, now: NetworkClock.Instant, qlog: QLog?)
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
        qlog: QLog?
    )
    mutating func packetLost(
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog?
    ) -> Bool
    mutating func linkFlowControl(
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func persistentCongestion(mss: Int, qlog: QLog?)
    mutating func mssChanged(mss: Int, qlog: QLog?)
    mutating func packetDiscarded(bytesSent: Int, qlog: QLog?)
    mutating func ackBegin()
    mutating func packetSent(bytesSent: Int, qlog: QLog?)
    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant)
}

@available(Network 0.1.0, *)
extension CongestionControlProtocol {
    var congestionWindowValidationSamples: Int {
        PipeAckSamples.count
    }

    var availableCongestionWindow: UInt64 {
        if congestionWindow > bytesInFlight {
            return congestionWindow - bytesInFlight
        } else {
            return 0
        }
    }

    var congestionWindowValidated: Bool {
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

    var lossFlightSize: UInt64 {
        if !congestionWindowValidated {
            return max(pipeAckValue, bytesInFlight)
        } else {
            return congestionWindow
        }
    }

    mutating private func incrementBytesInFlight(_ bytesSent: Int) {
        bytesInFlight += UInt64(bytesSent)
        log.datapath("Bytes in flight updated to \(bytesInFlight)")

        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func decrementBytesInFlight(_ bytes: UInt64) {
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

    mutating func mssChanged(mss: Int, qlog: QLog? = nil) {
        congestionWindow = max(congestionWindow, UInt64(mss))
        logUpdate(qlog: qlog)
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        incrementBytesInFlight(bytesSent)
        logUpdate(qlog: qlog)
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        decrementBytesInFlight(UInt64(bytesSent))
        logUpdate(qlog: qlog)
    }

    mutating func ackBegin() {
        bytesAcked = 0
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        let bytesAcked = UInt64(bytesAcked)
        decrementBytesInFlight(bytesAcked)
        if packetInRecovery(sentTime: sentTime) {
            // Dont update the congestion window
            log.datapath("Packet was sent before recovery, ignore")
            return
        }
        // Congestion window is updated later in ackEnd
        self.bytesAcked += bytesAcked
    }

    func packetInRecovery(sentTime: NetworkClock.Instant) -> Bool {
        sentTime <= recoveryStartTime
    }

    // `sentTime` is when the packet went out, `now` when its loss was detected.
    @discardableResult
    mutating func congestionEvent(
        sentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        // If the packet was sent before recovery started, do nothing
        if packetInRecovery(sentTime: sentTime) { return false }
        // Enter recovery if the packet was sent
        // after start of the previous recovery period
        enterRecovery(mss: mss, now: now, qlog: qlog)
        return true
    }

    mutating func linkFlowControl(
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        congestionEvent(sentTime: largestAckSentTime, mss: mss, now: now, qlog: qlog)
        log.debug(
            "Link was flow controlled, reduced congestion window is \(congestionWindow) bytes"
        )
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
        pipeAckSamples = PipeAckSamples(repeating: 0)
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

    mutating func revalidateCongestionWindow(smoothedRTT: NetworkDuration, now: NetworkClock.Instant) -> Bool {
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
        return congestionWindowValidated
    }

    func canSend(packetLength: Int) -> Bool {
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

    func logUpdate(qlog: QLog?) {
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
