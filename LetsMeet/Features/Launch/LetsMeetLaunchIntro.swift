//
//  LetsMeetLaunchIntro.swift
//  LetsMeet
//

import SwiftUI

/// Plays the cold-launch intro (~3s): endpoints appear, routes draw in toward the midpoint,
/// the red pin drops onto the valley, the wordmark fades in, a brief hold on the completed
/// brand, then the whole composition zooms through the midpoint while the real map (already
/// mounted underneath) is revealed. Calls `onFinished` once the zoom completes, so the
/// parent can discard this view.
struct LaunchIntroView: View {
    var onFinished: () -> Void

    /// Bound to the parent so the underlying HomeMapView can fade in during the zoom,
    /// rather than only being revealed by this view's own background/content fading out.
    @Binding var mapOpacity: Double

    @StateObject private var logoAnimator = LogoAnimator(startAtRest: false)
    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkOffset: CGFloat = 10
    @State private var introScale: CGFloat = 1
    @State private var introContentOpacity: Double = 1
    @State private var backgroundOpacity: Double = 1

    private let logoWidthFraction: CGFloat = 0.5
    private let wordmarkSpacing: CGFloat = 18
    private let wordmarkFont: Font = .system(size: 30, weight: .bold, design: .rounded)
    /// Approximate rendered height of the wordmark text, used only for the zoom-anchor
    /// calculation below - a small margin of error here is fine, since the spec only
    /// requires the midpoint to stay "near" screen center during the zoom, not pixel-exact.
    private let estimatedWordmarkHeight: CGFloat = 38
    private let logoAspectRatio = LogoGeometry.designSize.width / LogoGeometry.designSize.height

    var body: some View {
        GeometryReader { proxy in
            let logoWidth = proxy.size.width * logoWidthFraction

            ZStack {
                Color.white
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                VStack(spacing: wordmarkSpacing) {
                    LetsMeetLogoView(animator: logoAnimator)
                        .frame(width: logoWidth)

                    Text("Let's Meet")
                        .font(wordmarkFont)
                        .foregroundStyle(.primary)
                        .opacity(wordmarkOpacity)
                        .offset(y: wordmarkOffset)
                }
                .opacity(introContentOpacity)
                .scaleEffect(introScale, anchor: zoomAnchor(logoWidth: logoWidth))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear(perform: runSequence)
    }

    /// The valley vertex's fractional position within the logo+wordmark VStack, so scaling
    /// around this UnitPoint keeps the midpoint fixed on screen while everything else in
    /// the composition scales away from it and off the screen edges.
    private func zoomAnchor(logoWidth: CGFloat) -> UnitPoint {
        let logoHeight = logoWidth / logoAspectRatio
        let totalHeight = logoHeight + wordmarkSpacing + estimatedWordmarkHeight
        let valleyFractionOfLogo = LogoGeometry.valleyY / LogoGeometry.designSize.height
        let anchorY = (valleyFractionOfLogo * logoHeight) / totalHeight
        return UnitPoint(x: 0.5, y: anchorY)
    }

    // Timing (seconds from launch), retimed to let each moment register rather than snap by:
    //   0.00–0.25  endpoints appear
    //   0.25–1.10  routes draw, smooth and deliberate (stem 0.25–0.75, connector 0.68–1.10)
    //   1.10–1.40  midpoint pin springs onto the dark center
    //   1.35–1.75  wordmark fades/slides in
    //   1.75–2.20  hold on the completed logo + wordmark
    //   2.20–3.05  zoom through the midpoint, gentle start accelerating, map crossfades in
    // Each step's delay is measured from the PREVIOUS step's actual completion (via
    // sequential `Task.sleep` calls) rather than as a fixed offset from launch. Fixed
    // offsets from a single origin are fragile during a cold launch: if the main thread is
    // briefly busy (view hierarchy construction, location setup, etc.) and several
    // `asyncAfter` deadlines pass while it's blocked, they fire back-to-back the moment it
    // frees up - collapsing the gaps between those phases even though each individual
    // animation's own duration is still respected once it starts. Chaining relative delays
    // keeps the pacing between phases correct even if the whole sequence starts a beat late.
    private func runSequence() {
        withAnimation(.easeOut(duration: 0.25)) {
            logoAnimator.outerPinsVisible = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeInOut(duration: 0.50)) {
                logoAnimator.stemProgress = 1
            }

            try? await Task.sleep(nanoseconds: 430_000_000)
            withAnimation(.easeInOut(duration: 0.42)) {
                logoAnimator.connectorProgress = 1
            }

            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.64)) {
                logoAnimator.redPinVisible = true
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.40)) {
                wordmarkOpacity = 1
                wordmarkOffset = 0
            }

            // Hold on the completed brand, then begin the zoom.
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeIn(duration: 0.85)) {
                introScale = 32
            }
            withAnimation(.easeIn(duration: 0.55).delay(0.15)) {
                backgroundOpacity = 0
                mapOpacity = 1
            }
            withAnimation(.easeIn(duration: 0.45).delay(0.35)) {
                introContentOpacity = 0
            }

            try? await Task.sleep(nanoseconds: 850_000_000)
            onFinished()
        }
    }
}

/// Hosts the real HomeMapView (mounted once, for the app's whole lifetime) with the launch
/// intro on top of it. The intro is only ever created once per cold launch - backgrounding
/// and returning to the app does not recreate this view or its @State, so the intro does
/// not replay.
struct LaunchContainerView: View {
    @ObservedObject var homeViewModel: HomeViewModel

    @State private var showIntro = true
    @State private var mapOpacity: Double = 0

    var body: some View {
        ZStack {
            HomeMapView(viewModel: homeViewModel)
                .opacity(mapOpacity)
                .allowsHitTesting(!showIntro)

            if showIntro {
                LaunchIntroView(onFinished: { showIntro = false }, mapOpacity: $mapOpacity)
            }
        }
    }
}
