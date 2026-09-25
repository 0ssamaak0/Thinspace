# Build Thinspace

Thinspace targets macOS 27 and Apple silicon. The project intentionally does not
contain a development team or release provisioning profile.

Build an unsigned local release from the repository root:

```bash
xcodebuild \
  -project Thinspace.xcodeproj \
  -scheme Thinspace \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./build/DerivedData \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Create the disk image:

```bash
./scripts/create-dmg.sh \
  "./build/DerivedData/Build/Products/Release/Thinspace.app" \
  ./build
```

The resulting disk image is `./build/Thinspace.dmg`.
