import SwiftUI

// Wand native showcase. Every interactive area has an accessibilityIdentifier,
// and the last recognized gesture is mirrored into a single `#status` element so
// an automation agent can verify complex gestures via the accessibility tree
// alone — no screenshots, minimal tokens.
//
// Layout is a fixed (non-scrolling) screen so one-finger drag / long-press do not
// conflict with an outer ScrollView pan. A small bordered list provides a
// dedicated scroll target.
@main
struct ShowcaseApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class GestureState: ObservableObject {
    @Published var status: String = "ready"
    @Published var tapCount: Int = 0
    @Published var typed: String = ""
}

struct ContentView: View {
    @StateObject private var s = GestureState()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .compact && geometry.size.width > geometry.size.height && geometry.size.height < 500 {
                VStack {
                    Text("landscape").accessibilityIdentifier("landscapeReady")
                    Text(s.status).accessibilityIdentifier("status").accessibilityLabel(s.status)
                    TapSection(s: s)
                    TextSection(s: s)
                }.padding(8)
            } else { portraitContent }
        }
        // Keyboard avoidance must not replace the focused field's view hierarchy.
        .ignoresSafeArea(.keyboard)
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            let orientations: [String: UIInterfaceOrientationMask] = [
                "--portrait": .portrait, "--upside-down": .portraitUpsideDown,
                "--landscape": .landscapeRight, "--landscape-left": .landscapeLeft
            ]
            if let orientation = orientations.first(where: { args.contains($0.key) })?.value {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                        .requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
                }
            }
        }
    }

    private var portraitContent: some View {
        VStack(spacing: 8) {
            Text(s.status)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.black)
                .accessibilityIdentifier("status")
                .accessibilityLabel(s.status)

            HStack(spacing: 8) {
                TapSection(s: s)
                LongPressSection(s: s)
            }
            HStack(spacing: 8) {
                PinchSection(s: s)
                RotateSection(s: s)
            }
            DragDropSection(s: s)
            TextSection(s: s)
            CanvasSection(s: s)
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.95))
        .cornerRadius(12)
    }
}

private struct TapSection: View {
    @ObservedObject var s: GestureState
    var body: some View {
        Card(title: "Tap") {
            Button("Tap me") {
                s.tapCount += 1
                s.status = "tap:\(s.tapCount)"
            }
            .accessibilityIdentifier("tapButton")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            Text("count: \(s.tapCount)").font(.caption).accessibilityIdentifier("tapCount")
        }
    }
}

private struct LongPressSection: View {
    @ObservedObject var s: GestureState
    @State private var pressed = false
    var body: some View {
        Card(title: "Long press") {
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed ? Color.green : Color.gray)
                .frame(height: 56)
                .overlay(Text(pressed ? "held" : "hold me").foregroundColor(.white))
                .accessibilityIdentifier("longPressBox")
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            pressed = true
                            s.status = "longpress"
                        }
                )
        }
    }
}

private struct PinchSection: View {
    @ObservedObject var s: GestureState
    @State private var scale: CGFloat = 1.0
    var body: some View {
        Card(title: "Pinch / Zoom") {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange)
                .frame(width: 80, height: 80)
                .scaleEffect(scale)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .contentShape(Rectangle())
                .accessibilityIdentifier("pinchBox")
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = v; s.status = String(format: "pinch:%.2f", v) }
                        .onEnded { v in s.status = String(format: "pinched:%.2f", v) }
                )
        }
    }
}

private struct RotateSection: View {
    @ObservedObject var s: GestureState
    @State private var angle: Angle = .zero
    var body: some View {
        Card(title: "Rotate") {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple)
                .frame(width: 96, height: 64)
                .rotationEffect(angle)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .contentShape(Rectangle())
                .accessibilityIdentifier("rotateBox")
                .gesture(
                    RotationGesture()
                        .onChanged { a in angle = a; s.status = "rotate:\(Int(a.degrees))" }
                        .onEnded { a in s.status = "rotated:\(Int(a.degrees))" }
                )
        }
    }
}

private struct DragDropSection: View {
    @ObservedObject var s: GestureState
    @State private var offset: CGSize = .zero
    @State private var dropped: String = ""
    var body: some View {
        Card(title: "Drag & drop (drag red circle onto A or B)") {
            ZStack(alignment: .leading) {
                HStack {
                    Spacer()
                    ZoneView(label: "A", id: "zoneA", active: dropped == "zoneA")
                    Spacer()
                    ZoneView(label: "B", id: "zoneB", active: dropped == "zoneB")
                    Spacer()
                }
                Circle()
                    .fill(Color.red)
                    .frame(width: 60, height: 60)
                    .overlay(Text("drag").font(.caption2).foregroundColor(.white))
                    .offset(offset)
                    .accessibilityIdentifier("dragHandle")
                    .gesture(
                        DragGesture(coordinateSpace: .named("dragarea"))
                            .onChanged { v in
                                offset = v.translation
                                s.status = "drag:\(Int(v.location.x)),\(Int(v.location.y))"
                            }
                            .onEnded { v in
                                let zone = v.location.x > 200 ? "zoneB" : "zoneA"
                                dropped = zone
                                s.status = "drop:\(zone)"
                                // Snap the circle into the chosen zone and keep it there.
                                withAnimation { offset = CGSize(width: v.location.x - 30, height: 0) }
                            }
                    )
            }
            .frame(height: 84)
            .coordinateSpace(name: "dragarea")
            Text(dropped.isEmpty ? "—" : "dropped on \(dropped)").font(.caption).accessibilityIdentifier("dropResult")
        }
    }
}

private struct ZoneView: View {
    let label: String
    let id: String
    var active: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(active ? Color.green.opacity(0.25) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.green : Color.blue, lineWidth: 2))
            .frame(width: 72, height: 72)
            .overlay(Text(label))
            .accessibilityIdentifier(id)
    }
}

private struct TextSection: View {
    @ObservedObject var s: GestureState
    var body: some View {
        Card(title: "Text entry") {
            TextField("type here", text: $s.typed)
                // Keep the HID text oracle independent of keyboard preferences.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("textInput")
                .onChange(of: s.typed) { _, v in s.status = "typed:\(v)" }
        }
    }
}

// A Canvas-drawn row of "buttons" with NO accessibility at all — the labels are
// raster-drawn, not views. `wand ui` sees nothing here; Wand drives it purely
// via on-device OCR (`wand see` / `wand tapocr "Settings"`).
private struct CanvasSection: View {
    @ObservedObject var s: GestureState
    private let items = ["Start", "Settings", "Profile"]
    var body: some View {
        Card(title: "Canvas — zero accessibility (OCR only)") {
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(items.count)
                Canvas { ctx, _ in
                    for (i, label) in items.enumerated() {
                        let rect = CGRect(x: CGFloat(i) * w + 6, y: 8, width: w - 12, height: 56)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.indigo))
                        ctx.draw(Text(label).font(.headline).bold().foregroundStyle(.white),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let idx = max(0, min(items.count - 1, Int(loc.x / w)))
                    s.status = "canvas:\(items[idx])"
                }
            }
            .frame(height: 72)
            .accessibilityHidden(true)
        }
    }
}
