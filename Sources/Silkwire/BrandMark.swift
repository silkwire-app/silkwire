import SwiftUI
import AppKit

/// Ari on her strand, by Claude.app (brand kit: Project Ari 2 / ari-in-grey,
/// the `on-strand ... -small` files: legs 1.6x thicker and a heavier strand so she
/// holds up at sidebar size). Silver with a hint of violet on Midnight, graphite on
/// Parchment, as the kit recommends. The drawing is the kit's geometry verbatim;
/// only the gradient colours differ between the two finishes.
enum AriArt {
    enum Finish { case silverViolet, graphite }

    static func svg(_ finish: Finish) -> String {
        let defs: String
        switch finish {
        case .silverViolet:
            let shell = [("0", "#ffffff"), (".34", "#eef0f4"), (".52", "#c3c6cf"), (".56", "#6e717c"), (".72", "#8a8d98"), (".9", "#a596d6"), ("1", "#9f8fe0")]
            defs = linear("ID_legs", y1: "-46", y2: "0", [("0", "#ffffff"), (".45", "#d7d9e0"), (".72", "#9a9da8"), ("1", "#a79ccc")])
                + linear("ID_abd", y1: "-39.19", y2: "-2.94", shell)
                + linear("ID_pro", y1: "-21.53", y2: "-4.51", shell)
                + linear("ID_ped", y1: "-17.06", y2: "-10.71", shell)
                + rim("0.42") + spec + strand(edge: "#d6d8e0", centre: "#ffffff")
        case .graphite:
            let shell = [("0", "#d6d8e0"), (".30", "#6a6c78"), (".5", "#17171d"), (".72", "#1b1b22"), (".9", "#2e2f38"), ("1", "#45464f")]
            defs = linear("ID_legs", y1: "-46", y2: "0", [("0", "#9a9dad"), (".42", "#3a3b45"), (".68", "#1a1a21"), ("1", "#33343d")])
                + linear("ID_abd", y1: "-39.19", y2: "-2.94", shell)
                + linear("ID_pro", y1: "-21.53", y2: "-4.51", shell)
                + linear("ID_ped", y1: "-17.06", y2: "-10.71", shell)
                + rim("0.55") + spec + strand(edge: "#2a2b33", centre: "#000000")
        }
        let prefix = finish == .silverViolet ? "gi" : "gs"
        let document = "<?xml version='1.0' encoding='UTF-8'?><svg xmlns='http://www.w3.org/2000/svg' viewBox='-150.14 -58 300.28 71.6' width='300.28' height='71.6'><defs>" + defs + "</defs>" + geometry + "</svg>"
        return document.replacingOccurrences(of: "ID_", with: prefix)
    }

    private static func linear(_ id: String, y1: String, y2: String, _ stops: [(String, String)]) -> String {
        "<linearGradient id='\(id)' gradientUnits='userSpaceOnUse' x1='0' y1='\(y1)' x2='0' y2='\(y2)'>" + stops.map { "<stop offset='\($0.0)' stop-color='\($0.1)'/>" }.joined() + "</linearGradient>"
    }
    private static func rim(_ opacity: String) -> String {
        "<radialGradient id='ID_rim' cx='.5' cy='.5' r='.5'><stop offset='.55' stop-color='#000' stop-opacity='0'/><stop offset='1' stop-color='#000' stop-opacity='\(opacity)'/></radialGradient>"
    }
    private static let spec = "<radialGradient id='ID_spec' cx='.5' cy='.5' r='.5'><stop offset='0' stop-color='#fff' stop-opacity='.95'/><stop offset='.5' stop-color='#fff' stop-opacity='.35'/><stop offset='1' stop-color='#fff' stop-opacity='0'/></radialGradient>"
    private static func strand(edge: String, centre: String) -> String {
        "<linearGradient id='ID_strand' gradientUnits='userSpaceOnUse' x1='-146.14' y1='0' x2='146.14' y2='0'><stop offset='0' stop-color='\(edge)' stop-opacity='0'/><stop offset='0.14' stop-color='\(edge)' stop-opacity='.85'/><stop offset='0.36' stop-color='\(centre)' stop-opacity='.95'/><stop offset='0.64' stop-color='\(centre)' stop-opacity='.95'/><stop offset='0.86' stop-color='\(edge)' stop-opacity='.85'/><stop offset='1' stop-color='\(edge)' stop-opacity='0'/></linearGradient>"
    }

