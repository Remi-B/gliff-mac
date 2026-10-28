# Spécification Technique & Guide d'Implémentation : Port macOS du Client Gliff

## 1. Vue d'Ensemble & Architecture

### 1.1 Objectif du Projet
Développer un client macOS natif pour **Gliff** (`omacom/gliff`) permettant de se connecter à une session hôte **Hyprland** exécutée sur une machine **Arch Linux** distante via un tunnel SSH sécurisé.

### 1.2 Architecture Globale
Le projet adopte une **architecture hybride Swift/Rust** :

```
 ┌───────────────────────────────────────────────────────────────┐
 │                       Mac (Client macOS)                      │
 │                                                               │
 │   ┌───────────────────────────────────────────────────────┐   │
 │   │                       SwiftUI                         │   │
 │   │        (Interface utilisateur, Fenêtrage, UI)         │   │
 │   └──────────────────────────┬────────────────────────────┘   │
 │                              │                                │
 │   ┌──────────────────────────▼────────────────────────────┐   │
 │   │          Metal / VideoToolbox / AVSampleBuffer        │   │
 │   │          (Rendu d'affichage H.264 & Décodage)         │   │
 │   └──────────────────────────▲────────────────────────────┘   │
 │                              │ (Décodage / Trames H.264)      │
 │   ┌──────────────────────────┴────────────────────────────┐   │
 │   │                     UniFFI (Bridge)                   │   │
 │   └──────────────────────────▲────────────────────────────┘   │
 │                              │ (Appels FFI Rust / Swift)      │
 │   ┌──────────────────────────┴────────────────────────────┐   │
 │   │                  Gliff Core (Rust)                    │   │
 │   │    (Transport SSH, CBOR, Protocoles de contrôle)      │   │
 │   └──────────────────────────┬────────────────────────────┘   │
 └──────────────────────────────┼────────────────────────────────┘
                                │ Tunnel SSH (H.264 Stream & Controls)
 ┌──────────────────────────────▼────────────────────────────────┐
 │                      Machine Arch Linux                       │
 │                                                               │
 │   ┌───────────────────────────────────────────────────────┐   │
 │   │                 gliff-server (Linux)                  │   │
 │   │         (Capture Hyprland / Encapsulation H.264)      │   │
 │   └───────────────────────────────────────────────────────┘   │
 └───────────────────────────────────────────────────────────────┘
```

---

## 2. Étape 1 : Fork et Préparation du Dépôt Rust

### 2.1 Fork & Clonage
1. Forkez le dépôt `https://github.com/omacom/gliff` sur votre compte GitHub.
2. Clonez votre fork localement sur votre Mac :
   ```bash
   git clone https://github.com/<votre-user>/gliff.git
   cd gliff
   ```

### 2.2 Reconfiguration du Workspace Cargo (`Cargo.toml`)
Ajoutez un sous-module dédié au bridge macOS (ex: `gliff-mac-core`). Dans le fichier `Cargo.toml` racine :

```toml
[workspace]
members = [
    "gliff-server",
    "gliff-core",
    "gliff-mac-core",
]
resolver = "2"
```

### 2.3 Création du Crate `gliff-mac-core`
```bash
cargo new --lib gliff-mac-core
```

Dans `gliff-mac-core/Cargo.toml` :
```toml
[package]
name = "gliff-mac-core"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib", "cdylib"]

[dependencies]
uniffi = { version = "0.28", features = ["build", "cli"] }
tokio = { version = "1.0", features = ["full"] }
# Dépendances internes gliff
# gliff-core = { path = "../gliff-core" }

[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

Dans `gliff-mac-core/build.rs` :
```rust
fn main() {
    uniffi::generate_scenarios();
}
```

---

## 3. Étape 2 : Définition de l'Interface FFI (Rust - UniFFI)

### 3.1 Implémentation du Bridge (`gliff-mac-core/src/lib.rs`)

```rust
use std::sync::Arc;

uniffi::setup_scenarios!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum GliffError {
    #[error("Erreur de connexion SSH: {reason}")]
    SshError { reason: String },
    #[error("Erreur de décodage ou de protocole: {reason}")]
    ProtocolError { reason: String },
}

pub trait FrameCallback: Send + Sync {
    fn on_h264_packet(&self, packet: Vec<u8>, is_keyframe: bool, timestamp: u64);
}

#[derive(uniffi::Object)]
pub struct GliffSession {
    // État interne de session tokio / ssh
}

#[uniffi::export]
impl GliffSession {
    #[uniffi::constructor]
    pub fn new(host: String, port: u16, username: String) -> Arc<Self> {
        Arc::new(Self {})
    }

    pub fn start(&self, callback: Box<dyn FrameCallback>) -> Result<(), GliffError> {
        // Initialiser la connexion SSH vers gliff-server sur Arch Linux
        // Transmettre les paquets H.264 reçus au callback Swift
        Ok(())
    }

    pub fn send_mouse_event(&self, x: f32, y: f32, button_mask: u32) {
        // Envoi des événements pointeur vers le serveur Arch Linux
    }

    pub fn send_key_event(&self, key_code: u32, pressed: bool) {
        // Envoi des événements clavier
    }

    pub fn stop(&self) {
        // Arrêt propre de la session
    }
}
```

---

## 4. Étape 3 : Script de Compilation et Génération des Bindings Swift

Créez le script `build_mac.sh` à la racine du dépôt pour automatiser la compilation Cross-Apple (Apple Silicon & Intel) et la création du framework XCFramework :

```bash
#!/usr/bin/env bash
set -e

