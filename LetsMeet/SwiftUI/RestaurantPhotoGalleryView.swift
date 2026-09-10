//
//  RestaurantPhotoGalleryView.swift
//  LetsMeet
//

import SwiftUI
import UIKit

/// Adaptive, swipeable photo gallery for one restaurant card: a hero image
/// with a thumbnail rail alongside it, sized to however many photos Yelp's
/// Business Details endpoint actually returns for this business (verified
/// to be up to 3 on this app's current plan; the 2x2 grid path below is
/// forward-compatible with higher tiers but isn't reachable today).
///
/// The hero is a custom carousel (not TabView) so forward/backward swiping
/// wraps seamlessly at the ends, and the thumbnail rail always previews the
/// photos coming up next in carousel order - never the current hero.
///
/// Starts from the Business Search `image_url` as an immediate fallback
/// hero, then lazily fetches the full gallery on appear and upgrades in
/// place once it arrives - so the results sheet never blocks on this.
struct RestaurantPhotoGalleryView: View {
    let businessID: String
    let fallbackImageURL: URL?

    @State private var photos: [URL] = []
    @State private var selectedIndex: Int = 0
    @State private var isAdvancingForward = true
    @State private var didStartFetch = false

    private let galleryHeight: CGFloat = 180
    private let heroWidthFraction: CGFloat = 0.62
    private let spacing: CGFloat = 6
    private let maxVisibleThumbnails = 4

    var body: some View {
        GeometryReader { geo in
            let hasThumbnails = photos.count > 1
            let heroWidth = hasThumbnails ? geo.size.width * heroWidthFraction : geo.size.width
            let thumbnailColumnWidth = geo.size.width - heroWidth - (hasThumbnails ? spacing : 0)

            HStack(spacing: hasThumbnails ? spacing : 0) {
                hero(width: heroWidth)

                if hasThumbnails {
                    thumbnailRail(width: thumbnailColumnWidth)
                }
            }
        }
        .frame(height: galleryHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: startFetchIfNeeded)
    }

    // MARK: - Hero

