import AppKit
import NotchKit
import SwiftUI

// MARK: - Shape

/// Flat top that flares into the menu bar, rounded bottom corners — reads as part of the notch.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    /// False leaves out the flat top edge, for drawing an outline that stops at the top of the screen.
    var closed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        if closed { p.closeSubpath() }
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var geometry: NotchGeometry
    @ObservedObject var store: HubStore
    @ObservedObject var media: NowPlaying
    @ObservedObject var volume: VolumeController
    @State private var prefs = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pairs pieces of the closed notch with their places in the open one, for Grow.
    @Namespace private var morph

    /// With Reduce Motion on, the notch always fades.
    private var style: NotchAnimation { reduceMotion ? .fade : prefs.openAnimation }

    var body: some View {
        let ears = Ears(store: store, media: media)

        VStack(spacing: 0) {
            Group {
                switch style {
                case .grow: growing(ears)
                case .fade: fading(ears)
                }
            }
            .modifier(NotchEvents(store: store, expanded: geometry.expanded))
            // Measure directly: a preference key here only ever reported 0×0.
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { geometry.contentSize = g.size }
                    .onChange(of: g.size) { _, size in geometry.contentSize = size }
            })
            .opacity(geometry.hasNotch || geometry.expanded || ears.hasContent ? 1 : 0)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(style.animation(opening: geometry.expanded), value: geometry.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ears.hasContent)
        .environment(\.colorScheme, .dark)
    }

    /// One black shape that stretches between the closed and open sizes. The album art and the
    /// attention hand travel between their two places, and the open rows come into focus in turn.
    private func growing(_ ears: Ears) -> some View {
        let expanded = geometry.expanded
        let flare: CGFloat = expanded ? 12 : 6
        return ZStack(alignment: .top) {
            if expanded {
                ExpandedView(geometry: geometry, store: store, media: media, volume: volume, morph: morph, reveal: true)
                    .transition(.asymmetric(insertion: .opacity, removal: AnyTransition(.blurReplace)))
            } else {
                CompactView(geometry: geometry, ears: ears, morph: morph)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, flare)
        .background(Color.black)
        .clipShape(NotchShape(top: flare, bottom: expanded ? 24 : 10))
        .overlay(EdgeHighlight(top: flare, bottom: expanded ? 24 : 10).opacity(expanded ? 1 : 0))
        .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
    }

    /// The closed notch stays put and the open one fades in over it at full size.
    private func fading(_ ears: Ears) -> some View {
        ZStack(alignment: .top) {
            CompactView(geometry: geometry, ears: ears, morph: nil)
                .padding(.horizontal, 6)
                .background(Color.black)
                .clipShape(NotchShape(top: 6, bottom: 10))
            if geometry.expanded {
                ExpandedView(geometry: geometry, store: store, media: media, volume: volume, morph: nil, reveal: false)
                    .padding(.horizontal, 12)
                    .background(Color.black)
                    .clipShape(NotchShape(top: 12, bottom: 24))
                    .overlay(EdgeHighlight(top: 12, bottom: 24))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Marks a view as the same piece as its counterpart in the other notch state, so Grow
    /// moves one into the other. Does nothing without a namespace.
    @ViewBuilder func morph(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedGeometryEffect(id: id, in: namespace) } else { self }
    }
}

/// A faint white line along the sides and bottom of the open notch, so it stands off dark wallpaper.
struct EdgeHighlight: View {
    let top: CGFloat
    let bottom: CGFloat

    var body: some View {
        NotchShape(top: top, bottom: bottom, closed: false)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// The notch's reactions to events: an orange glow pulsing around its edge when something needs
/// you, and a quick sideways shake when an activity fails. Each waits a moment so the notch has
/// opened first. (A success's ripple belongs to its check mark; see `Ripple`.)
struct NotchEvents: ViewModifier {
    @ObservedObject var store: HubStore
    let expanded: Bool

    func body(content: Content) -> some View {
        let top: CGFloat = expanded ? 12 : 6, bottom: CGFloat = expanded ? 24 : 10
        content
            .keyframeAnimator(initialValue: 0.0, trigger: store.attentionPulse) { view, glow in
                view
                    .overlay(NotchShape(top: top, bottom: bottom, closed: false)
                        .stroke(Color.orange.opacity(glow), lineWidth: 2)
                        .allowsHitTesting(false))
                    .shadow(color: .orange.opacity(glow * 0.75), radius: 12)
            } keyframes: { _ in
                LinearKeyframe(0, duration: 0.25)
                CubicKeyframe(1, duration: 0.2)
                CubicKeyframe(0.3, duration: 0.3)
                CubicKeyframe(1, duration: 0.2)
                CubicKeyframe(0.3, duration: 0.3)
                CubicKeyframe(1, duration: 0.2)
                CubicKeyframe(0, duration: 0.6)
            }
            .keyframeAnimator(initialValue: 0.0, trigger: store.failurePulse) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                LinearKeyframe(0, duration: 0.3)
                CubicKeyframe(-12, duration: 0.06)
                CubicKeyframe(10, duration: 0.08)
                CubicKeyframe(-8, duration: 0.08)
                CubicKeyframe(5, duration: 0.08)
                CubicKeyframe(-2, duration: 0.07)
                CubicKeyframe(0, duration: 0.07)
            }
    }
}

/// Green rings that spread out from a success's check mark and fade.
struct Ripple: ViewModifier {
    let trigger: Int

    private struct Ring {
        var scale = 1.0
        var opacity = 0.0
    }

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                ring(delay: 0.3)
                ring(delay: 0.5)
            }
            .allowsHitTesting(false)
        }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .stroke(Color.green, lineWidth: 1.5)
            .keyframeAnimator(initialValue: Ring(), trigger: trigger) { circle, ring in
                circle.scaleEffect(ring.scale).opacity(ring.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: delay)
                    CubicKeyframe(3.2, duration: 0.75)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: delay)
                    LinearKeyframe(0.9, duration: 0.01)
                    CubicKeyframe(0, duration: 0.74)
                }
            }
    }
}

