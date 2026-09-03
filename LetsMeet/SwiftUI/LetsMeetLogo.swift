//
//  LetsMeetLogo.swift
//  LetsMeet
//

import SwiftUI

/// Fixed design-space geometry for the "M" route logo (Concept 9 - Tall Gradient Route).
/// Every shape below scales this design space to whatever frame it's actually given.
enum LogoGeometry {
    // Proportions traced directly from the approved reference: leg-to-leg span (340) vs.
    // vertical run from top corner to pin tip (435) - a 0.78 width:height ratio - with the
    // valley sitting 38% of the way down that vertical run.
    static let designSize = CGSize(width: 430, height: 490)

    static let legX: CGFloat = 45          // left leg x; right leg mirrors at (width - legX)
    static let topCornerY: CGFloat = 40
    static let valleyY: CGFloat = 205
    static let legPinTipY: CGFloat = 475    // where the outer pins' tips land

    static let routePinDiameter: CGFloat = 86  // outer (blue/orange) pin head diameter - large, distinct anchors
    static let centerPinDiameter: CGFloat = 62 // red midpoint pin head diameter - slightly smaller than the endpoints
    static let pinHeightRatio: CGFloat = 1.3   // total pin height (head + tip) as a multiple of head diameter

    static let routeStrokeWidthFraction: CGFloat = 0.065 // of designSize.width - moderate weight, not a thin line or a thick bar

    /// How far above the valley vertex the red pin's tip sits, so it points at the vertex
    /// without covering it - the dark meeting point must stay visible beneath/around it.
    static let centerPinGapFraction: CGFloat = 0.05

    // Gradient endpoints for the connectors, as UnitPoints relative to the FULL canvas.
    // A connector Shape has no frame of its own, so it's laid out at the full canvas size -
    // generic presets like .topLeading/.bottomTrailing would map to the canvas's corners,
    // not the connector line's own endpoints, leaving the gradient's dark stop far past the
    // valley and the visible line only ever reaching a partial blend. These are computed
    // from the connector's actual endpoints instead, so the gradient fully resolves to the
    // dark blend color exactly at the valley.
    static var valleyUnitPoint: UnitPoint {
        UnitPoint(x: 0.5, y: valleyY / designSize.height)
    }
    static var leftTopUnitPoint: UnitPoint {
        UnitPoint(x: legX / designSize.width, y: topCornerY / designSize.height)
    }
    static var rightTopUnitPoint: UnitPoint {
        UnitPoint(x: (designSize.width - legX) / designSize.width, y: topCornerY / designSize.height)
    }

    /// A route line into an OUTER (blue/orange) pin must stop at that pin's head-circle
    /// center for the head - drawn on top - to fully cover it, since that's the widest
    /// point of the pin's silhouette. Derived from pinHeightRatio: with the tip at the
    /// frame's bottom and the head circle at the top, the head's center sits
    /// (pinHeightRatio - 0.5) head-diameters above the tip. The red pin does NOT use this -
    /// the connectors run the full distance to the valley so the dark meeting point renders
    /// visibly, and the red pin sits just above it rather than covering it.
    static var pinCoverageFraction: CGFloat { pinHeightRatio - 0.5 }
}

/// The vertical portion of one leg of the "M": from the top corner down into the outer pin's
/// head circle. It stops at the head's center - the widest point of the pin - so the pin's
/// opaque head, drawn on top, fully covers it and only the pin's own tip shows below.
struct LogoStemShape: Shape {
    var isLeft: Bool

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / LogoGeometry.designSize.width
        let sy = rect.height / LogoGeometry.designSize.height
        let x = (isLeft ? LogoGeometry.legX : LogoGeometry.designSize.width - LogoGeometry.legX) * sx + rect.minX
        let topY = LogoGeometry.topCornerY * sy + rect.minY
        let bottomY = (LogoGeometry.legPinTipY - LogoGeometry.routePinDiameter * LogoGeometry.pinCoverageFraction) * sy + rect.minY

        var path = Path()
        path.move(to: CGPoint(x: x, y: bottomY))
        path.addLine(to: CGPoint(x: x, y: topY))
        return path
    }
}

/// The diagonal portion of one leg of the "M": from the top corner down to the exact
/// valley vertex where the blue and orange routes meet. Unlike the stems, this runs the
/// FULL distance - the vertex must render visibly (it's the dark meeting point the red
/// pin points at), not be hidden under the red pin.
struct LogoConnectorShape: Shape {
    var isLeft: Bool

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / LogoGeometry.designSize.width
        let sy = rect.height / LogoGeometry.designSize.height
        let x = (isLeft ? LogoGeometry.legX : LogoGeometry.designSize.width - LogoGeometry.legX) * sx + rect.minX
        let top = CGPoint(x: x, y: LogoGeometry.topCornerY * sy + rect.minY)
        let valley = CGPoint(
            x: LogoGeometry.designSize.width / 2 * sx + rect.minX,
            y: LogoGeometry.valleyY * sy + rect.minY
        )

