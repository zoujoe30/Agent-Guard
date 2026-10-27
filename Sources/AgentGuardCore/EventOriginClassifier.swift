import Foundation

public enum EventOriginClassifier {
    /// Quartz hardware events normally have no originating userspace process.
    /// Software-generated events retain the PID of the posting process.
    public static func isPhysical(sourcePID: Int64) -> Bool {
        sourcePID <= 0
    }
}
