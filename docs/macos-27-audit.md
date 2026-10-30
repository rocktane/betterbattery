# Audit de compatibilité macOS 27

Environnement vérifié : macOS 27.0.1 (26A434), Apple Silicon, Xcode 27.2, Swift 6.4.2. Cible minimale conservée : macOS 13. Audit du code de l’application et du helper ; lecture réelle des sources d’alimentation. Aucun changement des réglages d’alimentation ni installation du nouveau helper pendant les tests.

## Diagnostic et corrections effectuées

### Santé de batterie

Le test initial reproduisait exactement le symptôme : `FAIL: macOS 27 snapshot: expected measured health 80%, got 100%`.

Sur le Mac vérifié, `AppleRawMaxCapacity` et `DesignCapacity` ne sont plus présents à la racine de `AppleSmartBattery`. Les capacités sont dans `BatteryData` : `FullChargeCapacity = 4854`, `DesignCapacity = 6075`, `NominalChargeCapacity = 5004`. Les champs racine `CurrentCapacity` et `MaxCapacity` restent normalisés sur 100. Le lecteur ne trouvait pas les capacités et gardait sa valeur par défaut de 100 %.

Le lecteur utilise maintenant les capacités en mAh imbriquées, avec repli sur les anciens champs Apple Silicon. Il ne mélange pas un pourcentage et des mAh. Une mesure absente devient une valeur inconnue affichée « — ». Les capacités invalides sont rejetées et le résultat est plafonné à 100 %.

La santé calculée est une estimation brute d’environ 80 %. Informations système indique ici 81 % : le calcul Apple ne se résume pas nécessairement au rapport instantané des capacités exposées. L’infobulle précise cette différence ; l’application ne promet pas la reproduction exacte de la valeur Apple.

### Température et état macOS

Le registre ne publie aucun champ de température sur le Mac vérifié. L’application affichait 0 °C et pouvait traiter cette absence comme une batterie refroidie. La température est désormais facultative, affichée « — » avec une explication quand elle manque. Une température inconnue ne lève pas une pause thermique existante. La condition macOS et le nombre de cycles peuvent aussi être inconnus plutôt que présentés comme normaux ou nuls.

Une lecture périodique toutes les 60 secondes complète les notifications IOPowerSources, qui ne garantissent pas une mise à jour de la température et de la télémétrie. Le timer est tolérant et n’est pas une assertion de maintien en éveil.

Si macOS ne fournit aucune température, BetterBattery ne peut pas assurer son propre seuil thermique logiciel. Les protections matérielles et celles de macOS restent indépendantes ; aucune température alternative n’est inventée.

### Contrôle de charge et helper

- Top Up respecte désormais une pause thermique, y compris quand la charge était déjà arrêtée avant la surchauffe.
- Une désynchronisation SMC ne contourne pas une pause thermique lorsque la température devient inconnue.
- Les appels XPC utilisent des réponses asynchrones et une attente bornée à trois secondes par requête. Une réponse tardive ne peut plus modifier le résultat après expiration. L’interface reste synchrone : plusieurs opérations successives peuvent encore occasionner une pause ; l’attente infinie est supprimée.
- Les échecs temporaires d’ouverture/détection AppleSMC ne sont plus mémorisés définitivement dans le helper. Sa version passe à 3 pour que l’application recharge l’ancien daemon après installation.
- Les listes de clés autorisées, la vérification des écritures et la validation de signature du client sont conservées.

## Vérifications

Commandes reproductibles :

```sh
make test
build/tests/battery-reader --live
make build CODESIGN_ID='Apple Development: Yohan Gouiran (6JXRCYP89W)'
codesign --verify --deep --strict build/BetterBattery.app
git diff --check
```

Les tests compilent sans certificat et sans helper privilégié. Le certificat de développement existant a servi à la compilation locale complète ; aucun nouveau certificat n’a été créé.

- 22 assertions : format macOS 27, ancien format Apple Silicon, replis, capacités absentes/invalides, valeurs normalisées, température absente, télémétrie, réponse XPC dupliquée, erreur, expiration et réponse tardive.
- 11 assertions sur la machine d’état de charge avec un SMC simulé et des préférences isolées : hystérésis, Top Up, surchauffe, disparition du capteur, désynchronisation SMC, débranchement et restauration à l’arrêt.
- Lecture réelle via BatteryReader : santé, cycles et absence de température cohérents avec le registre.
- Application et helper compilés en optimisation de production pour arm64 avec une cible macOS 13, assets compilés et signatures vérifiées.
- Revue des chemins démarrage, approbation SMAppService, authentification XPC, SMC, veille/réveil, historique, notifications, démarrage à la connexion, mode économie et maintien en éveil.

## Ce qui reste à valider sur l’application installée

La compilation et les tests de logique ne certifient pas à eux seuls tout le fonctionnement matériel sous macOS 27.

- Enregistrement/approbation du nouveau helper, authentification réelle par audit token et signature, remplacement d’un daemon de version 2.
- Charge réellement arrêtée/reprise, décharge forcée, LED MagSafe et restauration après arrêt/crash.
- Veille prolongée puis réveil, rebranchement, interaction avec la recharge optimisée et les limites natives éventuelles de macOS.
- Application effective de `pmset -b lowpowermode` et maintien en éveil ; notifications selon les autorisations utilisateur.
- Affichage interactif clair/sombre, transparence réduite, navigation clavier, VoiceOver et panneaux sur petits écrans ou plusieurs moniteurs.
- Exécution réelle sur macOS 13–26 et autres générations de Mac. Les fixtures couvrent l’ancien format, pas tous les matériels.

Aucune installation dans `/Applications` ni relance de l’application personnelle n’a été effectuée. Le build se trouve dans `build/BetterBattery.app`.

## Trois améliorations de design ou de fonctionnement proposées

1. **Afficher l’état réel du helper et les erreurs d’action.** Désactiver les commandes indisponibles, proposer « Ouvrir les réglages » et confirmer les bascules uniquement après succès. Aujourd’hui, certains états d’automatisation peuvent annoncer un succès malgré un échec du helper.
2. **Rendre les contrôles personnalisés accessibles.** Les sélecteurs et interrupteurs dessinés dans des NSView reposent sur `mouseDown` ; ajouter navigation clavier, activation Espace/Entrée, Échap pour fermer le panneau, rôles et valeurs VoiceOver, et respect de Réduire les animations.
3. **Adapter le panneau à l’espace disponible.** Le panneau contourne volontairement le bornage AppKit et peut grandir jusqu’à 5000 points. Ajouter un défilement et un bornage à l’écran actif pour garder les réglages et Quitter accessibles sur un écran de faible hauteur.

## Trois fonctionnalités pertinentes

1. **Historique de santé sur plusieurs mois.** Enregistrer capacité, cycles, source de mesure et changements de batterie, puis montrer une tendance plutôt qu’un pourcentage isolé.
2. **Charge prête à une heure choisie.** Un Top Up planifié avant un départ, qui revient automatiquement au mode de préservation une fois terminé ou débranché.
3. **Diagnostic exportable et expurgé.** Exporter version macOS, disponibilité des capteurs, état du helper et capacités SMC, sans numéro de série, pour diagnostiquer rapidement les régressions après une mise à jour.
