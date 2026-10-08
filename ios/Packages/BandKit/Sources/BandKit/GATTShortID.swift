/// Maps a CoreBluetooth UUID string to the short characteristic id used in fixtures and the frame log.
///
/// - Bluetooth base UUIDs (`0000XXXX-0000-1000-8000-00805F9B34FB`) become `xxxx`, e.g. `2a37`.
/// - The WHOOP custom base (`XXXXXXXX-8D6D-82B8-614A-1C8CB0F8DCC6`) becomes its first eight hex digits.
/// - Anything else is returned lowercased.
public enum GATTShortID {
    private static let bluetoothBaseSuffix = "-0000-1000-8000-00805F9B34FB"
    private static let customBaseSuffix = "-8D6D-82B8-614A-1C8CB0F8DCC6"

    public static func make(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36 {
            if upper.hasSuffix(bluetoothBaseSuffix) {
                return String(upper.prefix(8).suffix(4)).lowercased()
            }
            if upper.hasSuffix(customBaseSuffix) {
                return String(upper.prefix(8)).lowercased()
            }
        }
        return upper.lowercased()
    }
}
