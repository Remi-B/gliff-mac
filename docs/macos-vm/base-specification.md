# Document de Spécifications Techniques : Virtualisation macOS sous Linux pour CI/CD

## 1. Vue d'ensemble et Objectifs
L'objectif de cette configuration est d'exécuter une machine virtuelle macOS sous un hôte Linux (Ubuntu/Omakub sur MacBook Pro T2) pour servir d'environnement de build automatisé (CI/CD) et de développement avec Xcode sans interface graphique (headless).

---

## 2. Architecture et Composants

### 2.1 Hyperviseur et Émulation
* **Hôte :** Linux (Ubuntu avec Omakub sur MacBook Pro T2).
* **Hyperviseur :** QEMU avec accélération matérielle KVM.
* **Bootloader VM :** OpenCore pour l'émulation du matériel Apple nécessaire à macOS.

### 2.2 Dossier Partagé
* **Dossier Hôte :** `/projects`
* **Technologie de partage :** `virtio-fs` (pour des performances d'E/S optimales).
* **Point de montage Invité (macOS) :** `/Volumes/projects` ou `~/projects` via le système de fichier VIRTIO.

---

## 3. Configuration de la Machine Virtuelle

### 3.1 Ressources Allouées
* **CPU :** Prise en charge des instructions AES-NI et passthrough des cœurs (par ex. `-cpu host`).
* **RAM :** Minimum 8 Go (16 Go recommandés pour des builds Xcode fluides).
* **Réseau :** Interface virtuelle `virtio-net-pci` bridgeée ou NAT avec redirection de ports SSH pour la CI.

### 3.2 Lancement QEMU (Exemple de paramètres clés)
```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 8G \
  -cpu host,kvm=on \
  -smp 4,sockets=1,cores=4,threads=1 \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -chardev socket,id=char0,path=/tmp/vfs-projects.sock \
  -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=projects \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -device ide-hd,bus=sata.0,drive=OpenCoreDrive \
  -drive id=OpenCoreDrive,if=none,snapshot=on,format=qcow2,file=OpenCore.qcow2 \
  -nographic
```

---

## 4. Configuration du Partage de Fichiers (virtio-fs)

1. **Sur l'hôte Linux :**
   Exécuter le démon `virtiofsd` pointant sur le dossier `/projects` :
   ```bash
   sudo /usr/libexec/virtiofsd --socket-path=/tmp/vfs-projects.sock -o shared_dir=/projects
   ```

2. **Sur l'invité macOS :**
   Monter le tag `projects` à l'aide des extensions virtio-fs pour macOS.

---

## 5. Automatisation du Build Xcode (CI/CD)

### 5.1 Mode Headless
La VM s'exécute avec l'option `-nographic` de QEMU. Aucune interface graphique n'est requise après l'initialisation initiale de macOS.

### 5.2 Exécution des Builds
Les builds sont déclenchés via SSH sur le port transféré (ex: `localhost:2222`) depuis la machine hôte ou un runner CI :

```bash
ssh -p 2222 builder@localhost << 'EOF'
  cd /Volumes/projects/mon-projet-app
  xcodebuild -scheme MonScheme -configuration Release build
EOF
```

---

## 6. Avantages de la Configuration
* **Synchronisation instantanée :** Aucun temps perdu à cloner le dépôt dans la VM ; les modifications sur `/projects` sont immédiatement accessibles par `xcodebuild`.
* **Ressources optimisées :** Pas d'overhead graphique grâce au mode headless.
* **Isolation :** L'environnement de build macOS reste confiné et n'impacte pas le système hôte.