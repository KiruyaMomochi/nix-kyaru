{ pkgs }:
let
  android = pkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [ "35.0.0" ];
    platformVersions = [ "35" ];
    includeEmulator = false;
  };
  tools = builtins.head android.build-tools;
  platform = builtins.head android.platforms;
  androidJar = "${platform}/libexec/android-sdk/platforms/android-35/android.jar";
in
pkgs.runCommand "hitohira-loc.jar" {
  nativeBuildInputs = [ pkgs.jdk ];
} ''
  mkdir classes
  cp ${./HitohiraLoc.java} HitohiraLoc.java
  javac --release 8 -Xlint:-options -cp ${androidJar} -d classes HitohiraLoc.java
  jar cf input.jar -C classes .
  java -cp ${tools}/libexec/android-sdk/build-tools/35.0.0/lib/d8.jar \
    com.android.tools.r8.D8 --min-api 31 --lib ${androidJar} --output output.jar input.jar
  cp output.jar $out
''