        var path = Path()
        path.move(to: top)
        path.addLine(to: valley)
        return path
    }
}

/// The tapering tip of a map pin: starts at the two points where it's exactly tangent to
/// the head circle (so it meets the head with no seam, by construction) and narrows to a
/// point at the bottom of `rect`. Kept as its own shape, separate from the head circle, so
/// each fills independently with no cross-path winding interaction between the two -
/// that interaction is what caused a visible gap in an earlier version of this shape.
struct PinTipShape: Shape {
    var headRadius: CGFloat
    var tangentAngleDegrees: Double = 32

    func path(in rect: CGRect) -> Path {
        let theta = Angle(degrees: tangentAngleDegrees).radians
        let headCenter = CGPoint(x: rect.midX, y: rect.minY + headRadius)
        let dx = headRadius * CGFloat(sin(theta))
        let dy = headRadius * CGFloat(cos(theta))
        let left = CGPoint(x: headCenter.x - dx, y: headCenter.y + dy)
        let right = CGPoint(x: headCenter.x + dx, y: headCenter.y + dy)
        let tip = CGPoint(x: rect.midX, y: rect.maxY)

        var path = Path()
        path.move(to: left)
        path.addQuadCurve(to: tip, control: CGPoint(x: left.x, y: tip.y))
        path.addQuadCurve(to: right, control: CGPoint(x: right.x, y: tip.y))
        path.closeSubpath()
        return path
    }
}

/// A single map-pin marker: a circular head plus a tapering tip (two separate same-colored
/// shapes, precisely positioned to overlap with no seam) and a small white hole in the
/// head, matching the reference's endpoint and midpoint pins. Built from known, exact
/// geometry - rather than an SF Symbol of unknown internal proportions - so route lines
/// can be positioned relative to the head's precise center and radius.
struct RoutePinGlyph: View {
    var color: Color
    /// A lighter tint of `color`, used for a subtle top-left highlight on the pin's fill
    /// so it reads as slightly dimensional rather than a flat cutout.
    var highlightColor: Color
    var headDiameter: CGFloat
    /// Outer (blue/orange) pins float above the background with a soft shadow; the red
    /// midpoint pin is visually attached to the route instead, so it gets much less.
    var isElevated: Bool = true

