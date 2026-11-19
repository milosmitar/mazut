//
//  SongTimelineView.swift
//  Mazut
//
//  Player timeline: time ruler with the A–B loop region on top, the song's
//  waveform below, and the playhead. Red accent + grays (app palette).
//
//  Gestures
//  - The loop shows only as a tint + edge lines over the waveform (no bar in
//    the ruler). After "Set A" and before "Set B" the tint grows from A to the
//    playhead.
//  - Ruler (still the handle for the loop, at the red edge lines): drag on
//    empty space → new loop region (applied, and switched on, on release);
//    drag near an edge → move A / B; drag inside → move the whole loop; tap
//    inside → loop on/off. While dragging, the view draws a local draft and
//    commits once on release (one transport restart).
//  - Waveform: tap → seek. Drag → scrub at 1× (whole song visible); when
//    zoomed, drag pans, and grabbing the playhead itself scrubs.
//  - Pinch anywhere → zoom (anchored under the fingers), from the whole song
//    down to `minSpan` seconds. When zoomed, the view follows the playhead
//    while playing, unless the user panned away (resumes once the playhead
//    comes back into view or after a tap-seek).
//

import SwiftUI

struct SongTimelineView: View {
    let engine: StemMixerEngine
    /// Loudness levels from `Waveform` (nil while being built → flat line).
    let levels: [UInt8]?

    private let rulerHeight: CGFloat = 24
    private let waveHeight: CGFloat = 72
    /// Shortest visible span at maximum zoom (seconds).
    private let minSpan: TimeInterval = 4
    /// Touch slop for grabbing a region edge or the playhead (points).
    private let grabRadius: CGFloat = 16

    // Viewport: [visibleStart, visibleStart + span]; span == nil → whole song.
    @State private var visibleStart: TimeInterval = 0
    @State private var span: TimeInterval?
    @State private var follow = true

    @State private var pinchStart: (span: TimeInterval, start: TimeInterval)?
    @State private var waveDrag: WaveDrag?
    @State private var rulerDrag: RulerDrag?
    /// Start points of the drags in progress, and of the ones a pinch swallowed:
    /// a finger left down after a pinch must not turn into a scrub / seek / loop
    /// edit. Matched by start location (a new touch never starts at the exact
    /// same point), which also survives drags SwiftUI cancels without onEnded.
    @State private var waveDragStart: CGPoint?
    @State private var rulerDragStart: CGPoint?
    @State private var swallowedWaveStart: CGPoint?
    @State private var swallowedRulerStart: CGPoint?
    /// Region drawn while a ruler drag is in progress.
    @State private var draft: (start: TimeInterval, end: TimeInterval)?

    private enum WaveDrag { case pending, scrub, pan(startVisible: TimeInterval) }
    private enum RulerDrag {
        case pendingCreate, create
        case pendingMove(a: TimeInterval, b: TimeInterval), move(a: TimeInterval, b: TimeInterval)
        case resizeStart(b: TimeInterval), resizeEnd(a: TimeInterval)
    }

