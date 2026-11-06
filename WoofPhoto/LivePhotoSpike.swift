import PhotosUI
import SwiftUI

/// M0 spike: can iOS build a Live Photo from the photo and video files Immich stores?
struct LivePhotoSpike: View {
    @Environment(Session.self) private var session
    @State private var status = "Not started"
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        VStack {
            if let livePhoto {
                LivePhotoView(livePhoto: livePhoto)
                Text("Passed. Touch and hold the photo to play it.").font(.footnote)
            }
            Text(status).font(.footnote).foregroundStyle(.secondary).padding()
            Button("Search Again") { Task { await load() } }
        }
        .navigationTitle("Live Photo")
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else {
            status = "Not signed in."
            return
        }
        livePhoto = nil
        do {
            status = "Loading the list of months…"
            // newest months first
            let buckets = try await client.buckets()
            for (number, bucket) in buckets.enumerated() {
                status = "Checking month \(number + 1) of \(buckets.count)…"
                let assets = try await client.bucket(bucket.timeBucket)
                guard let index = assets.livePhotoVideoId?.firstIndex(where: { $0 != nil }),
                      let videoID = assets.livePhotoVideoId?[index] ?? nil else { continue }
                status = "Downloading the photo and its video from \(bucket.timeBucket.prefix(7))…"
                let photo = try await client.downloadOriginal(assets.id[index])
                let video = try await client.downloadOriginal(videoID)
                status = "Files: \(photo.lastPathComponent), \(video.lastPathComponent)"
                PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { result, info in
                    DispatchQueue.main.async {
                        if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                            status = "Failed: iOS rejected the files. \(error.localizedDescription)"
                        } else if let result, info[PHLivePhotoInfoIsDegradedKey] as? Bool != true {
                            livePhoto = result
                        }
                    }
                }
                return
            }
            status = "No Live Photo in any of the \(buckets.count) months. Upload one from an iPhone with the official Immich app, then try again."
        } catch {
            // status still names the step that was running
            let code = (error as? URLError).map { " (URLError \($0.code.rawValue))" } ?? ""
            status = "Failed at: \(status)\n\(error.explanation)\(code)"
        }
    }
}

struct LivePhotoView: UIViewRepresentable {
    var livePhoto: PHLivePhoto
    /// Set by a SwiftUI hold gesture; nil leaves playback to the view's own press, as in the M0 spike.
    var playing: Bool?

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        guard let playing else { return }
        // inside the pager the view's own press never wins against the scrolling, so SwiftUI drives it
        view.playbackGestureRecognizer.isEnabled = false
        if playing != context.coordinator.playing {
            context.coordinator.playing = playing
            if playing { view.startPlayback(with: .full) } else { view.stopPlayback() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var playing = false
    }

    /// Without this SwiftUI uses the photo's full pixel size, so only its middle shows on screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PHLivePhotoView, context: Context) -> CGSize? {
        let space = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 300))
        let size = livePhoto.size
        guard size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