/// Brings a block of the open notch into focus a moment after the one above it.
struct Reveal: ViewModifier {
    let index: Int
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .offset(y: shown ? 0 : -8)
            .animation(.spring(response: 0.38, dampingFraction: 0.8).delay(0.04 + Double(index) * 0.035), value: shown)
    }
}

// MARK: - Compact (collapsed) state

/// What the little "ears" either side of the notch show, in priority order.
struct Ears {
    let store: HubStore
    let media: NowPlaying

    enum Left { case attention, artwork(NSImage?) }
    enum Right { case attention, running(Int), finished(Bool), equalizer }

    var left: Left? {
        if store.needsAttention { return .attention }
        if let t = media.track, t.isPlaying { return .artwork(media.artwork) }
        return nil
    }

    var right: Right? {
        if store.needsAttention { return .attention }
        if store.runningCount > 0 { return .running(store.runningCount) }
        if let last = store.visibleActivities.last(where: { $0.state != .running }) { return .finished(last.state == .success) }
        if let t = media.track, t.isPlaying { return .equalizer }
        return nil
    }

    var hasContent: Bool { left != nil || right != nil }
}

struct CompactView: View {
    @ObservedObject var geometry: NotchGeometry
    let ears: Ears
    let morph: Namespace.ID?

    var body: some View {
        let h = geometry.notchSize.height
        HStack(spacing: 0) {
            if ears.hasContent {
                leftEar.frame(width: geometry.earWidth, height: h)
            }
            Color.clear.frame(width: geometry.notchSize.width, height: h)
            if ears.hasContent {
                rightEar.frame(width: geometry.earWidth, height: h)
            }
        }
    }