    /// Strand, eight legs, palps and body, back to front, exactly as in the kit.
    private static let geometry = [
        "<line x1='-146.14' y1='0' x2='146.14' y2='0' stroke='url(#ID_strand)' stroke-width='1.6'/>",
        leg("M2.77 -11.77L8.45 -35.57L4.92 -36.5L-1.83 -12.97ZM5.03 -35.28L16.63 -11.42L18.62 -12.32L8.34 -36.78ZM4.86 -36.03a1.82 1.82 0 1 0 3.64 0a1.82 1.82 0 1 0 -3.64 0ZM16.8 -11.14L28.18 0L28.18 0L18.44 -12.6ZM16.53 -11.87a1.1 1.1 0 1 0 2.19 0a1.1 1.1 0 1 0 -2.19 0Z", "0.78"),
        leg("M-2.01 -13.05L-7.87 -31.21L-11.41 -30.18L-6.58 -11.72ZM-11.48 -30.81L-12.09 -10.32L-9.86 -10.18L-7.8 -30.57ZM-11.48 -30.69a1.84 1.84 0 1 0 3.68 0a1.84 1.84 0 1 0 -3.68 0ZM-12.09 -10.09L-9.53 0L-9.53 0L-9.87 -10.41ZM-12.1 -10.25a1.12 1.12 0 1 0 2.24 0a1.12 1.12 0 1 0 -2.24 0Z", "0.8"),
        leg("M-6.67 -14.03L-28.6 -38.02L-31.39 -35.55L-10.25 -10.87ZM-31.38 -38.03L-53.79 -12.15L-52.1 -10.62L-28.62 -35.54ZM-31.85 -36.78a1.86 1.86 0 1 0 3.72 0a1.86 1.86 0 1 0 -3.72 0ZM-53.57 -12.34L-70.54 0L-70.54 0L-52.33 -10.43ZM-54.09 -11.38a1.14 1.14 0 1 0 2.28 0a1.14 1.14 0 1 0 -2.28 0Z", "0.83"),
        "<ellipse cx='24.87' cy='-21.06' rx='18.45' ry='18.12' fill='url(#ID_abd)'/><ellipse cx='24.87' cy='-21.06' rx='18.45' ry='18.12' fill='url(#ID_rim)'/><ellipse cx='19.34' cy='-31.57' rx='5.54' ry='2.54' transform='rotate(-18 19.34 -31.57)' fill='url(#ID_spec)'/><ellipse cx='10.94' cy='-13.89' rx='4.08' ry='3.17' fill='url(#ID_ped)'/><ellipse cx='10.94' cy='-13.89' rx='4.08' ry='3.17' fill='url(#ID_rim)'/>",
        leg("M-7.95 -14.38L-40.8 -41.27L-43.25 -38.34L-11.05 -10.69ZM-43.14 -41.36L-78.57 -14.89L-77.18 -12.96L-40.9 -38.26ZM-43.93 -39.81a1.91 1.91 0 1 0 3.82 0a1.91 1.91 0 1 0 -3.82 0ZM-78.43 -14.98L-104.14 0L-104.14 0L-77.32 -12.87ZM-79.07 -13.93a1.19 1.19 0 1 0 2.39 0a1.19 1.19 0 1 0 -2.39 0Z", "0.89"),
        "<ellipse cx='-0.04' cy='-13.02' rx='9.7' ry='8.51' fill='url(#ID_pro)'/><ellipse cx='-0.04' cy='-13.02' rx='9.7' ry='8.51' fill='url(#ID_rim)'/><ellipse cx='-2.95' cy='-17.96' rx='2.91' ry='1.19' transform='rotate(-18 -2.95 -17.96)' fill='url(#ID_spec)'/>",
        leg("M-8.13 -11.88L-13.5 -7.64L-12.66 -6.46L-6.92 -10.19ZM-12.69 -7.66L-16.99 -9.58L-16.99 -9.58L-13.47 -6.44ZM-13.8 -7.05a0.72 0.72 0 1 0 1.45 0a0.72 0.72 0 1 0 -1.45 0Z", "0.9"),
        leg("M10.49 -10.61L46.15 -36.9L43.87 -40.05L7.67 -14.52ZM43.87 -36.9L79.24 -12.17L80.66 -14.14L46.15 -40.05ZM43.07 -38.48a1.94 1.94 0 1 0 3.89 0a1.94 1.94 0 1 0 -3.89 0ZM79.37 -12.09L104.14 0L104.14 0L80.53 -14.22ZM78.74 -13.16a1.21 1.21 0 1 0 2.43 0a1.21 1.21 0 1 0 -2.43 0Z", "0.9"),
        leg("M-4.81 -11.89L-9.03 -7.65L-8.05 -6.56L-3.4 -10.33ZM-8.05 -7.64L-11.34 -9.68L-11.34 -9.68L-9.04 -6.57ZM-9.27 -7.11a0.73 0.73 0 1 0 1.46 0a0.73 0.73 0 1 0 -1.46 0Z", "0.91"),
        leg("M8.06 -10.78L31.67 -31.43L29.11 -34.44L4.92 -14.48ZM29.07 -31.47L53.22 -10.54L54.9 -12.4L31.72 -34.4ZM28.42 -32.93a1.98 1.98 0 1 0 3.95 0a1.98 1.98 0 1 0 -3.95 0ZM53.42 -10.4L73.21 0L73.21 0L54.71 -12.54ZM52.81 -11.47a1.25 1.25 0 1 0 2.5 0a1.25 1.25 0 1 0 -2.5 0Z", "0.94"),
        leg("M3.25 -11.5L17.76 -39.02L14.21 -40.95L-1.02 -13.83ZM14.06 -39.37L23.38 -12.73L25.88 -13.53L17.91 -40.6ZM13.97 -39.98a2.02 2.02 0 1 0 4.04 0a2.02 2.02 0 1 0 -4.04 0ZM23.39 -12.71L29.04 0L29.04 0L25.88 -13.55ZM23.32 -13.13a1.31 1.31 0 1 0 2.63 0a1.31 1.31 0 1 0 -2.63 0Z", "0.99"),
        leg("M-2.04 -13.13L-8.44 -42.65L-12.41 -41.84L-6.8 -12.17ZM-12.23 -43.18L-25.44 -16.09L-23.08 -14.87L-8.63 -41.31ZM-12.45 -42.24a2.03 2.03 0 1 0 4.06 0a2.03 2.03 0 1 0 -4.06 0ZM-25.26 -16.36L-37.85 0L-37.85 0L-23.27 -14.61ZM-25.59 -15.48a1.33 1.33 0 1 0 2.65 0a1.33 1.33 0 1 0 -2.65 0Z", "1"),
    ].joined()
    private static func leg(_ d: String, _ opacity: String) -> String {
        "<path d='\(d)' fill='url(#ID_legs)' opacity='\(opacity)'/>"
    }

