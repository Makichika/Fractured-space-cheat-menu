# Sécurité et provenance

Ce projet modifie uniquement le processus local `spserver.exe` afin de fournir les fonctions du trainer.

La version distribuée ici :
- ne désactive pas Microsoft Defender ;
- ne modifie pas Smart App Control ;
- ne crée pas de tâche planifiée ou service de persistance ;
- ne télécharge pas de payload distant ;
- ne contient pas `trainer-debug.log` dans la release.

Les fonctions d'accès/injection mémoire déjà nécessaires au trainer sont conservées, car les retirer casserait certaines fonctions.

Vérifie `SHA256SUMS.txt` pour contrôler l'intégrité des fichiers.
