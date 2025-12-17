JDK 21 Upgrade Notes

This Flutter Android module was updated to compile against Java 21 (compileOptions and Kotlin `jvmTarget`).

What I changed:
- `app/build.gradle.kts`: `sourceCompatibility` and `targetCompatibility` set to Java 21.
- `app/build.gradle.kts`: `kotlinOptions.jvmTarget` set to `21`.

Manual steps you must perform on your machine:
1. Install a JDK 21 distribution (Temurin / Eclipse Adoptium or other).
   - Example: https://adoptium.net/
2. Point Gradle to the JDK 21 installation. Choose one of the following options:
   - Set `JAVA_HOME` to the JDK 21 path in your environment.
   - Or set `org.gradle.java.home` in `android/gradle.properties` to the absolute JDK 21 path, e.g.:
     org.gradle.java.home=C:\\Program Files\\Eclipse Adoptium\\jdk-21
3. (Optional) Verify Gradle is using Java 21:
   - In PowerShell:
     ```powershell
     & "${Env:JAVA_HOME}\\bin\\java" -version
     ./gradlew -v
     ```

Notes and compatibility:
- Android Gradle Plugin (AGP) and Gradle versions need to support JDK 21 for the build to succeed. If you encounter compatibility errors, consider upgrading Gradle and AGP first.
- The automated Java upgrade tool could not run on this project because it's a Flutter Android project (the upgrade tool only supports pure Maven/Gradle Java projects). Changes above are applied manually to the Gradle files.

If you want, I can:
- Add `org.gradle.java.home` to `android/gradle.properties` if you provide the JDK 21 path.
- Attempt to upgrade Gradle and AGP if build errors appear.
- Run a local Gradle build (if you allow me to run commands here).