# Targets pour Mac
TARGET_ARM="aarch64-apple-darwin"
TARGET_INTEL="x86_64-apple-darwin"

rustup target add $TARGET_ARM $TARGET_INTEL

echo "=== Compilation Rust pour macOS ==="
cargo build --release --target $TARGET_ARM -p gliff-mac-core
cargo build --release --target $TARGET_INTEL -p gliff-mac-core

echo "=== Génération des liaisons Swift UniFFI ==="
cargo run -p uniffi-bindgen generate \
    --library target/$TARGET_ARM/release/libgliff_mac_core.dylib \
    --language swift \
    --out-dir macos-bindings/

echo "=== Création de la bibliothèque universelle ==="
mkdir -p target/universal-apple-darwin/release/
lipo -create \
    target/$TARGET_ARM/release/libgliff_mac_core.a \
    target/$TARGET_INTEL/release/libgliff_mac_core.a \
    -output target/universal-apple-darwin/release/libgliff_mac_core.a

echo "=== Packaging XCFramework ==="
rm -rf macos-bindings/GliffCore.xcframework
xcodebuild -create-xcframework \
    -library target/universal-apple-darwin/release/libgliff_mac_core.a \
    -headers macos-bindings/ \
    -output macos-bindings/GliffCore.xcframework

echo "Build terminé avec succès !"
```

---

## 5. Étape 4 : Création & Configuration du Projet Xcode

1. Ouvrez Xcode et créez une nouvelle application : **App > macOS (AppKit / SwiftUI)**.
2. Définissez le nom du projet : `GliffMac`.
3. **Importation du Bridge** :
   * Glissez-déposez `macos-bindings/GliffCore.xcframework` dans le projet Xcode.
   * Glissez-déposez le fichier Swift généré (ex: `gliff_mac_core.swift`) dans votre arborescence source Xcode.
4. **Réglages du Target Xcode (`Build Settings`)** :
   * **Framework Search Paths** : ajoutez le chemin vers `macos-bindings/`.
   * **Import Paths** : ajoutez le dossier des en-têtes C d'UniFFI générés.
   * **App Sandbox** (dans *Signing & Capabilities*) :
     * Activez **Incoming Connections (Server)** et **Outgoing Connections (Client)**.

---

## 6. Étape 5 : Implémentation macOS Native (SwiftUI & VideoToolbox)

### 6.1 Moteur de Décodage VideoToolbox (`H264Decoder.swift`)

```swift
import Foundation
import VideoToolbox
import CoreMedia

class H264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    var onFrameDecoded: ((CVImageBuffer) -> Void)?

    func decode(packet: Data, isKeyframe: Bool) {
        // Extraction SPS/PPS et initialisation de VTDecompressionSession
        // Conversion du paquet en CMBlockBuffer et VTDecompressionSessionDecodeFrame
    }
}
```

### 6.2 Vue d'Affichage Metal / AVSampleBuffer (`RemoteDesktopView.swift`)

```swift
import SwiftUI
import AVKit

struct RemoteDesktopView: NSViewRepresentable {
    @ObservedObject var viewModel: GliffViewModel

    func makeNSView(context: Context) -> AVSampleBufferDisplayLayerHostView {
        let view = AVSampleBufferDisplayLayerHostView()
        context.coordinator.setupInputHandling(for: view)
        return view
    }

    func updateNSView(_ nsView: AVSampleBufferDisplayLayerHostView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSViewController {
        var viewModel: GliffViewModel

        init(viewModel: GliffViewModel) {
            self.viewModel = viewModel
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setupInputHandling(for view: NSView) {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved, .leftMouseDown, .leftMouseUp]) { event in
                self.viewModel.handleNSEvent(event)
                return nil
            }
        }
    }
}

class AVSampleBufferDisplayLayerHostView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
```

### 6.3 Interface SwiftUI Principale (`ContentView.swift`)

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = GliffViewModel()

    var body: some View {
        VStack {
            if viewModel.isConnected {
                RemoteDesktopView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 20) {
                    Text("Gliff macOS Client")
                        .font(.largeTitle)
                        .bold()

                    Form {
                        TextField("Hôte Arch Linux (IP / Nom)", text: $viewModel.host)
                        TextField("Utilisateur SSH", text: $viewModel.username)
                        SecureField("Mot de passe / Clé SSH", text: $viewModel.password)
                    }
                    .frame(width: 300)

                    Button("Se Connecter à Hyprland") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}
```

---

## 7. Plan de Phase et Recette de Validation

| Phase | Description | Objectif de Validation |
| :--- | :--- | :--- |
| **Phase 1** | Configuration Crate `gliff-mac-core` & UniFFI | Génération réussie du `.xcframework` via script. |
| **Phase 2** | Projet Xcode & Authentification SSH | Connexion SSH réussie depuis l'app Mac vers Arch Linux. |
| **Phase 3** | Integration VideoToolbox | Affichage fluide du flux vidéo H.264 généré par `gliff-server`. |
| **Phase 4** | Mappings d'Événements | Contrôle complet du pointeur et du clavier macOS sur Hyprland. |
| **Phase 5** | Raccourcis macOS & Pressec-papier | Copier/Coller partagé et gestion du mode plein écran. |