    private var fillGradient: LinearGradient {
        LinearGradient(colors: [highlightColor, color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        let totalHeight = headDiameter * LogoGeometry.pinHeightRatio

        ZStack {
            // No explicit frame: takes the full pin bounds from the ZStack below, so its
            // tangent-point math lines up with the head circle's actual position in that
            // same coordinate space.
            PinTipShape(headRadius: headDiameter / 2)
                .fill(fillGradient)

            Circle()
                .fill(fillGradient)
                .frame(width: headDiameter, height: headDiameter)
                .offset(y: (headDiameter - totalHeight) / 2)

            Circle()
                .fill(Color.white)
                .frame(width: headDiameter * 0.52, height: headDiameter * 0.52)
                .offset(y: headDiameter * 0.45 - totalHeight / 2)
        }
        .frame(width: headDiameter, height: totalHeight)
        .shadow(
            color: .black.opacity(isElevated ? 0.22 : 0.1),
            radius: headDiameter * (isElevated ? 0.14 : 0.05),
            y: headDiameter * (isElevated ? 0.12 : 0.03)
        )
    }
}

/// Holds the animatable state for each independent piece of the logo - the blue route,
/// the orange route, the two outer pins, and the red midpoint pin - as a shared object so
/// a parent view (e.g. a launch intro sequence) can orchestrate them in any order/timing
/// it needs, rather than the logo only being able to play one fixed built-in sequence.
final class LogoAnimator: ObservableObject {
    @Published var stemProgress: CGFloat
    @Published var connectorProgress: CGFloat
    @Published var outerPinsVisible: Bool
    @Published var redPinVisible: Bool

    /// `startAtRest: true` shows the finished logo immediately, with no animation -
    /// used when the logo is displayed on its own rather than as part of an intro sequence.
    init(startAtRest: Bool = true) {
        stemProgress = startAtRest ? 1 : 0
        connectorProgress = startAtRest ? 1 : 0
        outerPinsVisible = startAtRest
        redPinVisible = startAtRest
    }
}

/// The full "M" route logo: two tall route legs (blue left, orange right) meeting in a
/// center valley marked by a red pin, with matching blue/orange pins at each leg's base.
/// Built from independent, individually-animatable pieces (stems, connectors, pins) driven
/// by an externally-owned LogoAnimator.
struct LetsMeetLogoView: View {
    static let lightBlue = Color(red: 0.18, green: 0.61, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.48, blue: 0.0)
    static let meetingRed = Color(red: 1.0, green: 0.30, blue: 0.30)
    private static let lightBlueHighlight = Color(red: 0.58, green: 0.79, blue: 1.0)
    private static let orangeHighlight = Color(red: 1.0, green: 0.70, blue: 0.42)
    private static let meetingRedHighlight = Color(red: 1.0, green: 0.62, blue: 0.62)
    /// Very dark navy/near-black - what the blue and orange routes each fade into as they
    /// approach the valley, so the center reads as a dark meeting point, not a blue-orange blend.
    private static let blendColor = Color(red: 0.06, green: 0.07, blue: 0.12)

    @ObservedObject var animator: LogoAnimator

    var body: some View {
        ZStack {
            LogoStemShape(isLeft: true)
                .trim(from: 0, to: animator.stemProgress)
                .stroke(Self.lightBlue, style: routeStrokeStyle)

            LogoStemShape(isLeft: false)
                .trim(from: 0, to: animator.stemProgress)
                .stroke(Self.orange, style: routeStrokeStyle)

            LogoConnectorShape(isLeft: true)
                .trim(from: 0, to: animator.connectorProgress)
                .stroke(
                    LinearGradient(colors: [Self.lightBlue, Self.blendColor], startPoint: LogoGeometry.leftTopUnitPoint, endPoint: LogoGeometry.valleyUnitPoint),
                    style: routeStrokeStyle
                )

            LogoConnectorShape(isLeft: false)
                .trim(from: 0, to: animator.connectorProgress)
                .stroke(
                    LinearGradient(colors: [Self.orange, Self.blendColor], startPoint: LogoGeometry.rightTopUnitPoint, endPoint: LogoGeometry.valleyUnitPoint),
                    style: routeStrokeStyle
                )

            GeometryReader { proxy in
                let sx = proxy.size.width / LogoGeometry.designSize.width
                let sy = proxy.size.height / LogoGeometry.designSize.height

                RoutePinGlyph(color: Self.lightBlue, highlightColor: Self.lightBlueHighlight, headDiameter: LogoGeometry.routePinDiameter * sx)
                    .position(x: LogoGeometry.legX * sx, y: pinCenterY(tipY: LogoGeometry.legPinTipY, headDiameter: LogoGeometry.routePinDiameter) * sy)
                    .scaleEffect(animator.outerPinsVisible ? 1 : 0.75, anchor: .bottom)
                    .opacity(animator.outerPinsVisible ? 1 : 0)

                RoutePinGlyph(color: Self.orange, highlightColor: Self.orangeHighlight, headDiameter: LogoGeometry.routePinDiameter * sx)
                    .position(x: (LogoGeometry.designSize.width - LogoGeometry.legX) * sx, y: pinCenterY(tipY: LogoGeometry.legPinTipY, headDiameter: LogoGeometry.routePinDiameter) * sy)
                    .scaleEffect(animator.outerPinsVisible ? 1 : 0.75, anchor: .bottom)
                    .opacity(animator.outerPinsVisible ? 1 : 0)

                // The red pin's tip sits just above the valley vertex (not on top of it) so
                // the dark meeting point stays visible - it points at the vertex rather than
                // covering it like a badge.
                RoutePinGlyph(color: Self.meetingRed, highlightColor: Self.meetingRedHighlight, headDiameter: LogoGeometry.centerPinDiameter * sx, isElevated: false)
                    .position(
                        x: LogoGeometry.designSize.width / 2 * sx,
                        y: pinCenterY(tipY: LogoGeometry.valleyY - LogoGeometry.centerPinDiameter * LogoGeometry.centerPinGapFraction, headDiameter: LogoGeometry.centerPinDiameter) * sy
                    )
                    .scaleEffect(animator.redPinVisible ? 1 : 0.4, anchor: .bottom)
                    .opacity(animator.redPinVisible ? 1 : 0)
            }
        }
        .aspectRatio(LogoGeometry.designSize.width / LogoGeometry.designSize.height, contentMode: .fit)
    }

    /// A RoutePinGlyph is positioned by its frame's center; its tip sits half the total
    /// pin height below that center. This solves for the center Y that puts the tip at
    /// the given target Y.
    private func pinCenterY(tipY: CGFloat, headDiameter: CGFloat) -> CGFloat {
        tipY - (headDiameter * LogoGeometry.pinHeightRatio) / 2
    }

    private var routeStrokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: LogoGeometry.designSize.width * LogoGeometry.routeStrokeWidthFraction, lineCap: .round, lineJoin: .round)
    }
}

#Preview {
    LetsMeetLogoView(animator: LogoAnimator())
        .padding(40)
}
