# Keeping Plezilo's Android signing key

Plezilo's preview APKs are signed with a key that, until the `ANDROID_*` repository secrets exist, lives only in
the Actions cache of the build branch (`silo-preview-keystore-v1`, or `-enc-v1` once encrypted). GitHub deletes a cache
entry after 7 days without a build. A lost key means a new one, and every install then has to be removed before the
next update installs. These steps keep the **same** key for good.

## 1. Set a passphrase

Repository **Settings › Secrets and variables › Actions › New repository secret**:

- Name `PREVIEW_KEYSTORE_PASSPHRASE`, value a long random string you keep in your password manager
  (for example the output of `openssl rand -base64 32`).

From now on the APK build also stores the cached key encrypted with it.

## 2. Export the key

Push a commit whose first line contains `[export-keystore]` to the build branch (Claude can do this). The
**Export preview signing key** workflow restores the cached key, encrypts it with your passphrase and attaches the
`preview-signing-key` artifact to its run (kept for one day). Download it from the run page (Actions tab) and unzip it.

## 3. Decrypt it on your computer

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in preview-keystore.tar.enc | tar -x
# enter the passphrase; you get preview.jks and password
```

Keep `preview.jks` and `password` somewhere safe (password manager attachment or an encrypted drive): they are your
backup.

## 4. Add the stable-key secrets

Create these repository secrets:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | output of `base64 -w0 preview.jks` (macOS: `base64 -i preview.jks`) |
| `ANDROID_STORE_PASSWORD` | the contents of `password` |
| `ANDROID_KEY_PASSWORD` | the contents of `password` (the same) |
| `ANDROID_KEY_ALIAS` | `preview` |

The APK build prefers these secrets over the cache, so the next preview is signed with the same key and installs as
an update. Check that release's notes: there must be no "uninstall first" warning. After that the cache no longer
matters, and the downloaded artifact can be deleted.
