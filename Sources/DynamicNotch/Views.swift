import AppKit
import NotchKit
import SwiftUI

// MARK: - Shape

/// Flat top that flares into the menu bar, rounded bottom corners — reads as part of the notch.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

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
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var geometry: NotchGeometry
    @ObservedObject var store: HubStore
    @ObservedObject var media: NowPlaying
    @ObservedObject var volume: VolumeController

    private var flare: CGFloat { geometry.expanded ? 12 : 6 }

    var body: some View {
        let shape = NotchShape(top: flare, bottom: geometry.expanded ? 24 : 10)
        let ears = Ears(store: store, media: media)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if geometry.expanded {
                    ExpandedView(geometry: geometry, store: store, media: media, volume: volume)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    CompactView(geometry: geometry, ears: ears)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, flare)
            .background(Color.black)
            .clipShape(shape)
            // Measure directly: a preference key here only ever reported 0×0.
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { geometry.contentSize = g.size }
                    .onChange(of: g.size) { _, size in geometry.contentSize = size }
            })
            .shadow(color: .black.opacity(geometry.expanded ? 0.45 : 0), radius: 18, y: 8)
            .opacity(geometry.hasNotch || geometry.expanded || ears.hasContent ? 1 : 0)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: geometry.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ears.hasContent)
        .environment(\.colorScheme, .dark)
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
        case .artwork(let image):
            Artwork(image: image, size: geometry.notchSize.height * 0.62, radius: 5)
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

    var body: some View {
        let activities = store.visibleActivities
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.permissions) { p in
                PermissionCard(permission: p) { store.resolve(p, $0) }
            }

            if media.track != nil {
                MediaCard(media: media)
            }
            VolumeRow(volume: volume)

            if !store.agents.isEmpty {
                SectionHeader(title: "Agents")
                ForEach(store.agents.prefix(4)) { AgentRow(session: $0) }
            }

            if !activities.isEmpty {
                SectionHeader(title: "Activities")
                ForEach(activities.suffix(5).reversed()) { a in
                    ActivityRow(activity: a) { store.dismiss(a) }
                }
                if activities.count > 5 {
                    Text("+\(activities.count - 5) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if store.agents.isEmpty && activities.isEmpty && store.permissions.isEmpty {
                Text("Nothing running. Try  notch run -- sleep 5")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
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
    let decide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
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

    var body: some View {
        if let t = media.track {
            HStack(spacing: 12) {
                Artwork(image: media.artwork, size: 50, radius: 9)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.font(.system(size: 13)).frame(width: 16).padding(.top, 1)
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
