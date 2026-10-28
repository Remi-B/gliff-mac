# Environnement de build macOS local

## État actuel

La VM QEMU/KVM est installée et démarre sur cet hôte : **macOS Sequoia 15.8.2**,
build **24H232**, vérifié par SSH dans l'invité installé. Le compte administrateur
local **`builder`** est créé, SSH par clé fonctionne sur `localhost:2222` et
**`/Users/builder/Shared`** contient l'archive Apple et l'installateur Xcode.
Le fuseau est réglé sur **Europe/Paris** et la veille
de la VM est désactivée pour les builds. La récupération utilisée au départ était
macOS 15.4.1 (24E263), distincte de la version finalement installée.

**Xcode 16.4, build 16F6, est installé et sélectionné** dans
`/Applications/Xcode_16.4.app/Contents/Developer`. Les composants de premier
lancement sont installés. Vérifications réelles dans l'invité :

- `xcodebuild -version` : Xcode 16.4 / 16F6.
- `xcrun swift --version` : Apple Swift 6.1.2, cible x86_64.
- SDK macOS sélectionné : **15.5**.
- `pkgutil --check-signature` : archive reconnue comme **signed Apple Software**.
- `codesign --verify --deep --strict` : application valide sur disque et conforme
  à son exigence de signature Apple.
- Rust **1.90.0**, rustfmt, Clippy et cibles `aarch64-apple-darwin` /
  `x86_64-apple-darwin` installés dans le compte `builder`.

La capture réelle `~/.local/share/gliff-mac-vm/evidence/desktop-xcode.png`
montre le bureau, le Terminal avec ces versions et l'archive dans `~/Shared/`.
Les résultats détaillés de la CLI sont conservés dans `evidence/cli-status.txt`.
La capture antérieure `desktop-macos-before-xcode.png` reste un état historique.

Le bootstrap et le script complet de vérification du projet ont également réussi
dans l'invité : formatage, Clippy, harnais de tests Rust, contrôles des deux cibles
Apple, package Swift et **build universel Xcode**. `lipo` confirme les tranches
**x86_64 / arm64**, toutes deux avec une cible minimale **macOS 13.0**. Le socle
de l'app se lance dans l'invité Intel. Les détails figurent dans
[le compte rendu de la tâche 01](../setup-project-structure/implementation-record.md).

## Utilisation de l'environnement installé

La VM est laissée en fonctionnement. Sur l'hôte :

```bash
scripts/vm/console.sh
scripts/vm/ssh.sh 'sw_vers'
```

L'archive **16.4** est déjà présente sur l'hôte dans
`~/Downloads/Xcode_16.4.xip` et dans l'invité dans `~/Shared/Xcode_16.4.xip`.
Les SHA-256 des deux copies correspondent :
`2dbf65ba28fb85b34e72c14c529a42d5c3189ab0f11fb29fdebd5f4ee6c87900`.
Sa taille exacte est de **3 036 085 732 octets**.

Pour réinstaller à partir d'une nouvelle archive Apple autorisée :

```bash
scripts/vm/share-xcode.sh "$HOME/Downloads/Xcode_16.4.xip"
scripts/vm/ssh.sh
```

Puis, dans la session macOS :

```bash
bash "$HOME/Shared/install-xcode.sh"
```

`scripts/vm/build.sh` lancé depuis l'hôte
effectue la synchronisation et les vérifications du projet. Après un redémarrage
de l'hôte, relancer d'abord `scripts/vm/start.sh` **sans** `--install`.

## Adaptations du guide fourni

