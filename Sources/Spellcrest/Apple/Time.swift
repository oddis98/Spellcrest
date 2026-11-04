#if canImport(QuartzCore)
import QuartzCore

/// The time in seconds, as the display links count it: the loop's clock.
func currentTime() -> Double { CACurrentMediaTime() }
#endif
