# Fractured Space Solo Trainer v20

Menu pour les parties locales de Fractured Space utilisant `spserver.exe`.

## Utilisation

1. Lance une partie solo et attends que ton vaisseau soit présent.
2. Lance `RUN_V20.bat`.
3. Dans **Spawner / Scenario**, choisis un type de frégate, un nombre de 1 à 20 et le vaisseau à escorter, puis clique sur **SPAWN FRIGATE**.

Les cinq vrais types sont disponibles : `SmallBeamShip`, `SmallGunnerShip`, `SmallHealerShip`, `SmallKamikaziShip` et `SmallMissileShip`. Le menu charge la classe nécessaire en Conquest comme en Last Stand, puis crée les frégates une par une. Le jeu doit rester ouvert ; seul le menu doit être relancé après une mise à jour de ses fichiers.

## Fichiers

Garde `FracturedSpaceSoloTrainer_v20.ps1`, `Sandbox_v20.ps1`, `FrigateLoader_v20.ps1`, `RUN_V20.bat` et `data/ship-systems.json` ensemble. Le journal `data/trainer-debug.log` est créé localement et n'est pas publié.

Le trainer vérifie la version de `spserver.exe` avant ses opérations en mémoire. Il utilise notamment `OpenProcess`, `ReadProcessMemory`, `WriteProcessMemory` et `CreateRemoteThread`. Windows peut avertir à cause de ces opérations. Ne désactive pas Defender ou Smart App Control pour lancer le menu.

`RUN_V20.bat` utilise `-ExecutionPolicy Bypass` uniquement pour le processus PowerShell qu'il lance ; il ne change pas la politique de la machine. Les empreintes des fichiers publiés sont dans `SHA256SUMS.txt`.