    @ViewBuilder private var leftEar: some View {
        switch ears.left {
        case .attention:
            Pulsing { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
                .font(.system(size: 13, weight: .semibold))
                .morph("attention", in: morph)
        case .artwork(let image):
            Artwork(image: image, size: geometry.notchSize.height * 0.62, radius: 5)
                .morph("artwork", in: morph)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var rightEar: some View {
        switch ears.right {
        case .attention:
            Pulsing { Circle().fill(.orange).frame(width: 8, height: 8) }
        case .running(let n):
            HStack(spacing: 3) {
                ProgressView().progressViewStyle(.circular).controlSize(.mini)
                if n > 1 { Text("\(n)").font(.system(size: 11, weight: .semibold)).monospacedDigit() }
            }
        case .finished(let ok):
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.system(size: 14, weight: .semibold))
        case .equalizer:
            Equalizer().frame(width: 16, height: 12)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Expanded state

struct ExpandedView: View {
    @ObservedObject var geometry: NotchGeometry
    @ObservedObject var store: HubStore
    @ObservedObject var media: NowPlaying
    @ObservedObject var volume: VolumeController
    let morph: Namespace.ID?
    /// Bring the blocks into focus one after another as the notch opens.
    let reveal: Bool
    @State private var shown = false

    var body: some View {
        let activities = store.visibleActivities
        let shown = self.shown || !reveal
        VStack(alignment: .leading, spacing: 12) {
            Group {
                ForEach(Array(store.permissions.enumerated()), id: \.element.id) { index, p in
                    // Only the first card's hand comes out of the notch's.
                    PermissionCard(permission: p, morph: index == 0 ? morph : nil) { store.resolve(p, $0) }
                }
            }
            .modifier(Reveal(index: 0, shown: shown))

            Group {
                if media.track != nil {
                    MediaCard(media: media, morph: morph)
                }
            }
            .modifier(Reveal(index: 1, shown: shown))
            VolumeRow(volume: volume)
                .modifier(Reveal(index: 2, shown: shown))

            if !store.agents.isEmpty {
                Group {
                    SectionHeader(title: "Agents")
                    ForEach(store.agents.prefix(4)) { AgentRow(session: $0) }
                }
                .modifier(Reveal(index: 3, shown: shown))
            }

            if !activities.isEmpty {
                Group {
                    SectionHeader(title: "Activities")
                    ForEach(activities.suffix(5).reversed()) { a in
                        ActivityRow(activity: a) { store.dismiss(a) }
                    }
                    if activities.count > 5 {
                        Text("+\(activities.count - 5) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .modifier(Reveal(index: 4, shown: shown))
            }

            if store.agents.isEmpty && activities.isEmpty && store.permissions.isEmpty {
                Text("Nothing running. Try  notch run -- sleep 5")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .modifier(Reveal(index: 3, shown: shown))
            }
        }
        .onAppear { if reveal { self.shown = true } }
        .padding(.top, geometry.notchSize.height + 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: geometry.expandedWidth, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, -4)
    }
}

struct PermissionCard: View {
    let permission: PendingPermission
    var morph: Namespace.ID? = nil
    let decide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    .morph("attention", in: morph)
                Text("\(permission.agent) · \(permission.project)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(permission.tool)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            Text(permission.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
            HStack(spacing: 8) {
                Button("Answer in terminal") { decide(.terminal) }
                    .buttonStyle(PillButtonStyle(color: .white.opacity(0.12)))
                Spacer()
                Button("Deny") { decide(.deny) }
                    .buttonStyle(PillButtonStyle(color: .red.opacity(0.8)))
                Button("Allow") { decide(.allow) }
                    .buttonStyle(PillButtonStyle(color: .green.opacity(0.8)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.55)))
    }
}

struct MediaCard: View {
    @ObservedObject var media: NowPlaying
    var morph: Namespace.ID? = nil

    var body: some View {
        if let t = media.track {
            HStack(spacing: 12) {
                Artwork(image: media.artwork, size: 50, radius: 9)
                    .morph("artwork", in: morph)
                    .onTapGesture { media.openPlayer() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(t.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(t.player.displayName).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    IconButton(symbol: "backward.fill", size: 14) { media.previous() }
                    IconButton(symbol: t.isPlaying ? "pause.fill" : "play.fill", size: 20) { media.playPause() }
                    IconButton(symbol: "forward.fill", size: 14) { media.next() }
                }
            }
        }
    }
}

struct VolumeRow: View {
    @ObservedObject var volume: VolumeController

    private var symbol: String {
        if volume.muted || volume.volume == 0 { return "speaker.slash.fill" }
        if volume.volume < 0.34 { return "speaker.wave.1.fill" }
        if volume.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            if volume.adjustable {
                PillSlider(value: volume.muted ? 0 : Double(volume.volume), symbol: symbol,
                           onChange: { volume.set(Float($0)) },
                           onTapIcon: { volume.setMuted(!volume.muted) })
                Text(volume.muted ? "Muted" : "\(Int((volume.volume * 100).rounded()))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else {
                IconButton(symbol: symbol, size: 12) { volume.setMuted(!volume.muted) }
                    .frame(width: 20)
                Text("\(volume.deviceName) doesn't support volume control")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Control Center–style fat capsule: white fill over a dark track, speaker icon riding inside the fill.
/// Drag anywhere to set; tap the icon to mute.
struct PillSlider: View {
    let value: Double
    let symbol: String
    let onChange: (Double) -> Void
    let onTapIcon: () -> Void

    @State private var dragging = false
    private let height: CGFloat = 26

    var body: some View {
        GeometryReader { g in
            let width = g.size.width
            let h = dragging ? height + 4 : height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                // Never narrower than a circle, so the icon always sits on white.
                Capsule().fill(Color.white).frame(width: max(h, CGFloat(value) * width))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: h, height: h)
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if isIconTap(v) { return }
                        dragging = true
                        onChange(min(max(v.location.x / width, 0), 1))
                    }
                    .onEnded { v in
                        if isIconTap(v) { onTapIcon() }
                        dragging = false
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
        }
        .frame(height: height + 4)
    }

    private func isIconTap(_ v: DragGesture.Value) -> Bool {
        v.startLocation.x < height && abs(v.translation.width) < 3 && abs(v.translation.height) < 3
    }
}

struct AgentRow: View {
    let session: AgentSession

    private var color: Color {
        switch session.state {
        case .working: return .blue
        case .waiting: return .orange
        case .idle, .ended: return .green
        }
    }

    private var label: String {
        switch session.state {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .idle, .ended: return "Idle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if session.state == .working || session.state == .waiting {
                    Pulsing { Circle().fill(color) }
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 8, height: 8)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(session.agent).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                    Elapsed(since: session.since)
                }
                if let d = session.detail, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    let dismiss: () -> Void
    /// Bumped when this activity succeeds while it's on screen (or just before the notch opened
    /// to show it), to send a ripple out from its check mark.
    @State private var ripple = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.font(.system(size: 13)).frame(width: 16).padding(.top, 1)
                .modifier(Ripple(trigger: ripple))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let src = activity.source {
                        Text(src).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let done = activity.finishedAt {
                        Text(Elapsed.format(done.timeIntervalSince(activity.startedAt)))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        IconButton(symbol: "xmark", size: 9, action: dismiss).foregroundStyle(.secondary)
                    } else {
                        Elapsed(since: activity.startedAt)
                    }
                }
                if let d = activity.detail, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if activity.state == .running {
                    if let p = activity.progress {
                        ProgressView(value: p).progressViewStyle(.linear).tint(.blue).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = activity.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        }
        // A success usually opens the notch, so the row appears just after it finished.
        .onAppear {
            if activity.state == .success, let done = activity.finishedAt, Date().timeIntervalSince(done) < 1.5 { ripple += 1 }
        }
        .onChange(of: activity.state) { _, state in
            if state == .success { ripple += 1 }
        }
    }

    @ViewBuilder private var icon: some View {
        switch activity.state {
        case .running: Image(systemName: activity.symbol ?? "gearshape.2.fill").foregroundStyle(.blue)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Small pieces

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(since)))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct Pulsing<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            content.opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t * 4)))
        }
    }
}

struct Equalizer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { i in
                    let phase = t * (5 + Double(i) * 1.3) + Double(i)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 2.5, height: 3 + 9 * CGFloat(0.5 + 0.5 * sin(phase)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(color))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
