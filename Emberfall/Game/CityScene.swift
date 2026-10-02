import SpriteKit
import SwiftUI

/// The 8×8 city grid. All colors come from the active ThemePack — the scene
/// knows nothing about "ember" vs "frost"; it asks the theme.
final class CityScene: SKScene {
    var onTapSlot: ((Int) -> Void)?

    private var tileNodes: [SKShapeNode] = []
    private var buildingNodes: [String: SKNode] = [:]
    private var theme: ThemePack = .active
    private let gridN = 8

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(theme.background)
        buildGrid()
    }

    func refresh(buildings: [BuildingView], theme: ThemePack) {
        self.theme = theme
        backgroundColor = UIColor(theme.background)
        for node in buildingNodes.values { node.removeFromParent() }
        buildingNodes.removeAll()
        for b in buildings {
            guard b.slot >= 0, b.slot < 64 else { continue }
            let tile = tileNodes[b.slot]
            let node = buildingNode(for: b, at: tile.position)
            node.name = "slot:\(b.slot)"
            addChild(node)
            buildingNodes[b.id] = node
        }
    }

    // MARK: - Grid

    private func buildGrid() {
        removeAllChildren()
        tileNodes = []
        let s = min(size.width, size.height)
        let tile = s / CGFloat(gridN)
        let originX = (size.width - s) / 2
        let originY = (size.height - s) / 2
        for row in 0..<gridN {
            for col in 0..<gridN {
                let cx = originX + tile * (CGFloat(col) + 0.5)
                let cy = originY + tile * (CGFloat(gridN - 1 - row) + 0.5)
                let rect = CGRect(x: cx - tile / 2 + 2, y: cy - tile / 2 + 2,
                                  width: tile - 4, height: tile - 4)
                let shape = SKShapeNode(rect: rect, cornerRadius: tile * 0.12)
                shape.fillColor = UIColor(theme.surface)
                // Terrain texture: alternate the two city earth variants for
                // subtle variety. Missing texture -> flat fill (never blank).
                let tkey = (row + col) % 2 == 0 ? "city" : "cityAlt"
                if let tname = theme.terrain(tkey), UIImage(named: tname) != nil {
                    shape.fillTexture = SKTexture(imageNamed: tname)
                }
                shape.strokeColor = UIColor(theme.surface2)
                shape.lineWidth = 1
                shape.name = "slot:\(row * gridN + col)"
                addChild(shape)
                tileNodes.append(shape)
            }
        }
    }

    private func buildingNode(for b: BuildingView, at pos: CGPoint) -> SKNode {
        let def = theme.building(b.type)
        let s = min(size.width, size.height) / CGFloat(gridN)
        let container = SKNode()
        container.position = pos

        // Real-art path: theme sprite for this building's visual stage.
        // The sprite carries its own silhouette + ground shadow, so the flat
        // background rect is skipped. Under construction: pulsing ember ring
        // behind a dimmed sprite. Missing sprite: flat fallback (never blank).
        if let spriteName = theme.buildingSprite(b.type, level: b.level),
           UIImage(named: spriteName) != nil {
            if b.state == "building" {
                let ring = SKShapeNode(rect: CGRect(x: -s / 2 + 4, y: -s / 2 + 4,
                                                    width: s - 8, height: s - 8),
                                       cornerRadius: s * 0.18)
                ring.fillColor = .clear
                ring.strokeColor = UIColor(theme.primary)
                ring.lineWidth = 2
                ring.run(SKAction.repeatForever(SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.55, duration: 0.7),
                    SKAction.fadeAlpha(to: 1.0, duration: 0.7),
                ])))
                container.addChild(ring)
            }
            let sprite = SKSpriteNode(imageNamed: spriteName)
            let dim = max(sprite.size.width, sprite.size.height)
            if dim > 0 { sprite.setScale((s * 0.92) / dim) }
            if b.state == "building" { sprite.alpha = 0.55 }
            container.addChild(sprite)
        } else {
            let bg = SKShapeNode(rect: CGRect(x: -s / 2 + 4, y: -s / 2 + 4, width: s - 8, height: s - 8),
                                 cornerRadius: s * 0.18)
            if b.state == "building" {
                bg.fillColor = UIColor(theme.surface2)
                bg.strokeColor = UIColor(theme.primary)
                bg.lineWidth = 2
                let pulse = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.55, duration: 0.7),
                    SKAction.fadeAlpha(to: 1.0, duration: 0.7),
                ])
                bg.run(SKAction.repeatForever(pulse))
            } else {
                let gradColors: [UIColor] = b.type == .citadel
                    ? [UIColor(theme.primary), UIColor(theme.primaryDeep)]
                    : [UIColor(theme.surface2), UIColor(theme.surface)]
                bg.fillColor = gradColors[0]
                bg.strokeColor = UIColor(theme.primary).withAlphaComponent(0.35)
                bg.lineWidth = 1.5
            }
            container.addChild(bg)

            // Glyph from the theme's SF Symbol name.
            if let img = UIImage(systemName: def.icon),
               let cg = img.cgImage {
                let tex = SKTexture(cgImage: cg)
                let glyph = SKSpriteNode(texture: tex)
                glyph.setScale((s * 0.42) / tex.size().width)
                glyph.color = UIColor(b.type == .citadel ? theme.text : theme.primary)
                glyph.colorBlendFactor = 0.9
                container.addChild(glyph)
            }
        }

        // Level pips
        if b.level > 0 {
            let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
            label.text = "\(b.level)"
            label.fontSize = s * 0.22
            label.fontColor = UIColor(theme.gold)
            label.position = CGPoint(x: s * 0.28, y: -s * 0.34)
            container.addChild(label)
        }
        if b.type == .citadel {
            let glow = SKShapeNode(circleOfRadius: s * 0.52)
            glow.fillColor = .clear
            glow.strokeColor = UIColor(theme.primary).withAlphaComponent(0.5)
            glow.lineWidth = 3
            glow.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.scale(to: 1.08, duration: 1.2),
                SKAction.scale(to: 1.0, duration: 1.2),
            ])))
            container.addChild(glow)
        }
        return container
    }

    // MARK: - Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        for node in nodes(at: p) {
            if let name = node.name, name.hasPrefix("slot:"),
               let slot = Int(name.dropFirst(5)) {
                onTapSlot?(slot)
                return
            }
            // Taps on a building land on its children; walk up to the tile.
            var parent = node.parent
            while parent != nil {
                if let n = parent?.name, n.hasPrefix("slot:"),
                   let slot = Int(n.dropFirst(5)) {
                    onTapSlot?(slot)
                    return
                }
                parent = parent?.parent
            }
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        buildGrid()
    }
}

// MARK: - SwiftUI wrapper

struct CitySceneView: UIViewRepresentable {
    @ObservedObject var game: GameState
    var onTapSlot: (Int) -> Void

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.preferredFramesPerSecond = 30
        let scene = CityScene()
        scene.scaleMode = .resizeFill
        scene.onTapSlot = onTapSlot
        context.coordinator.scene = scene
        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        if let scene = context.coordinator.scene, let snap = game.snapshot {
            scene.refresh(buildings: snap.buildings, theme: .active)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var scene: CityScene?
    }
}
