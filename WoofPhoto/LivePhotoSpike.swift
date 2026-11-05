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
