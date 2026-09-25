# Sécurité et provenance

Ce projet est destiné au serveur solo local `spserver.exe`. Il lit et modifie la mémoire de ce processus et y exécute du code pour certaines actions. Ces opérations peuvent déclencher une alerte heuristique de Windows.

Les scripts publiés ne désactivent pas Microsoft Defender ou Smart App Control, ne créent pas de tâche planifiée ni de service, et ne téléchargent pas de code distant. `RUN_V20.bat` utilise `-ExecutionPolicy Bypass` pour son seul processus PowerShell ; il ne modifie pas la politique du système.

`data/trainer-debug.log` peut être créé localement, mais il est exclu du dépôt. Vérifie les empreintes de `SHA256SUMS.txt` pour contrôler les fichiers publiés. N'exécute le menu qu'à partir d'une source que tu reconnais.
