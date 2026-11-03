import Testing

/// Suites that set the process-wide layout holds (`holdGrids`, `holdFrames`), which hold every
/// surface's resizes: one test at a time, so none sees another's hold.
@Suite(.serialized) enum LayoutHoldTests {}
