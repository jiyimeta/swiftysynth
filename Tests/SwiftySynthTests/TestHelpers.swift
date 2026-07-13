import Testing

/// Relative-error float comparison used across the hermetic unit tests.
func expectClose(
    _ actual: Float,
    _ expected: Float,
    rel: Float = 1e-6,
    _ comment: @autoclosure () -> Testing.Comment = "",
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    let scale = max(abs(actual), abs(expected), 1e-30)
    #expect(
        abs(actual - expected) <= rel * scale,
        "\(comment()) expected \(expected), got \(actual)",
        sourceLocation: sourceLocation
    )
}
