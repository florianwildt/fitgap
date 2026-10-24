import SwiftUI

/// Floating progress of a running sync or export. Liquid Glass on iOS 26, system material before.
/// While the Apple Health export runs, tapping the capsule opens its details; Cancel keeps its own tap.
struct SyncProgressCapsule: View {
    @ObservedObject var model: AppModel
    let showHealthDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(model.progress).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.healthExporting {
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Button("Abbrechen", role: .cancel) { model.cancel() }
                .modifier(GlassButton())
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Capsule())
        .onTapGesture { if model.healthExporting { showHealthDetails() } }
        .modifier(GlassCapsule())
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Details")) { if model.healthExporting { showHealthDetails() } }
        .accessibilityIdentifier("sync-progress")
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

private struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.buttonStyle(.glass) } else { content.buttonStyle(.bordered) }
    }
}
