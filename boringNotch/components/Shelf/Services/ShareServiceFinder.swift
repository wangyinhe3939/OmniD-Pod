//
//  ShareServiceFinder.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

final class ShareServiceFinder {

    /// Returns share services asynchronously without blocking the UI
    @MainActor
    func findApplicableServices(for items: [Any], timeout _: TimeInterval = 2.0) async -> [NSSharingService] {
        // The picker is only for visible presentation. Showing it from an
        // unattached dummy view logs a ShareKit error and can leave lifecycle
        // state ambiguous. This API is deprecated on macOS 13+, but remains the
        // only system API that enumerates providers for a custom provider menu.
        NSSharingService.sharingServices(forItems: items)
    }
}
