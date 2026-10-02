// Public key that release archives are signed with (Ed25519, raw, base64).
// Written by scripts/updater-keys.sh; empty = auto-install off (download only).
// The private key never leaves the GitHub secret MAC_UPDATE_KEY.
enum UpdateKey {
    static let macPublicKey = "dSgbkypT4AdWFXUXRKEShi+AQDsv89w2rLmsqDOBVxs="
}
