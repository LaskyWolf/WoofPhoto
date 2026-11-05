import PhotosUI
import SwiftUI

/// M0 spike: can iOS build a Live Photo from the photo and video files Immich stores?
struct LivePhotoSpike: View {
    @Environment(Session.self) private var session
    @State private var status = "Looking for a Live Photo…"
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        VStack {
            if let livePhoto {
                LivePhotoView(livePhoto: livePhoto)
                Text("Passed. Touch and hold the photo to play it.").font(.footnote)
            }
            Text(status).font(.footnote).foregroundStyle(.secondary).padding()
        }
        .navigationTitle("Live Photo")
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            // newest months first; a library without Live Photos in the last 3 years has nothing to test
            for bucket in try await client.buckets().prefix(36) {
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
            status = "No Live Photo found in the last 36 months."
        } catch {
            status = error.explanation
        }
    }
}

struct LivePhotoView: UIViewRepresentable {
    var livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
    }
}
