//
//  MazutWidgetBundle.swift
//  MazutWidget
//
//  Ulazna tačka widget ekstenzije — sadrži samo Live Activity za stemove.
//

import SwiftUI
import WidgetKit

@main
struct MazutWidgetBundle: WidgetBundle {
    var body: some Widget {
        StemLiveActivity()
    }
}