    /// Decoded image, cached per finish. Nil only if this macOS can't read SVG.
    static func image(_ finish: Finish) -> NSImage? {
        if let cached = cache[finish] { return cached }
        let image = svg(finish).data(using: .utf8).flatMap(NSImage.init(data:))
        cache[finish] = image
        return image
    }
    nonisolated(unsafe) private static var cache: [Finish: NSImage] = [:]
}

/// The sidebar's mark: Ari on her strand, with SILKWIRE centred quietly beneath
/// (the kit's "stacked quiet": name at about 60% of her span, 78% ink). Right-click
/// to show Ari alone. Falls back to the old spider if the artwork can't be drawn.
struct AriSidebarMark: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("brand.sidebarShowsName") private var showsName = true
    /// Pulls the name up into the empty canvas below the strand.
    static let nameLift: CGFloat = -5
    var body: some View {
        // Spacing 0 plus a small negative pad: the artwork keeps ~10pt of empty canvas
        // below the strand, so the name now sits about 7pt under the wire (Jason: closer,
        // not tight).
        VStack(spacing: 0) {
            if let art = AriArt.image(scheme == .dark ? .silverViolet : .graphite) {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 230)
                    .accessibilityLabel("Silkwire")
            } else {
                SilkwireSpider().fill(SilkwireTheme.brandMark).frame(width: 49, height: 49)
            }
            if showsName {
                SilkwireWordmark().scaleEffect(0.62).opacity(0.78).frame(height: 16).padding(.top, AriSidebarMark.nameLift)
            }
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            Toggle("Show “Silkwire” under Ari", isOn: $showsName)
        }
    }
}
