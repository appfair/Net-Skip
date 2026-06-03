// SPDX-License-Identifier: GPL-2.0-or-later
func trying<T>(operation: () throws -> T) -> T? {
    do {
        return try operation()
    } catch {
        logger.error("error performing operation: \(error)")
        return nil
    }
}

var isSkip: Bool {
    #if SKIP
    true
    #else
    false
    #endif
}