    private func hero(width: CGFloat) -> some View {
        RemotePhotoImage(
            url: photos[safe: selectedIndex],
            width: width,
            height: galleryHeight,
            allowsAspectFit: true
        )
        .id(selectedIndex)
        .transition(heroTransition)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard photos.count > 1,
                          abs(value.translation.width) > abs(value.translation.height)
                    else { return }
                    if value.translation.width < -40 {
                        advance(by: 1)
                    } else if value.translation.width > 40 {
                        advance(by: -1)
                    }
                }
        )
    }

    private var heroTransition: AnyTransition {
        isAdvancingForward
            ? .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
              )
            : .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
              )
    }

    // MARK: - Thumbnails

    /// Photo indices in forward carousel order starting right after the
    /// current hero - e.g. hero=A -> [B, C], hero=B -> [C, A]. Never
    /// includes the hero's own index.
    private var thumbnailIndices: [Int] {
        guard photos.count > 1 else { return [] }
        return (1..<photos.count).map { (selectedIndex + $0) % photos.count }
    }

    private var visibleThumbnailIndices: [Int] {
        Array(thumbnailIndices.prefix(maxVisibleThumbnails))
    }

    private var thumbnailOverflowCount: Int {
        max(0, thumbnailIndices.count - maxVisibleThumbnails)
    }

    @ViewBuilder
    private func thumbnailRail(width: CGFloat) -> some View {
        let indices = visibleThumbnailIndices
        switch indices.count {
        case 1:
            thumbnailButton(index: indices[0], width: width, height: galleryHeight)
        case 2:
            VStack(spacing: spacing) {
                // Keyed by slot position (not photo index) so a slot's view
                // identity never changes as photos rotate through it - this
                // is what prevents SwiftUI from animating a positional slide
                // between slots. The content crossfade happens inside
                // thumbnailButton via .id(index) on the image itself.
                ForEach(Array(indices.enumerated()), id: \.offset) { _, index in
                    thumbnailButton(index: index, width: width, height: (galleryHeight - spacing) / 2)
                }
            }
        default:
            // 4+ photos: 2x2 grid, forward-compatible with plans above the
            // 3-photo cap verified for this app - not reachable today.
            let cellWidth = (width - spacing) / 2
            let cellHeight = (galleryHeight - spacing) / 2
            LazyVGrid(
                columns: [GridItem(.fixed(cellWidth), spacing: spacing), GridItem(.fixed(cellWidth), spacing: spacing)],
                spacing: spacing
            ) {
                ForEach(Array(indices.enumerated()), id: \.offset) { offset, index in
                    thumbnailButton(
                        index: index,
                        width: cellWidth,
                        height: cellHeight,
                        overflowCount: (offset == indices.count - 1 && thumbnailOverflowCount > 0) ? thumbnailOverflowCount : nil
                    )
                }
            }
        }
    }

    private func thumbnailButton(index: Int, width: CGFloat, height: CGFloat, overflowCount: Int? = nil) -> some View {
        Button {
            guard let position = thumbnailIndices.firstIndex(of: index) else { return }
            advance(by: position + 1)
        } label: {
            RemotePhotoImage(url: photos[safe: index], width: width, height: height, allowsAspectFit: false)
                // Forces a crossfade (not a slide) when this slot's photo
                // changes: changing .id() swaps the view in place via
                // .transition, since the slot around it never moves.
                .id(index)
                .transition(.opacity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if let overflowCount {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.45))
                            Text("+\(overflowCount)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
    }

    // MARK: - Carousel

    /// Moves the hero `steps` positions forward (positive) or backward
    /// (negative) in the photo list, wrapping around at either end so the
    /// carousel never stops at the first or last photo.
    private func advance(by steps: Int) {
        guard photos.count > 1 else { return }
        isAdvancingForward = steps > 0
        withAnimation(.easeInOut(duration: 0.28)) {
            selectedIndex = ((selectedIndex + steps) % photos.count + photos.count) % photos.count
        }
    }

    // MARK: - Loading

    private func startFetchIfNeeded() {
        if photos.isEmpty, let fallbackImageURL {
            photos = [fallbackImageURL]
        }

        guard !didStartFetch else { return }
        didStartFetch = true

        YelpManager.shared.fetchPhotos(forBusinessID: businessID) { result in
            DispatchQueue.main.async {
                guard case .success(let fetchedPhotos) = result, !fetchedPhotos.isEmpty else { return }
                photos = fetchedPhotos
                if selectedIndex >= photos.count {
                    selectedIndex = 0
                }
            }
        }
    }
}

/// Renders one remote photo at a fixed, deterministic size so layout never
/// jumps while it loads. Landscape (or still-loading/failed) photos fill and
/// clip the frame; when `allowsAspectFit` is set, a portrait photo is shown
/// in full via aspect-fit over a blurred backdrop of itself instead of being
/// cropped to fill.
private struct RemotePhotoImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let allowsAspectFit: Bool

    @StateObject private var loader = RemoteImageBox()

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                if allowsAspectFit, uiImage.size.height > uiImage.size.width {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .blur(radius: 18)
                        .overlay(Color.black.opacity(0.28))
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: width, height: height)
                } else {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .onAppear { loader.load(url) }
        .onChange(of: url) { newURL in loader.load(newURL) }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LetsMeetColor.lightBlue.opacity(0.15))
            .overlay(
                Image(systemName: "fork.knife")
                    .font(.system(size: min(width, height) * 0.3))
                    .foregroundColor(LetsMeetColor.lightBlue)
            )
    }
}

/// Fetches and decodes one photo's raw bytes directly (bypassing AsyncImage)
/// so its pixel dimensions are available to distinguish portrait from
/// landscape. A small in-memory cache keeps repeated hero/thumbnail swaps of
/// the same URL (e.g. cycling the carousel) instant with no flicker.
private final class RemoteImageBox: ObservableObject {
    @Published private(set) var image: UIImage?

    private var currentURL: URL?
    private static let cache = NSCache<NSURL, UIImage>()

    func load(_ newURL: URL?) {
        guard newURL != currentURL else { return }
        currentURL = newURL

        guard let newURL else {
            image = nil
            return
        }

        if let cached = Self.cache.object(forKey: newURL as NSURL) {
            image = cached
            return
        }

        image = nil
        URLSession.shared.dataTask(with: newURL) { [weak self] data, _, _ in
            guard let data, let decoded = UIImage(data: data) else { return }
            Self.cache.setObject(decoded, forKey: newURL as NSURL)
            DispatchQueue.main.async {
                guard self?.currentURL == newURL else { return }
                self?.image = decoded
            }
        }.resume()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
