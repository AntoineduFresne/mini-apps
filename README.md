# Mini apps

Two small macOS apps, each compiled on the Mac by its installer.

- **Relancer** relaunches the app in front with Control + Option + Command + R.
- **Rester actif** keeps the Mac awake, even with the lid closed, for a chosen time.

## Install or update

From this folder:

```
zsh relancer/installer.zsh
zsh rester-actif/installer.zsh
```

Both need Apple's command line tools (`xcode-select --install`). Rester actif asks for the admin password once.

## Remove

```
zsh relancer/desinstaller.zsh
zsh rester-actif/desinstaller.zsh
```
