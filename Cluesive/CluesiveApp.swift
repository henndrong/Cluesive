//
//  CluesiveApp.swift
//  Cluesive
//
//  Created by Henndro Joshua on 27/1/26.
//

import SwiftUI
import CoreData

@main
struct CluesiveApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
