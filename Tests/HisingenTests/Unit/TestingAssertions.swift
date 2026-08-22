import Testing


private struct UnwrapFailure: Error {}

private func recordFailure(_ message: String, at sourceLocation: SourceLocation) {
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

func XCTAssertEqual<T: Equatable>(
    _ left: @autoclosure () throws -> T,
    _ right: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let leftValue = try left()
    let rightValue = try right()
    guard leftValue != rightValue else { return }
    let detail = message()
    recordFailure(detail.isEmpty ? "Expected \(leftValue) to equal \(rightValue)" : detail,
                  at: sourceLocation)
}

func XCTAssertEqual<T: FloatingPoint>(
    _ left: @autoclosure () throws -> T,
    _ right: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let leftValue = try left()
    let rightValue = try right()
    guard abs(leftValue - rightValue) <= accuracy else {
        let detail = message()
        recordFailure(detail.isEmpty ? "Expected \(leftValue) to equal \(rightValue) within \(accuracy)" : detail,
                      at: sourceLocation)
        return
    }
}

func XCTAssertNotEqual<T: Equatable>(
    _ left: @autoclosure () throws -> T,
    _ right: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let leftValue = try left()
    let rightValue = try right()
    guard leftValue == rightValue else { return }
    let detail = message()
    recordFailure(detail.isEmpty ? "Expected \(leftValue) to not equal \(rightValue)" : detail,
                  at: sourceLocation)
}

func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    guard try expression() else {
        let detail = message()
        recordFailure(detail.isEmpty ? "Expected condition to be true" : detail, at: sourceLocation)
        return
    }
}

func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    guard try !expression() else {
        let detail = message()
        recordFailure(detail.isEmpty ? "Expected condition to be false" : detail, at: sourceLocation)
        return
    }
}

func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    guard try expression() != nil else { return }
    let detail = message()
    recordFailure(detail.isEmpty ? "Expected value to be nil" : detail, at: sourceLocation)
}

func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    guard try expression() == nil else { return }
    let detail = message()
    recordFailure(detail.isEmpty ? "Expected a non-nil value" : detail, at: sourceLocation)
}

func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    if let value = try expression() { return value }
    let detail = message()
    recordFailure(detail.isEmpty ? "Expected a non-nil value" : detail, at: sourceLocation)
    throw UnwrapFailure()
}

func XCTAssertLessThanOrEqual<T: Comparable>(
    _ left: @autoclosure () throws -> T,
    _ right: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) rethrows {
    let leftValue = try left()
    let rightValue = try right()
    guard leftValue <= rightValue else {
        let detail = message()
        recordFailure(detail.isEmpty ? "Expected \(leftValue) to be less than or equal to \(rightValue)" : detail,
                      at: sourceLocation)
        return
    }
}

func XCTFail(
    _ message: @autoclosure () -> String = "Test failed",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    recordFailure(message(), at: sourceLocation)
}


