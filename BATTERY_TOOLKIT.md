# Analyse de Battery-Toolkit (mhaeuser/Battery-Toolkit)

## Architecture

Battery-Toolkit utilise une **architecture trois processus** communiquant par XPC :

```
BatteryToolkit (App)              ← UI menu bar, settings
    ↕ XPC
BatteryToolkitService             ← Prompts admin (AuthorizationRef)
    ↕ XPC (Mach service, privilegié)
me.mhaeuser.batterytoolkitd       ← Daemon root via launchd
    - Accès SMC direct (IOKit)
    - Monitoring power events
    - Contrôle charge + LED
    - Gestion sleep
```

Le daemon tourne en root, éliminant le besoin de `sudo` ou de sudoers.

---

## Enseignements clés

### 1. SMC direct via IOKit (pas de binaire `smc`)

Le changement le plus impactant. Au lieu de `Process()` + `sudo -n /usr/local/bin/smc`, il ouvre directement le driver SMC :

```swift
let smc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
var connect: io_connect_t = IO_OBJECT_NULL
IOServiceOpen(smc, get_mach_task_self(), 1, &connect)
IOConnectCallMethod(connect, kSMCUserClientOpen, nil, 0, nil, 0, nil, nil, nil, nil)
```

Puis lit/écrit via `IOConnectCallStructMethod` avec une struct `SMCParamStruct` de 80 bytes (selector 2 = `kSMCHandleYPCEvent`).

**Avantages** : zéro dépendance externe, pas de process spawning, pas de sudoers, plus rapide.
**Contrainte** : nécessite les droits root pour ouvrir le user client SMC.

### 2. Write verification

Après chaque écriture SMC, relecture pour confirmer :

```swift
static func writeKey(key: Key, bytes: [UInt8]) -> Bool {
    var inputStruct = SMCParamStruct.writeKey(key: key, bytes: bytes)
    let outputStruct = callSMCFunctionYPC(params: &inputStruct)
    // Relecture défensive — le driver SMC peut mentir sur le succès
    let readValue = readKey(key: key, dataSize: bytes.count)
    guard let readValue else { return outputStruct != nil }
    return readValue == bytes
}
```

### 3. Multi-key fallback dynamique

Deux jeux de clés testés au démarrage, le premier supporté est utilisé :

| Opération | Clé primaire | Clé fallback |
|---|---|---|
| Charge on/off | `CHTE` (ui32, 4 bytes) | `CH0C` (hex_, 1 byte) |
| Adapter on/off | `CHIE` (hex_, 1 byte) | `CH0J` (ui8, 1 byte) |

```swift
static func supported() -> Bool {
    chargeKey = chargeKeys.firstIndex { SMCComm.keySupported(keyInfo: $0.keyInfo) }
    adapterKey = adapterKeys.firstIndex { SMCComm.keySupported(keyInfo: $0.keyInfo) }
    return chargeKey != nil && adapterKey != nil
}
```

**Note** : Les valeurs diffèrent légèrement de battery CLI :
- `CH0C`: `0x00` enable, `0x01` disable (pas `0x02`)
- `CH0J`: `0x00` enable, `0x20` disable (pas `0x01`)

### 4. Anti-micro-charge

Quand le Mac passe sur batterie, la charge est **immédiatement désactivée** :

```swift
private static func handleLimitedPowerGuarded() {
    if drawingUnlimitedPower() {
        registerPercentChangedHandler()
    } else {
        unregisterPercentChangedHandler()
        // Désactive la charge AVANT qu'on rebranche
        disableCharging()
    }
}
```

Quand l'utilisateur rebranche ensuite, la charge ne démarre pas avant que le logiciel ait vérifié le %. Empêche les pulses de charge parasites.

### 5. Sleep prevention pendant les transitions

Mécanisme reference-counted :

```swift
private static var disabledCounter: UInt8 = 0

static func disable() {
    disabledCounter += 1
    guard disabledCounter == 1 else { return }
    setSleepDisabledIOPMValue(value: kCFBooleanTrue)
}

static func restore() {
    disabledCounter -= 1
    guard disabledCounter == 0 else { return }
    restorePrevious()
}
```

Utilisé pour empêcher le Mac de dormir pendant un changement d'état SMC. Plusieurs sous-systèmes peuvent indépendamment demander la prévention du sleep.

L'état précédent du sleep est persisté dans UserDefaults immédiatement (pas au shutdown) car le service IOKit peut déjà être teardown au moment du SIGTERM.

### 6. Battery reading via packed bits

Au lieu de `IOPSCopyPowerSourcesInfo`, utilise les bits compactés de darwin notify :

```swift
notify_register_check("com.apple.system.powersources.percent", &token)
var bits: UInt64 = 0
notify_get_state(token, &bits)

let percent = UInt8(bits & 0xFF)
let isCharging = (bits & (1 << 17)) != 0
let isFullyCharged = (bits & (1 << 21)) != 0
let externalPower = (bits & (1 << 16)) != 0
```

Plus léger qu'un dictionnaire IOPowerSources, mais c'est une API privée.

### 7. MagSafe LED étendue

| Valeur ACLC | Effet |
|---|---|
| `0x00` | Contrôle système (défaut macOS) |
| `0x01` | LED éteinte |
| `0x03` | Vert fixe |
| `0x04` | Orange fixe |
| `0x06` | Orange clignotement lent |
| `0x07` | Orange clignotement rapide |
| `0x19` | Orange blink-off |

Synchronisé avec l'état :
- 100% → vert
- Charge désactivée (limite) → orange fixe
- En charge → orange slow blink
- Adapter désactivé → LED éteinte

### 8. Gestion SIGTERM + restore on exit

