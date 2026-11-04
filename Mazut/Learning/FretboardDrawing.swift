//
//  FretboardDrawing.swift
//  Mazut
//
//  Drawing shared by the Canvas fretboards (Scales, Find the Note).
//

import SwiftUI

enum FretboardDrawing {
    /// Frets with a single inlay dot; the 12th gets a double one.
    static let singleInlays = [3, 5, 7, 9, 15]

    /// Inlay dots for the frets in `frets`: single ones on `centerY`, the 12th
    /// fret's pair `rowGap` above and below it.
    static func drawInlays(in context: GraphicsContext, frets: ClosedRange<Int>,
                           x: (Int) -> CGFloat, centerY: CGFloat, rowGap: CGFloat,
                           diameter: CGFloat) {
        func dot(_ cx: CGFloat, _ cy: CGFloat) {
            let rect = CGRect(x: cx - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(0.15)))
        }
        for fret in singleInlays where frets.contains(fret) {
            dot(x(fret), centerY)
        }
        if frets.contains(12) {
            dot(x(12), centerY - rowGap)
            dot(x(12), centerY + rowGap)
        }
    }
}
