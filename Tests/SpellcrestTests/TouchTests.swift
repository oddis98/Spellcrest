import CoreGraphics
import Testing
@testable import Spellcrest

/// The standard layout's places in a view of `size` points, and its diamond's A, B, X and Y.
private func standard(_ size: CGSize, left: Double = 0, right: Double = 0, bottom: Double = 0) -> (TouchPlaces, a: CGPoint, b: CGPoint, x: CGPoint, y: CGPoint) {
    let places = TouchPlaces(size: size, left: left, right: right, bottom: bottom)
    let diamond = TouchLayout.diamond.map(places.middle(of:))
    return (places, diamond[0], diamond[1], diamond[2], diamond[3])
}

@Test func touchControlsHoldTheButtonsUnderEachFinger() {
    let (layout, a, b, x, y) = standard(CGSize(width: 852, height: 393), left: 59, right: 59, bottom: 21) // an iPhone, landscape
    let (pad, r) = (layout.home, TouchPlaces.pad)
    #expect(layout.buttons(at: CGPoint(x: pad.x + r * 0.8, y: pad.y + 3)) == [.right])
    #expect(layout.buttons(at: CGPoint(x: pad.x - r * 0.6, y: pad.y - r * 0.6)) == [.left, .up]) // between two: both
    #expect(layout.buttons(at: pad).isEmpty) // the middle holds nothing
    #expect(layout.buttons(at: a) == [.a] && layout.buttons(at: b) == [.b] && layout.buttons(at: x) == [.x] && layout.buttons(at: y) == [.y])
    #expect(x.y < a.y && a.y == y.y && y.y < b.y && y.x < x.x && x.x < a.x) // a diamond
    #expect(layout.buttons(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) == [.a, .b]) // one thumb on two
    #expect(layout.buttons(at: CGPoint(x: 426, y: 100)).isEmpty) // the game itself
    #expect(pad.x - r > 59 && a.x + 26 < 852 - 59) // clear of the notch and the corners
}

@Test func inPortraitTheTouchControlsAreBelowTheGame() {
    let (layout, a, b, x, y) = standard(CGSize(width: 402, height: 874), bottom: 34) // an iPhone, portrait
    let game = 402 * 180 / 320.0 // the canvas's height at the top
    #expect(layout.home.y - TouchPlaces.pad > game && [a, b, x, y].allSatisfy { Double($0.y) - 26 > game })
}

@Test func theControlsKeepTheFingersThatLandOnThemAndTheGameGetsTheRest() {
    let (layout, a, b, x, y) = standard(CGSize(width: 852, height: 393), left: 59, right: 59, bottom: 21) // an iPhone, landscape
    #expect(layout.covers(layout.home) && layout.covers(layout.groups[0].middle)) // the D-pad's middle and the diamond's, which hold nothing
    #expect([a, b, x, y].allSatisfy(layout.covers))
    #expect(!layout.covers(CGPoint(x: 426, y: 100)) && !layout.covers(CGPoint(x: 426, y: 380))) // the game, up top and between them
}

@Test func theControlsSayWhereTheyAreOverTheCanvas() {
    // An iPhone SE sideways, 667x375 points and no insets, showing a 240x135 canvas from edge to edge: as Driftwood
    // measured it on a screenshot, the D-pad reaches to about x 45, and the buttons start about x 182, y 76.
    let canvas = Size(240, 135), layout = TouchPlaces(size: CGSize(width: 667, height: 375), left: 0, right: 0, bottom: 0)
    let shown = fit(canvas, in: CGSize(width: 667, height: 375))
    #expect(layout.rectangles(over: canvas, at: CGPoint(x: shown.originX, y: shown.originY), scale: shown.width / 240)
        == [Rect(x: 8, y: 88, width: 37, height: 37), Rect(x: 182, y: 76, width: 50, height: 49)])
    // Upright, they're below the game: none over it.
    let upright = TouchPlaces(size: CGSize(width: 375, height: 667), left: 0, right: 0, bottom: 0)
    let top = fit(canvas, in: CGSize(width: 375, height: 667), top: 20)
    #expect(upright.rectangles(over: canvas, at: CGPoint(x: top.originX, y: top.originY), scale: top.width / 240).isEmpty)
}

@Test func aGameLaysOutItsOwnButtonsAndAStickOnTheLeft() {
    let layout = TouchLayout(movement: .stick(reach: 40), buttons: [
        .init(.a, at: [40, 44], radius: 34), .init(.b, at: [104, 30]), .init(.start, from: .topRight, at: [20, 20], radius: 16),
    ])
    let places = TouchPlaces(layout, size: CGSize(width: 852, height: 393), left: 59, right: 59, bottom: 21, top: 0)
    let (a, b, start) = (places.middle(of: layout.buttons[0]), places.middle(of: layout.buttons[1]), places.middle(of: layout.buttons[2]))
    #expect(a == CGPoint(x: 852 - 59 - 24 - 40, y: 393 - 21 - 16 - 44) && start == CGPoint(x: 852 - 59 - 24 - 20, y: 16 + 20)) // from their corners
    #expect(places.buttons(at: a) == [.a] && places.buttons(at: CGPoint(x: a.x, y: a.y - 45)) == [.a] && places.buttons(at: b) == [.b])
    #expect(places.buttons(at: start) == [.start])
    #expect(places.claim(a) == .buttons && places.claim(start) == .buttons)
    #expect(places.claim(CGPoint(x: 150, y: 300)) == .stick && places.claim(CGPoint(x: 400, y: 60)) == .stick) // the left half
    #expect(places.claim(CGPoint(x: 600, y: 120)) == nil) // the right half, off the buttons: the game's pointer
    #expect(places.home == CGPoint(x: 59 + 24 + 40, y: 393 - 21 - 16 - 40)) // where the stick waits
}

@Test func theStickPushesByHowFarTheThumbGoesAndHoldsTheDPadPastHalfWay() {
    let places = TouchPlaces(TouchLayout(movement: .stick(reach: 40)), size: CGSize(width: 852, height: 393), left: 0, right: 0, bottom: 0)
    let base = CGPoint(x: 200, y: 250)
    #expect(places.pushed(from: base, to: CGPoint(x: 220, y: 250)) == [0.5, 0])
    #expect(places.pushed(from: base, to: CGPoint(x: 200, y: 330)) == [0, 1]) // past its reach: 1
    #expect(Input.buttons(pushedTo: [0.4, 0]).isEmpty && Input.buttons(pushedTo: [0.8, 0]) == [.right])
    #expect(Input.buttons(pushedTo: [-0.6, -0.6]) == [.left, .up] && Input.buttons(pushedTo: [0.9, -0.2]) == [.right])
    #expect(Input.direction(stick: [0.1, 0], buttons: []) == .zero) // its dead zone
    let half = Input.direction(stick: [0.6, 0], buttons: [.right])
    #expect(abs(half.x - 0.5) < 1e-9 && half.y == 0) // past it, from nothing, as a controller's stick
}
