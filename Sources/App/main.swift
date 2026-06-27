import AppKit

// Explicit entry point for the agent app.
//
// A nib-less menu bar agent must build NSApplication by hand: create the shared instance,
// set the activation policy *before* the app finishes launching, install the delegate, and
// run the event loop. Relying on `@main` + an inferred main nib is what left the app
// running with no status item — the delegate's launch code never executed.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Accessory: status item only, no Dock icon, no app menu bar of our own.
app.setActivationPolicy(.accessory)

app.run()
