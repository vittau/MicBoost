import Testing

@testable import MicBoostCore

@Test func monitorBufferLeaseRestoresEvenAfterPartialRejection() throws {
    for reject in [false, true] {
        var value: UInt32 = 512
        var writes: [UInt32] = []
        let lease = MonitorBufferLease(
            policy: .request(128), read: { value },
            write: { frames in
                value = frames
                writes.append(frames)
                if reject && frames == 128 { throw EngineError.halFailure(-777, "Request test buffer") }
            })
        #expect(value == 128)
        #expect(lease.result == (reject ? "rejected (-777)" : "128"))
        try lease.restore()
        try lease.restore()
        #expect(value == 512 && writes == [128, 512])
    }
}

@Test func sharedBufferLeaseNeverWritesAndRejectedUnchangedNeedsNoRestoreWrite() throws {
    var writes = 0
    let shared = MonitorBufferLease(policy: .sharedWithSource, read: { 512 }, write: { _ in writes += 1 })
    try shared.restore()
    #expect(writes == 0 && shared.result == "none (shared with source)")
    let rejected = MonitorBufferLease(
        policy: .request(128), read: { 512 },
        write: { _ in
            writes += 1
            throw EngineError.halFailure(-777, "Reject buffer")
        })
    try rejected.restore()
    #expect(writes == 1 && rejected.result == "rejected (-777)")
}

@Test func failedBufferRestoreRetainsLeaseForRetry() throws {
    var value: UInt32 = 512
    var failing = true
    let lease = MonitorBufferLease(
        policy: .request(128), read: { value },
        write: { frames in
            if frames == 512 && failing { throw EngineError.halFailure(-888, "Restore buffer") }
            value = frames
        })
    do {
        try lease.restore()
        Issue.record("Restore succeeded unexpectedly")
    } catch {}
    #expect(value == 128)
    failing = false
    try lease.restore()
    #expect(value == 512)
}

@Test func bufferRestoreRejectsIgnoredWriteAndRetries() throws {
    var value: UInt32 = 512
    var ignore = true
    let lease = MonitorBufferLease(
        policy: .request(128), read: { value },
        write: { frames in
            if frames != 512 || !ignore { value = frames }
        })
    do {
        try lease.restore()
        Issue.record("Ignored restore accepted")
    } catch {}
    #expect(value == 128)
    ignore = false
    try lease.restore()
    #expect(value == 512)
}
