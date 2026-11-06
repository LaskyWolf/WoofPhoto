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
    @Environment(Session.self) private var session
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
        .sheet(isPresented: Binding { showsAccount && session.client == nil } set: { showsAccount = $0 }) { SignInView() }
        .navigationDestination(isPresented: Binding { showsAccount && session.client != nil } set: { showsAccount = $0 }) {
            SettingsView()
        }
    }
}

extension View {
    /// WoofMusic's long press: a lifted view gets a background matching what's behind it, so text doesn't
    /// float over the blur. The margin goes back after the menu. Nil is for a view that fills its own shape.
    @ViewBuilder
    func liftedMenu<Items: View>(background: Color? = Color(.systemBackground), margin: CGFloat = 6,
                                 @ViewBuilder items: () -> Items) -> some View {
        if let background {
            let shape = RoundedRectangle(cornerRadius: Tokens.tileRadius, style: .continuous)
            padding(margin)
                .background(background, in: shape)
                .contentShape(.contextMenuPreview, shape)
                .contextMenu(menuItems: items)
                .padding(-margin)
        } else {
            contextMenu(menuItems: items)
        }
    }

    /// A tab's title and chips, pinned above the content over a fade, so what scrolls under them stays out of the way.
    func stickyHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            header()
                .padding(.bottom, 10)
                .background {
                    LinearGradient(stops: [.init(color: Color(.systemBackground), location: 0),
                                           .init(color: Color(.systemBackground).opacity(0.8), location: 0.6),
                                           .init(color: Color(.systemBackground).opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
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
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: systemImage) }
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
        .accessibilityLabel(session.client == nil ? "Sign In" : "Account and Settings")
        .task(id: session.client?.server) {
            let me = try? await session.client?.me()
            initial = me?.name.first.map { String($0).uppercased() } ?? ""
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

/// WoofMusic's album and artist header: a 160-point cover on the left; the kind line, title and a
/// secondary line beside it with round buttons under them; the cover blurred behind, fading into the page.
struct DetailHeader<Cover: View, Secondary: View, Buttons: View>: View {
    static var coverSize: CGFloat { 160 }

    let meta: String
    let title: String
    /// Round, for a person's face, like an artist in WoofMusic.
    var circle = false
    @ViewBuilder var cover: Cover
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var buttons: Buttons
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // at accessibility text sizes the title gets the full width under the cover
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            cover
                .frame(width: Self.coverSize, height: Self.coverSize)
                .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Tokens.cardRadius)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                if !meta.isEmpty {
                    Text(meta).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(title).font(.title3.bold()).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                secondary
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    buttons
                }
                .buttonStyle(ZoomPressStyle(scale: 0.92))
            }
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? nil : Self.coverSize, alignment: .leading)
        }
        .padding(.horizontal, Tokens.screenPadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            // 300 points taller than the header, reaching up under the bars and the pull-down overscroll
            Color.clear
                .frame(height: 700)
                .overlay { cover }
                .clipped()
                .blur(radius: 40, opaque: true)
                .opacity(0.7)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.top, -300)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// WoofMusic's player glyph: white, no background, a soft shadow, a 44-point target.
struct GlyphLabelStyle: LabelStyle {
    var size: CGFloat = 19
    var color = Color.white

    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .frame(width: max(44, size * 2), height: max(44, size * 2))
            .contentShape(.circle)
    }
}

/// WoofMusic's PlayerSkipButtonStyle: a soft disc shows only under the finger.
struct GlyphPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0), in: .circle)
    }
}

/// A round header button face; `filled` paints it in the accent with a white glyph, like WoofMusic's Play.
struct RoundIcon: View {
    let systemImage: String
    var filled = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: filled ? 19 : 15, weight: .bold))
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: filled ? 50 : 38, height: filled ? 50 : 38)
            .background(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.1)), in: .circle)
            .contentShape(.circle)
            .accessibilityShowsLargeContentViewer()
    }
}

extension View {
    /// The bar repeats the title only once the `DetailHeader` has scrolled away.
    func detailBarTitle(_ title: String) -> some View {
        modifier(DetailBarTitle(title: title))
    }
}

private struct DetailBarTitle: ViewModifier {
    let title: String
    @State private var isHeaderAway = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > DetailHeader<EmptyView, EmptyView, EmptyView>.coverSize
            } action: { _, away in
                isHeaderAway = away
            }
            .navigationTitle(isHeaderAway ? title : "")
            .toolbarTitleDisplayMode(.inline)
    }
}
