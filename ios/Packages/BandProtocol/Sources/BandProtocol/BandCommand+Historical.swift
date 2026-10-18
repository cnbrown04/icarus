/// History-offload commands (PLAN.md 5.3.4). Kept in their own file so the shared `BandCommand.swift`
/// is not touched while another workstream edits it; the builders only use the internal initializer.
extension BandCommand {
    /// SEND_HISTORICAL_DATA (cmd 22). Starts the offload of the strap's on-device history.
    /// Carries the standard `[0x00]` command byte (NOOP, verified on 4.0).
    public static func sendHistoricalData() -> BandCommand {
        BandCommand(.sendHistoricalData, payload: [0x00])
    }

    /// HISTORICAL_DATA_RESULT (cmd 23). Acknowledges one offloaded batch by echoing the 8-byte
    /// end-data of the METADATA (type 49) HISTORY_END frame that closed it (see `HistoricalMetadata`).
    /// The strap replays the batch until it receives this confirmed write; without it the same early
    /// batch is re-served forever and the strap's history never drains past it.
    /// Payload: `[0x01] + endData` — the leading 0x01 is hardware-verified (NOOP `BLEManager
    /// .ackHistoricalChunk` / `build_history_ack_whoop4` on WHOOP 4 fw 41.17.6.0); a bare-token echo
    /// is rejected and the strap replays the batch.
    public static func historicalDataResult(token: [UInt8]) -> BandCommand {
        BandCommand(.historicalDataResult, payload: [0x01] + token)
    }
}
