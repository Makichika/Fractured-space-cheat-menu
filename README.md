# Fractured Space Solo Trainer v20

Trainer destiné au serveur solo/local `spserver.exe` de Fractured Space.

## Utilisation

1. Lance Fractured Space.
2. Ouvre une partie/secteur local afin que `spserver.exe` soit démarré.
3. Lance `RUN_V20.bat`.
4. Utilise le trainer comme avant.

## Changements de cette distribution

- La logique du trainer n'a pas été modifiée.
- `FracturedSpaceSoloTrainer_v20.ps1` est inchangé.
- `Sandbox_v20.ps1` est inchangé.
- `data/ship-systems.json` est inchangé.
- Le lanceur ne force plus `-ExecutionPolicy Bypass`.
- `data/trainer-debug.log` n'est plus distribué : le trainer le recrée localement si nécessaire.
- Des hashes SHA-256 sont fournis dans `SHA256SUMS.txt`.

## Pourquoi Windows peut encore avertir

Le trainer travaille avec la mémoire de `spserver.exe` et utilise notamment des API Windows telles que `OpenProcess`, `ReadProcessMemory`, `WriteProcessMemory`, `VirtualAllocEx`, `VirtualProtectEx` et `CreateRemoteThread`.

Ces techniques sont aussi utilisées par certains logiciels malveillants ; une protection heuristique peut donc avertir même si le projet est publié avec son code source.

Cette distribution n'essaie pas de désactiver Defender, Smart App Control ou AMSI, et n'essaie pas de masquer ces opérations.

## Important

Ne désactive pas Windows Defender ou Smart App Control pour exécuter le trainer.

Pour une distribution publique avec moins d'avertissements, la prochaine étape correcte est de signer les scripts/releases avec un certificat de signature de code et de conserver des builds reproductibles avec les hashes publiés.
