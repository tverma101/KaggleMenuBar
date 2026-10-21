import CoreGraphics

/// Small hardware pictograms for the status circles, drawn on a 10-unit grid
/// and filled even-odd so the holes show the disc's backing through them:
/// a chip with pins for CPU, a card with a fan for GPU, and four tiles, a
/// matrix unit, for TPU. Shapes stay at least a unit wide, which is 2 pixels
/// on a Retina menu bar.
enum AcceleratorGlyph {
    /// `size` is the side of the grid in points, centered on `center`, y-up.
    static func path(for accelerator: Accelerator, center: CGPoint, size: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x - size / 2, y: center.y - size / 2)
            .scaledBy(x: size / 10, y: size / 10)
        return unitPath(for: accelerator).copy(using: &transform) ?? unitPath(for: accelerator)
    }

    private static func unitPath(for accelerator: Accelerator) -> CGPath {
        let path = CGMutablePath()
        switch accelerator {
        case .cpu:
            addChip(to: path)
            path.addRect(CGRect(x: 3.7, y: 3.7, width: 2.6, height: 2.6))
        case .tpu:
            for x in [1.0, 5.4] {
                for y in [1.0, 5.4] {
                    path.addRoundedRect(in: CGRect(x: x, y: y, width: 3.6, height: 3.6), cornerWidth: 0.7, cornerHeight: 0.7)
                }
            }
        case .gpu:
            path.addRoundedRect(in: CGRect(x: 0.4, y: 3.0, width: 9.2, height: 5.6), cornerWidth: 1, cornerHeight: 1)
            path.addEllipse(in: CGRect(x: 4.2, y: 3.8, width: 4.0, height: 4.0))
            path.addEllipse(in: CGRect(x: 5.55, y: 5.15, width: 1.3, height: 1.3))
            // The card's edge connector.
            path.addRect(CGRect(x: 1.4, y: 1.4, width: 3.6, height: 1.6))
        }
        return path
    }

    /// A square body with two pins on each side.
    private static func addChip(to path: CGMutablePath) {
        path.addRoundedRect(in: CGRect(x: 2, y: 2, width: 6, height: 6), cornerWidth: 1, cornerHeight: 1)
        for offset in [3.0, 5.9] {
            path.addRect(CGRect(x: offset, y: 0.5, width: 1.1, height: 1.5))
            path.addRect(CGRect(x: offset, y: 8, width: 1.1, height: 1.5))
            path.addRect(CGRect(x: 0.5, y: offset, width: 1.5, height: 1.1))
            path.addRect(CGRect(x: 8, y: offset, width: 1.5, height: 1.1))
        }
    }
}
