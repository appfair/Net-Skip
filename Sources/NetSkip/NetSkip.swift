// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

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
