import XCTest
import _Differentiation

@differentiable(reverse)
private func quadratic(_ x: Double) -> Double {
    x * x + 3 * x + 2
}

@differentiable(reverse)
private func weightedPolynomial(_ x: Double, _ y: Double) -> Double {
    x * x + x * y + y
}

private struct Scalar: Differentiable, AdditiveArithmetic {
    var value: Double

    static let zero = Scalar(value: 0)

    static func + (lhs: Scalar, rhs: Scalar) -> Scalar {
        Scalar(value: lhs.value + rhs.value)
    }

    static func - (lhs: Scalar, rhs: Scalar) -> Scalar {
        Scalar(value: lhs.value - rhs.value)
    }

    mutating func move(by offset: Scalar) {
        value += offset.value
    }
}

@differentiable(reverse)
private func unwrap(_ scalar: Scalar) -> Double {
    scalar.value
}

final class DifferentiationTests: XCTestCase {
    func testComputesValueWithGradient() {
        let result = valueWithGradient(at: 4.0, of: quadratic)

        XCTAssertEqual(result.value, 30.0, accuracy: 1e-12)
        XCTAssertEqual(result.gradient, 11.0, accuracy: 1e-12)
    }

    func testComputesMultiArgumentGradient() {
        let result = valueWithGradient(at: 3.0, 5.0, of: weightedPolynomial)

        XCTAssertEqual(result.value, 29.0, accuracy: 1e-12)
        XCTAssertEqual(result.gradient.0, 11.0, accuracy: 1e-12)
        XCTAssertEqual(result.gradient.1, 4.0, accuracy: 1e-12)
    }

    func testCustomDifferentiableTypeCanBeUsedAcrossModuleBoundary() {
        let gradient = gradient(at: Scalar(value: 7), of: unwrap)

        XCTAssertEqual(gradient.value, 1.0, accuracy: 1e-12)
    }
}
