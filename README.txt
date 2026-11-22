Petalhaven - Flutter rebuild, PHASE 8 (all screens, all 10 games, forms, backup, animations, exact hero photos)

Build the APK on GitHub (no installs):
 1. New GitHub repo -> upload everything in this folder (keep the .github folder; if it is skipped,
    create the file .github/workflows/build-apk.yml by hand and paste the contents from this zip).
 2. Actions tab -> "Build Flutter APK" -> wait ~6-8 min (first run downloads Flutter).
 3. Open the finished run -> Artifacts -> Petalhaven-Flutter-APK -> unzip -> install app-release.apk.

If the build fails, open the red step and send me the error text. This code has not been compiled yet.

Backup compatibility: "Share full backup" / "Choose file" use the same JSON format as the website,
so a backup exported from the original Petalhaven HTML can be imported here (and vice versa).