```swift
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    BTPowerEvents.exit()  // Restore charging + adapter + LED
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)
```

Restore les défauts à la sortie sauf pendant une mise à jour du daemon (flag `updating`).

### 9. Modes de charge

Trois modes au lieu de juste on/off :
- **standard** : hystérésis normale (min/max)
- **toLimit** : force la charge jusqu'au max, puis stop
- **toFull** : force la charge à 100%, puis retour en mode standard

### 10. Charging ≠ Power Adapter

Deux opérations indépendantes :
- **Disable charging** : la batterie reste au niveau actuel, le secteur alimente le Mac
- **Disable power adapter** : le Mac tourne sur batterie même branché (force le drain)

---

## Plan d'implémentation pour Better Battery

### Phase 1 : SMC direct (remplace SMCController + Setup)

**Impact** : élimine la dépendance `/usr/local/bin/smc` + sudoers. Simplifie énormément le first-run.

1. Créer `Sources/SMCComm.swift` — accès IOKit direct au SMC
   - `SMCParamStruct` (C bridging header ou reproduction en Swift)
   - `open()` / `close()` via IOServiceOpen/IOServiceClose
   - `readKey()` / `writeKey()` via IOConnectCallStructMethod
   - Write verification (relecture après écriture)

2. Créer `Sources/SMCKeys.swift` — définition des clés et détection
   - Struct `SMCKeyDef { name, type, size, enableValue, disableValue }`
   - Probe `CHTE`/`CH0C` pour charge, `CHIE`/`CH0J` pour adapter
   - `supported() -> Bool` avec fallback automatique

3. Réécrire `Sources/SMCController.swift` — utilise SMCComm au lieu de Process()
   - Mêmes fonctions publiques : `enableCharging()`, `disableCharging()`, `setMagSafeLED()`
   - Ajouter `enablePowerAdapter()` / `disablePowerAdapter()`

4. Supprimer `Sources/Setup.swift` — plus besoin de vérifier smc/sudoers
   - Le first-run se réduit à vérifier que le SMC est accessible
   - Si pas root → demander les droits admin une seule fois

**Difficulté** : l'accès SMC direct nécessite root. Options :
- (a) App lancée via `sudo` (simple mais laid)
- (b) Helper tool privilégié via SMJobBless/SMAppService (propre, comme Battery-Toolkit)
- (c) Garder l'approche sudoers mais avec le binaire intégré (compromis)

**Recommandation** : option (b) pour le long terme, mais commencer par (a) ou (c) pour un MVP.

### Phase 2 : Anti-micro-charge + Sleep prevention

1. Dans `ChargeLimiter.swift`, ajouter la logique anti-micro-charge :
   ```
   quand isPluggedIn passe de true → false :
       disableCharging()  // Préventivement
   ```

2. Créer `Sources/SleepManager.swift` :
   - `IORegisterForSystemPower` pour wake events
   - `IOPMAssertionCreateWithName` pour empêcher le sleep
   - Reference counting (disable/restore)
   - Persist previous state dans UserDefaults

3. Dans `ChargeLimiter`, wrapper les transitions avec sleep prevention :
   ```
   SleepManager.disable()
   smc.disableCharging()
   // ... vérifier écriture
   SleepManager.restore()
   ```

### Phase 3 : Battery reading amélioré

1. Ajouter `notify_register_dispatch` pour `kIOPSNotifyPowerSource` en plus de `IOPSNotificationCreateRunLoopSource`
   - Callback séparé pour les changements de source d'alimentation

2. Optionnel : utiliser les packed battery bits au lieu de IOPowerSources
   - Plus rapide mais API privée (risque de casse avec les mises à jour macOS)
   - Garder IOPowerSources en fallback

### Phase 4 : LED + modes étendus

1. Étendre l'enum `MagSafeLEDColor` :
   ```swift
   case system, off, green, orange, orangeSlowBlink, orangeFastBlink
   ```

2. Synchroniser la LED avec l'état :
   - En charge → orange slow blink
   - Limite active → orange fixe
   - 100% → vert
   - Adapter désactivé → off

3. Ajouter le mode "Charge to Full" temporaire dans le menu

### Phase 5 : Robustesse

1. SIGTERM handler pour restore propre à la sortie
2. Persister l'état de charge dans UserDefaults (crash recovery)
3. Write verification sur toutes les écritures SMC
4. Wake-from-sleep refresh : relire l'état complet et réappliquer

---

## Décision architecturale : accès root

L'accès SMC direct nécessite root. Trois approches possibles :

### Option A : Helper privilégié (SMAppService)
```
BetterBattery.app (user)  ←XPC→  BetterBatteryDaemon (root)
```
- **Pro** : propre, sécurisé, standard macOS
- **Con** : complexe (XPC, code signing, provisioning profile), nécessite Xcode

### Option B : App complète en root via LaunchDaemon
```
/Library/LaunchDaemons/com.betterbattery.plist → lance l'app en root
```
- **Pro** : simple, un seul binaire
- **Con** : l'UI tourne en root (pas idéal), complexité LaunchDaemon

### Option C : Garder smc + sudoers (actuel)
```
App (user) → sudo -n /usr/local/bin/smc
```
- **Pro** : déjà implémenté, simple
- **Con** : dépendance externe, sudoers fragile, process spawning toutes les 60s

### Option D : setuid helper minimaliste
```
BetterBattery.app (user) → ./smc-helper (setuid root, intégré)
```
- **Pro** : pas de dépendance externe, pas de XPC
- **Con** : setuid est déprécié par Apple, problèmes de sécurité

**Recommandation** : rester sur l'option C pour le MVP actuel, migrer vers A quand on passe sur un projet Xcode.
