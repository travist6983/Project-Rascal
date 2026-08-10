import SwiftUI
import WidgetKit

/// The extension's entry point.
///
/// One widget, deliberately. Multi-kid is out of scope, so there is nothing to configure and no
/// second widget to offer — a gallery with one entry in it is the honest shape of a product that
/// archives one childhood.
@main
struct RascalWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
