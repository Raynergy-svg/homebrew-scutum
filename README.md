# Raynergy-svg/homebrew-scutum

Homebrew tap for Scutum.

## Install

```zsh
brew tap Raynergy-svg/scutum
brew install irondome-sentinel
```

## Notes

- The formula (`Formula/irondome-sentinel.rb`) installs from the GitHub tag tarball.

## Audit (optional)

Homebrew no longer allows `brew audit` to be called with a local file path. Audit by formula name after tapping:

```zsh
brew audit --strict --online --formula irondome-sentinel
```

Bundler may print a funding notice ("Run `bundle fund`"); it’s informational and not an error.