    private var duration: TimeInterval { max(engine.duration, 0.01) }
    private var visibleSpan: TimeInterval { min(span ?? duration, duration) }
    private var isZoomed: Bool { visibleSpan < duration - 0.01 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 0) {
                ruler(width: width)
                    .frame(height: rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(rulerGesture(width: width))
                waveform(width: width)
                    .frame(height: waveHeight)
                    .contentShape(Rectangle())
                    .gesture(waveGesture(width: width))
                    .accessibilityElement()
                    .accessibilityLabel("Song position")
                    .accessibilityValue(timeText(engine.currentTime))
                    .accessibilityAdjustableAction { dir in
                        let step: TimeInterval = dir == .increment ? 5 : -5
                        engine.seek(to: engine.currentTime + step)
                    }
            }
            .overlay(alignment: .topTrailing) { zoomResetButton }
            .simultaneousGesture(pinchGesture(width: width))
            .onChange(of: engine.currentTime) { _, t in followPlayhead(t) }
            .onChange(of: engine.duration) { _, _ in span = nil; visibleStart = 0 }
        }
        .frame(height: rulerHeight + waveHeight)
        .clipped()
    }

    // MARK: - Coordinates

    private func x(for t: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((t - visibleStart) / visibleSpan) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        let t = visibleStart + TimeInterval(x / max(width, 1)) * visibleSpan
        return min(max(0, t), engine.duration)
    }

    private func clampStart(_ s: TimeInterval) -> TimeInterval {
        min(max(0, s), max(0, duration - visibleSpan))
    }

    /// The loop region to draw: the draft while dragging, the engine's loop, or —
    /// after "Set A" and before "Set B" — a pending region growing from A to the
    /// playhead (shown once the playhead is past A).
    private var region: (start: TimeInterval, end: TimeInterval)? {
        if let draft { return draft }
        guard let a = engine.loopStart else { return nil }
        if let b = engine.loopEnd { return (a, b) }
        return engine.currentTime > a ? (a, engine.currentTime) : (a, a)
    }

    /// A is set, B not yet: the region follows the playhead.
    private var regionPending: Bool { draft == nil && engine.loopStart != nil && engine.loopEnd == nil }

    /// Region looks "on" (red): a running loop, a draft (releasing enables it),
    /// or a pending A→playhead region.
    private var regionActive: Bool { draft != nil || engine.isLoopEnabled || regionPending }

    // MARK: - Drawing

    private func ruler(width: CGFloat) -> some View {
        Canvas { ctx, size in
            // Ticks + time labels, spaced ≥ 56 pt apart.
            let pxPerSec = width / CGFloat(visibleSpan)
            let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { CGFloat($0) * pxPerSec >= 56 } ?? 600
            var t = (visibleStart / step).rounded(.down) * step
            while t <= visibleStart + visibleSpan {
                let px = x(for: t, width: width)
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: size.height - 7))
                tick.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                ctx.draw(Text(timeText(t)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: px + 3, y: size.height - 2), anchor: .bottomLeading)
                t += step
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        }
    }

    private func waveform(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let now = engine.currentTime
            let r = region
            let active = regionActive

            // Background + loop tint.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.gray.opacity(0.08)))
            if let r {
                let x0 = x(for: r.start, width: width), x1 = x(for: r.end, width: width)
                let tint: Color = active ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.14)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(tint))
                for bx in [x0, x1] {
                    var line = Path()
                    line.move(to: CGPoint(x: bx, y: 0))
                    line.addLine(to: CGPoint(x: bx, y: size.height))
                    ctx.stroke(line, with: .color(active ? .accentColor : .gray), lineWidth: 1)
                }
            }

            // Bars, one per 2 pt column: loudest bucket in the column.
            if let levels, !levels.isEmpty {
                let count = levels.count
                let colW: CGFloat = 2
                var col: CGFloat = 0
                while col < size.width {
                    let t0 = time(at: col, width: width)
                    let t1 = time(at: col + colW, width: width)
                    let i0 = min(count - 1, Int(t0 / duration * Double(count)))
                    let i1 = min(count, max(i0 + 1, Int(t1 / duration * Double(count))))
                    var v: UInt8 = 0
                    for i in i0..<i1 where levels[i] > v { v = levels[i] }
                    let h = max(1, CGFloat(v) / 255 * (size.height - 6))
                    let inLoop = r.map { t0 >= $0.start && t0 < $0.end } ?? false
                    let played = t0 < now
                    let color: Color
                    if inLoop && active {
                        color = played ? Color(red: 0.95, green: 0.35, blue: 0.3) : Color.accentColor
                    } else if r != nil && active {
                        color = Color.gray.opacity(played ? 0.45 : 0.28)   // outside a running loop: dimmed
                    } else {
                        color = played ? Color.primary.opacity(0.75) : Color.gray.opacity(0.5)
                    }
                    ctx.fill(Path(CGRect(x: col, y: mid - h / 2, width: colW - 0.6, height: h)),
                             with: .color(color))
                    col += colW
                }
            } else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid))
                line.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(line, with: .color(.gray.opacity(0.5)), lineWidth: 1)
            }

            // Playhead with a grab knob on top.
            let px = x(for: now, width: width)
            var head = Path()
            head.move(to: CGPoint(x: px, y: 0))
            head.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(head, with: .color(.primary), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: px - 5, y: -1, width: 10, height: 10)),
                     with: .color(.accentColor))
        }
    }

    @ViewBuilder private var zoomResetButton: some View {
        if isZoomed {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { span = nil; visibleStart = 0 }
                follow = true
            } label: {
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, rulerHeight + 4)
            .padding(.trailing, 4)
            .accessibilityLabel("Show whole song")
        }
    }

    // MARK: - Gestures

    private func waveGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                waveDragStart = v.startLocation
                guard pinchStart == nil, v.startLocation != swallowedWaveStart else { return }
                if waveDrag == nil {
                    let onPlayhead = abs(v.startLocation.x - x(for: engine.currentTime, width: width)) < grabRadius
                    waveDrag = onPlayhead ? .scrub : .pending
                }
                if case .pending = waveDrag, abs(v.translation.width) > 4 {
                    waveDrag = isZoomed ? .pan(startVisible: visibleStart) : .scrub
                }
                switch waveDrag {
                case .scrub:
                    engine.seek(to: time(at: v.location.x, width: width), exitsLoop: false)
                case .pan(let startVisible):
                    follow = false
                    visibleStart = clampStart(startVisible - TimeInterval(v.translation.width / width) * visibleSpan)
                default: break
                }
            }
            .onEnded { v in
                defer { waveDrag = nil; waveDragStart = nil }
                if v.startLocation == swallowedWaveStart { swallowedWaveStart = nil; return }
                guard pinchStart == nil else { return }
                switch waveDrag {
                case .pending:
                    engine.seek(to: time(at: v.location.x, width: width))   // tap
                    follow = true
                case .scrub:
                    engine.endScrub(at: time(at: v.location.x, width: width))
                    follow = true
                default: break
                }
            }
    }

    private func rulerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                rulerDragStart = v.startLocation
                guard pinchStart == nil, v.startLocation != swallowedRulerStart else { return }
                let t = time(at: v.location.x, width: width)
                if rulerDrag == nil { rulerDrag = beginRulerDrag(at: v.startLocation.x, width: width) }
                let moved = abs(v.translation.width) > 4
                let minLen = StemMixerEngine.minLoopLength

                switch rulerDrag {
                case .pendingCreate where moved:
                    rulerDrag = .create
                    fallthrough
                case .create:
                    let anchor = time(at: v.startLocation.x, width: width)
                    draft = (min(anchor, t), max(anchor, t))
                case .pendingMove(let a, let b) where moved:
                    rulerDrag = .move(a: a, b: b)
                    fallthrough
                case .move:
                    guard case .move(let a, let b) = rulerDrag else { break }
                    let dt = TimeInterval(v.translation.width / width) * visibleSpan
                    let shift = min(max(dt, -a), engine.duration - b)
                    draft = (a + shift, b + shift)
                case .resizeStart(let b):
                    draft = (max(0, min(t, b - minLen)), b)
                case .resizeEnd(let a):
                    draft = (a, min(engine.duration, max(t, a + minLen)))
                default: break
                }
            }
            .onEnded { v in
                defer { rulerDrag = nil; draft = nil; rulerDragStart = nil }
                if v.startLocation == swallowedRulerStart { swallowedRulerStart = nil; return }
                guard pinchStart == nil else { return }
                switch rulerDrag {
                case .pendingMove:
                    engine.setLoopEnabled(!engine.isLoopEnabled)     // tap on region
                case .create:
                    if let d = draft { engine.setLoopRegion(start: d.start, end: d.end, enabled: true) }
                case .move, .resizeStart, .resizeEnd:
                    if let d = draft {
                        engine.setLoopRegion(start: d.start, end: d.end, enabled: engine.isLoopEnabled)
                    }
                default: break   // tap on empty ruler: nothing
                }
            }
    }

    /// What a ruler drag starting at `x` does: grab an edge, the middle, or create.
    private func beginRulerDrag(at x0: CGFloat, width: CGFloat) -> RulerDrag {
        guard let a = engine.loopStart, let b = engine.loopEnd else { return .pendingCreate }
        let xa = x(for: a, width: width), xb = x(for: b, width: width)
        let da = abs(x0 - xa), db = abs(x0 - xb)
        // Narrow region: the nearer edge wins; wide: middle grabs the whole loop.
        if min(da, db) < grabRadius && (xb - xa < grabRadius * 3 || x0 < xa + grabRadius || x0 > xb - grabRadius) {
            return da <= db ? .resizeStart(b: b) : .resizeEnd(a: a)
        }
        if x0 > xa && x0 < xb { return .pendingMove(a: a, b: b) }
        return .pendingCreate
    }

    private func pinchGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil {
                    pinchStart = (visibleSpan, visibleStart)
                    waveDrag = nil
                    rulerDrag = nil
                    // Fingers already down belong to the pinch from now on.
                    swallowedWaveStart = waveDragStart
                    swallowedRulerStart = rulerDragStart
                    draft = nil
                }
                guard let s = pinchStart else { return }
                let anchorFrac = TimeInterval(min(max(v.startLocation.x / max(width, 1), 0), 1))
                let anchorTime = s.start + anchorFrac * s.span
                let newSpan = min(max(s.span / TimeInterval(v.magnification), min(minSpan, duration)), duration)
                span = newSpan >= duration - 0.01 ? nil : newSpan
                visibleStart = clampStart(anchorTime - anchorFrac * newSpan)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Keep the playhead in view while zoomed (page when it nears the right edge).
    private func followPlayhead(_ t: TimeInterval) {
        guard isZoomed, waveDrag == nil, pinchStart == nil else { return }
        let end = visibleStart + visibleSpan
        if !follow {
            // User panned away; resume once the playhead is back in view.
            if t >= visibleStart && t <= end { follow = true }
            return
        }
        if t < visibleStart || t > visibleStart + visibleSpan * 0.85 {
            visibleStart = clampStart(t - visibleSpan * 0.15)
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
