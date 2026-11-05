import SwiftUI

/// Layout constants shared with WoofMusic, so both apps keep the same rhythm.
enum Tokens {
    static let screenPadding: CGFloat = 16
    static let sectionGap: CGFloat = 24
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    /// Height of the chip row under each tab title.
    static let controlHeight: CGFloat = 40
    static let cardColor = Color(.secondarySystemBackground)
}

/// WoofMusic's accent colours. The chosen one tints buttons, chips and the selected tab.
struct AccentPreset: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

    static let all: [AccentPreset] = [
        AccentPreset(name: "Default Blue", color: Color(red: 0, green: 0.48, blue: 1)),
        AccentPreset(name: "Red", color: Color(red: 0.91, green: 0.22, blue: 0.22)),
        AccentPreset(name: "Orange", color: Color(red: 0.95, green: 0.45, blue: 0.13)),
        AccentPreset(name: "Amber", color: Color(red: 0.98, green: 0.70, blue: 0.15)),
        AccentPreset(name: "Green", color: Color(red: 0.18, green: 0.72, blue: 0.32)),
        AccentPreset(name: "Teal", color: Color(red: 0.12, green: 0.65, blue: 0.60)),
        AccentPreset(name: "Cyan", color: Color(red: 0.15, green: 0.70, blue: 0.90)),
        AccentPreset(name: "Purple", color: Color(red: 0.60, green: 0.35, blue: 0.90)),
        AccentPreset(name: "Pink", color: Color(red: 0.94, green: 0.35, blue: 0.66)),
        AccentPreset(name: "Indigo", color: Color(red: 0.33, green: 0.40, blue: 0.95)),
        AccentPreset(name: "Lime", color: Color(red: 0.55, green: 0.75, blue: 0.20)),
        AccentPreset(name: "Brown", color: Color(red: 0.62, green: 0.43, blue: 0.30)),
    ]

    static func named(_ name: String) -> AccentPreset { all.first { $0.name == name } ?? all[0] }
}

/// A tab's large title with round icon buttons and the account button, as in WoofMusic.
struct TabHeader<Buttons: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var buttons: Buttons
    @State private var showsAccount = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 12) {
                buttons
                AccountButton { showsAccount = true }
            }
        }
        .padding(.horizontal, Tokens.screenPadding)
        .padding(.vertical, 8)
        .sheet(isPresented: $showsAccount) {
            NavigationStack {
                SettingsView().toolbar {
                    Button("Done", role: .close) { showsAccount = false }
                }
            }
        }
    }
}

extension TabHeader where Buttons == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A 36-point icon button that bounces when tapped. Takes taps on 44 points.
struct HeaderButton: View {
    let label: String
    let systemImage: String
    var isOn = false
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: taps)
                .frame(width: 36, height: 36)
                .tapArea(outset: 4)
        }
        .buttonStyle(IconPressStyle())
        .accessibilityLabel(label)
    }
}

/// The signed-in user's initial in a circle; opens Settings.
struct AccountButton: View {
    let action: () -> Void
    @Environment(Session.self) private var session
    @State private var initial = ""

    var body: some View {
        Button(action: action) {
            Text(initial)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Color(.systemGray), Color(.systemGray3)], startPoint: .top, endPoint: .bottom), in: .circle)
                .overlay { if initial.isEmpty { Image(systemName: "person.fill").foregroundStyle(.white) } }
                .tapArea(outset: 4)
        }
        .buttonStyle(IconPressStyle())
        .accessibilityLabel("Account and Settings")
        .task {
            guard initial.isEmpty, let me = try? await session.client?.me() else { return }
            initial = me.name.first.map { String($0).uppercased() } ?? ""
        }
    }
}

/// A row of capsule chips; the selected one is filled with the accent.
struct FilterChips<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let selected = item == selection
                    Button {
                        withAnimation(.snappy) { selection = item }
                    } label: {
                        Text(title(item))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .frame(minHeight: Tokens.controlHeight)
                            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemGray5)), in: .capsule)
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(ZoomPressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Tokens.screenPadding)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A section title in a feed, with an optional See All link.
struct FeedTitle<Destination: View>: View {
    let title: String
    @ViewBuilder var destination: Destination

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            if Destination.self != EmptyView.self {
                NavigationLink("See All") { destination }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, Tokens.screenPadding)
        .padding(.top, Tokens.sectionGap)
        .padding(.bottom, 8)
    }
}

extension FeedTitle where Destination == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: Press feedback (from WoofMusic)

/// How long the feedback stays after the finger lifts, so a quick tap still shows it.
private let pressLinger: Duration = .milliseconds(200)

/// Shrinks a card while it is pressed, also on a quick tap.
struct ZoomPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        ZoomPressLabel(configuration: configuration, scale: scale)
    }
}

private struct ZoomPressLabel: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomed = false

    var body: some View {
        configuration.label
            .scaleEffect(zoomed && !reduceMotion ? scale : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: zoomed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    zoomed = true
                } else {
                    Task {
                        try? await Task.sleep(for: pressLinger)
                        if !configuration.isPressed { zoomed = false }
                    }
                }
            }
    }
}

/// Shrinks an icon over a soft disc under the finger.
struct IconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconPressLabel(configuration: configuration)
    }
}

private struct IconPressLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0), in: .circle)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.85)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// Grows the area that takes the tap by `outset`, without moving anything around the view.
    func tapArea(outset: CGFloat) -> some View {
        padding(outset).contentShape(.rect).padding(-outset)
    }
}