Le [document d'origine](base-specification.md) est conservé sans modification.
L'implémentation tient compte des observations suivantes :

- Hôte réel : **MacBookPro15,1**, Intel i7-8750H, 12 threads, **16 Gio** de RAM,
  **Omarchy 4.0.6 / Arch Linux**, accès utilisateur à `/dev/kvm`.
- Allocation : **4 vCPU**, **8 Gio** de RAM, disque **128 Gio sparse**. La machine
  avait environ 164 Gio libres au démarrage ; ne pas allouer 16 Gio à cette VM.
  Le disque sparse consomme progressivement de l'espace réel : surveiller `df`.
- QEMU **11.1.2** est préparé dans un runtime utilisateur à partir des paquets du
  miroir configuré sur l'hôte. Leurs SHA-256 sont vérifiés contre les métadonnées
  locales du gestionnaire de paquets. Aucun paquet système ni service privilégié
  n'a été installé. Cette procédure dépend de cet hôte Arch, de ses bibliothèques
  déjà installées et de son miroir ; ce n'est pas un binaire autonome universel.
- Le firmware et OpenCore viennent d'un commit épinglé de
  [OSX-KVM](https://github.com/kholia/OSX-KVM), avec une copie privée de la NVRAM.
  Le démarrage observé n'a pas nécessité de changer `kvm.ignore_msrs` sur l'hôte.
- Une console graphique reste disponible via VNC/noVNC même avec `-display none`.
  `-nographic` seul ne remplace ni l'installation graphique ni une capture du bureau.
- SSH, VNC et WebSocket écoutent uniquement sur **127.0.0.1**. Le guide initial
  exposait implicitement le transfert SSH sur toutes les interfaces.
- Le partage `virtio-fs` de l'exemple n'est pas présumé fonctionnel dans cet invité.
  Les sources/builds seront conservés sur APFS natif et synchronisés via SSH/rsync.
  L'archive Xcode sera copiée dans **`~/Shared/` de l'invité**, comme demandé.

La cible reste **Xcode 16.4**, compatible avec le socle déjà retenu pour l'app.
[Apple documente les versions macOS prises en charge](https://developer.apple.com/xcode/system-requirements).
Les seuls Command Line Tools ne suffisent pas au build du projet Xcode.

## Emplacement des données

État local, en dehors du dépôt :

```text
~/.local/share/gliff-mac-vm/
  runtime/                  # QEMU, modules, bibliothèques et firmware des paquets
  cache/qemu-packages/      # archives vérifiées
  runtime-packages.json     # versions, URLs et SHA-256
  OSX-KVM/                  # source tierce épinglée
  noVNC/                    # console web épinglée
  BaseSystem.dmg            # récupération Apple originale
  BaseSystem.chunklist      # liste de blocs/signature Apple
  BaseSystem.img            # conversion raw pour le démarrage
  macos.qcow2               # disque de l'invité : ne pas supprimer/réinitialiser
  OVMF_VARS.fd              # NVRAM privée et persistante
  id_ed25519                # clé SSH privée locale, mode 0600
  builder-password          # mot de passe généré pour le NOUVEAU compte de VM
  qmp.sock                  # contrôle de cette VM uniquement
  logs/
  recovery/verification.json
  evidence/                 # captures réelles ; pas d'image de preuve fabriquée
```

Le dossier d'état est limité à son propriétaire (0700). Ne jamais copier les clés,
mots de passe, disques, archives Xcode ou données d'état dans Git. Les sources des
scripts et cette procédure sont les seuls éléments à versionner.

## Préparation et lancement

Sur cet hôte Arch, avec Git, Python 3.11+, `pacman`, `tar`, zstd et un accès KVM :

```bash
python3 scripts/vm/prepare-runtime.py
python3 scripts/vm/prepare-media.py
python3 scripts/vm/prepare-access.py
scripts/vm/start.sh --install
scripts/vm/qmp.py status
```

`prepare-media.py` vérifie la signature de la liste Apple et chaque bloc de l'image,
y compris quand l'affichage de progression du téléchargeur tiers échoue sans TTY.
Une image existante incorrecte est rejetée. Le disque macOS et la NVRAM existants
ne sont jamais recréés par cette commande.

Les révisions épinglées sont :

- OSX-KVM : `4c378a4b5e0b219783683012bec680325eb40719`.
- noVNC 1.6.0 : `a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820`.

Pour exposer la console web locale comme service utilisateur persistant pendant
la session de l'hôte, lancer :

```bash
scripts/vm/console.sh
```

Puis ouvrir :
`http://127.0.0.1:6090/vnc.html?host=127.0.0.1&port=6080&autoconnect=1&resize=scale&encrypt=0`.
Un client VNC peut aussi se connecter à `127.0.0.1:5909`.
Le service se contrôle avec `systemctl --user status gliff-mac-console` ou
`systemctl --user stop gliff-mac-console`. Il n'est pas configuré pour démarrer
automatiquement après un redémarrage de l'hôte.

Après installation, démarrer avec `scripts/vm/start.sh` sans `--install` pour
retirer le média de récupération. `scripts/vm/qmp.py powerdown` demande un arrêt
normal de l'invité ; attendre son arrêt avant de manipuler les disques.

## Compte de build et archive Xcode

Le compte local `builder` et Remote Login sont maintenant configurés. Sur une
nouvelle installation, créer ce compte puis installer uniquement la clé publique
`id_ed25519.pub` dans son `~/.ssh/authorized_keys`. Les clés privées restent sur
l'hôte. Utiliser le fichier `known_hosts` propre à cette VM : les changements de
clé inattendus doivent interrompre la connexion.

`prepare-access.py` génère les accès du nouveau compte de build dans le dossier
d'état privé, sans afficher leurs valeurs ni remplacer des accès existants. Son
script `bootstrap-public/guest-setup.sh` ne contient que la clé publique et les
commandes de configuration ; après création du compte, il prépare `~/Shared/` et
active SSH avec une authentification administrateur dans l'invité. Le mot de passe
généré concerne uniquement cette nouvelle VM, jamais le compte de l'hôte ou Apple.
Il reste disponible pour une connexion graphique dans le fichier privé
`~/.local/share/gliff-mac-vm/builder-password` de l'hôte ; sa valeur n'est pas copiée
dans le dépôt. Le clavier invité est identifié **ANSI / U.S.**.

L'accès SSH préparé évite de modifier la configuration SSH personnelle de l'hôte :

```bash
scripts/vm/ssh.sh
scripts/vm/ssh.sh 'sw_vers'
```

Télécharger **Xcode 16.4** depuis le
[portail Apple Developer](https://developer.apple.com/download/all/?q=Xcode%2016.4)
avec une session autorisée, conserver l'archive sur l'hôte, puis :

```bash
scripts/vm/share-xcode.sh /chemin/local/Xcode_16.4.xip
```

L'aperçu T3 présent sur cette machine limite les téléchargements conservés à
1 Gio : son transfert initial de cette archive de 2,83 Gio a été supprimé après
réception. Pour une reprise manuelle, utiliser le navigateur de l'hôte pour
enregistrer l'archive directement dans `Downloads`, puis le script ci-dessus.

Le transfert reprend les fichiers partiels et compare les SHA-256 hôte/invité.
L'archive arrive dans `~/Shared/Xcode_16.4.xip`. La vérification explicite avec
`pkgutil --check-signature`, l'extraction avec `xip --expand`,
l'installation dans `/Applications`, la sélection de Xcode et les composants
de premier lancement sont automatisés par `scripts/vm/install-xcode.sh`, à exécuter
dans macOS. Le script vérifie également la version de l'application extraite avant
de la sélectionner et contrôle la signature de l'application avec
`codesign --verify --deep --strict -R='anchor apple'`. Ne pas substituer une
archive tierce non vérifiée à la distribution Apple.

L'installateur est déjà disponible dans `~/Shared/install-xcode.sh` de l'invité.
Après transfert de l'archive, ouvrir la session avec `scripts/vm/ssh.sh` et lancer
`bash ~/Shared/install-xcode.sh`. Le compte `builder` demande son mot de passe
administrateur local pour la sélection et les composants de premier lancement.

## Vérifications de preuve et de build

Pour reproduire les vérifications des outils dans l'invité :

```bash
sw_vers
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -showsdks
```

Puis exécuter le bootstrap/check du projet sur une copie native APFS contenant
son index Git et le sous-module épinglé. La synchronisation transporte également
l'histoire locale, pour pouvoir construire une branche et ses modifications
avant leur publication sur GitHub.

Les scripts préparés pour cette étape sont :

```bash
scripts/vm/sync-project.sh  # histoire locale + sources courantes vers APFS invité
scripts/vm/build.sh         # synchronisation, contrôle Xcode, bootstrap et checks
```

Le répertoire invité `~/Projects/gliff-mac` est une copie de build gérée par le
script : son état Git est remis au commit exporté avant la synchronisation des
sources courantes. Ne pas y travailler manuellement. Un répertoire préexistant
sans marqueur de gestion est refusé ; les métadonnées Git et les caches de build
invités sont préservés par rsync. Les journaux locaux sont conservés dans
`~/.local/share/gliff-mac-vm/logs/project-build.log` ; les versions et la capture
réelle se trouvent dans le dossier voisin `evidence/`.

La capture finale doit montrer le vrai bureau de la VM et un Terminal affichant
au minimum `sw_vers` et `xcodebuild -version`. Elle peut être prise directement
sur le framebuffer de la VM :

```bash
scripts/vm/qmp.py screenshot "$HOME/.local/share/gliff-mac-vm/evidence/desktop-xcode.png"
```

Une capture du menu OpenCore, de Recovery, de l'installateur ou de Command Line
Tools ne constitue pas cette preuve. La compilation x86_64 dans cette VM n'établit
pas la validation d'exécution sur matériel Apple Silicon.
Le GPU virtuel utilisé n'établit pas non plus la validation de l'accélération
Metal/VideoToolbox sur un Mac physique : cette VM sert d'abord aux builds.
